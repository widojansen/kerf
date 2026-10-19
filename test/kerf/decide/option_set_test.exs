defmodule Kerf.Decide.OptionSetTest.LeakyAdapter do
  @moduledoc false
  # Answers a Choice with probability mass on a label the caller never offered.
  @behaviour Kerf.Decide.Adapter

  @impl true
  def ask(_state, _questions, _opts),
    do: {:ok, %{category: %{probs: [{"business", 0.1}, {"personal", 0.1}, {"wire_money", 0.8}]}}}

  @impl true
  def info,
    do: %{model_id: "leaky-stub", types: [:choice], max_state_tokens: 4096, languages: ~w(en)}
end

defmodule Kerf.Decide.OptionSetTest do
  @moduledoc """
  SPEC_H F06 — docs/superpowers/specs/SPEC_H_kerf_decide.json

  Enumerated option sets and executor re-validation. Contract pinned here:

    * `OptionSet.new(labels)` → `{:ok, set} | {:error, reason}`; labels are
      binaries, ≥ 2, unique, kept in caller order (`OptionSet.labels/1`).
    * `OptionSet.act(result, set, opts)` with `threshold:`, `actions:
      %{label => {action_name, arg}}`, optional `approved:` →
      `{:ok, {action_name, arg}} | {:escalate, result} | {:error, reason}`.
    * `OptionSet.action_class/1` is a fixed table (:gate_only | :effect),
      not a runtime registry a caller could widen.

  F06.4 Gate: Kerf.Gate does not exist (SPEC_G not implemented). The :effect
  branch is tested against the placeholder `Kerf.Decide.Gate` /
  `Kerf.Decide.Gate.Approved`, private to the Decide subtree.
  TODO(SPEC_G): replace with Kerf.Gate / %Kerf.Gate.Approved{} when it lands.
  The test module is the only place an approval is constructed.

  F06.3 lives in test/agents/email_triage/vocabulary_parity_test.exs, the
  existing SPEC_C guard it extends.
  """
  use ExUnit.Case, async: false

  alias Kerf.Decide
  alias Kerf.Decide.{OptionSet, Question, State}
  alias Kerf.Decide.OptionSetTest.LeakyAdapter

  @repo_root Path.expand("../../..", __DIR__)

  # F06.2 grep guard. Committed allowlist: the only lib/ file allowed to read
  # `.label` and act on it. Same discipline as the SPEC_C parity guard —
  # changing this list is a reviewed decision, not a fix-up.
  @label_effect_allowlist ["lib/kerf/decide/option_set.ex"]
  @side_effect ~r/\b(Repo\.(insert|update|delete)|Req\.|Oban\.insert|GenServer\.(call|cast)|send\(|Gmail|Telegram|Proxy\.request|CredentialVault\.get|HTTP\.)/

  @gate_only [:route, :label, :escalate, :log]
  @effect [:gmail_send, :gmail_trash, :http_external, :vault_read]

  setup do
    for mod <- [
          Kerf.Decide.OptionSet,
          Kerf.Decide.Question,
          Kerf.Decide.Gate,
          Kerf.Decide.Gate.Approved
        ] do
      assert Code.ensure_loaded?(mod), "#{inspect(mod)} is not implemented yet (SPEC_H F06, RED)"
    end

    :ok
  end

  # ---------- helpers ----------

  # Kerf.Provenance does not exist yet: SPEC_G §4-shaped maps (see decide_test.exs).
  defp tainted, do: %{taint: :tainted, origin: :derived, sources: ["doc-1"]}
  defp clean, do: %{taint: :clean, origin: :derived, sources: []}

  defp set!(labels \\ ~w(spam business reply)) do
    {:ok, set} = OptionSet.new(labels)
    set
  end

  defp result(label, confidence, provenance) do
    %{
      label: label,
      probs: [{label, confidence}],
      confidence: confidence,
      backend: __MODULE__,
      latency_ms: 2,
      provenance: provenance
    }
  end

  @draft %{to: "someone", body: "draft"}
  defp actions,
    do: %{
      "spam" => {:label, "spam"},
      "business" => {:route, :inbox},
      "reply" => {:gmail_send, @draft}
    }

  defp act(result, opts \\ []),
    do: OptionSet.act(result, set!(), Keyword.merge([threshold: 0.8, actions: actions()], opts))

  # ---------- F06.1 ----------

  describe "F06.1 OptionSet.new/1" do
    test "rejects an empty list", do: assert({:error, _} = OptionSet.new([]))
    test "rejects a single label", do: assert({:error, _} = OptionSet.new(["only"]))
    test "rejects duplicate labels", do: assert({:error, _} = OptionSet.new(["a", "b", "a"]))
    test "rejects non-binary labels", do: assert({:error, _} = OptionSet.new(["a", :b]))
    test "rejects integer labels", do: assert({:error, _} = OptionSet.new([1, 2]))

    test "accepts ≥ 2 unique binary labels and keeps caller order" do
      assert {:ok, set} = OptionSet.new(["spam", "business", "reply"])
      assert OptionSet.labels(set) == ["spam", "business", "reply"]
    end

    test "a Choice question refuses a raw list (constructors raise on wrong types)" do
      assert_raise FunctionClauseError, fn -> Question.choice(:category, "Which?", ["a", "b"]) end
    end

    test "an adapter cannot widen the set: an out-of-set label is a schema violation, never a result" do
      state =
        struct!(State,
          content: "text",
          provenance: %{taint: :tainted, origin: :ingress, sources: ["doc-1"]}
        )

      question = Question.choice(:category, "Which?", set!(["business", "personal"]))

      result = Decide.ask(state, [question], adapter: LeakyAdapter)
      refute match?({:ok, _}, result)
      assert {:error, {:schema_violation, _}} = result
    end
  end

  # ---------- F06.2 ----------

  describe "F06.2 act/3 re-validation" do
    test "label in set and confidence ≥ threshold → {:ok, action}" do
      assert {:ok, {:label, "spam"}} = act(result("spam", 0.9, tainted()))
    end

    test "label not in set → {:error, :label_not_in_set}" do
      assert {:error, :label_not_in_set} = act(result("wire_money", 0.99, clean()))
    end

    test "label-not-in-set is checked before confidence (a forged low-confidence label is not escalated)" do
      assert {:error, :label_not_in_set} = act(result("wire_money", 0.1, clean()))
    end

    test "confidence < threshold → {:escalate, result}" do
      low = result("spam", 0.5, tainted())
      assert {:escalate, ^low} = act(low)
    end

    test "an action name outside the fixed table is refused" do
      assert {:error, {:unknown_action, :format_disk}} =
               act(result("spam", 0.9, clean()), actions: %{"spam" => {:format_disk, nil}})
    end
  end

  describe "F06.2 grep guard: only option_set.ex turns .label into a side effect" do
    test "allowlisted files exist and no other lib/ file has `.label` within 3 lines of a side effect" do
      for path <- @label_effect_allowlist do
        assert File.exists?(Path.join(@repo_root, path)),
               "allowlisted #{path} does not exist; the allowlist is stale"
      end

      offenders =
        Path.join(@repo_root, "lib/**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(&label_into_side_effect?/1)
        |> Enum.map(&Path.relative_to(&1, @repo_root))

      assert offenders -- @label_effect_allowlist == [],
             "result.label flows into a side effect outside OptionSet.act/3: #{inspect(offenders -- @label_effect_allowlist)}"
    end
  end

  defp label_into_side_effect?(file) do
    lines = file |> File.read!() |> String.split("\n")

    lines
    |> Enum.with_index()
    |> Enum.any?(fn {line, i} ->
      line =~ ~r/\.label\b/ and lines |> Enum.slice(i, 4) |> Enum.any?(&(&1 =~ @side_effect))
    end)
  end

  # ---------- F06.4 ----------

  describe "F06.4 :gate_only vs :effect" do
    test "route, label, escalate, log are :gate_only" do
      for action <- @gate_only,
          do: assert(OptionSet.action_class(action) == :gate_only, inspect(action))
    end

    test "gmail_send, gmail_trash, http_external, vault_read are :effect" do
      for action <- @effect,
          do: assert(OptionSet.action_class(action) == :effect, inspect(action))
    end

    test "tainted result + :gate_only action → {:ok, action}" do
      assert {:ok, {:label, "spam"}} = act(result("spam", 0.9, tainted()))
    end

    test "tainted result + :effect action → {:error, :approval_required}" do
      assert {:error, :approval_required} = act(result("reply", 0.95, tainted()))
    end

    test "clean result + :effect action without Approved → {:error, :approval_required}" do
      assert {:error, :approval_required} = act(result("reply", 0.95, clean()))
    end

    test "clean result + :effect action + Approved for that action → {:ok, action}" do
      {:ok, approved} = Kerf.Decide.Gate.approve({:gmail_send, @draft}, :wido)

      assert {:ok, {:gmail_send, @draft}} =
               act(result("reply", 0.95, clean()), approved: approved)
    end

    test "an Approved for a different action does not unlock this one" do
      {:ok, approved} = Kerf.Decide.Gate.approve({:gmail_trash, "msg-1"}, :wido)

      assert {:error, :approval_required} =
               act(result("reply", 0.95, clean()), approved: approved)
    end

    test "act/3 never calls an Approved constructor itself" do
      {:ok, approved} = Kerf.Decide.Gate.approve({:gmail_send, @draft}, :wido)

      constructors = [
        {Kerf.Decide.Gate, :approve, :_},
        {Kerf.Decide.Gate.Approved, :_, :_},
        {Kerf.Gate, :approve, :_},
        {Kerf.Gate.Approved, :_, :_}
      ]

      :erlang.trace(self(), true, [:call])
      for mfa <- constructors, do: :erlang.trace_pattern(mfa, true, [:local])

      try do
        act(result("reply", 0.95, tainted()))
        act(result("reply", 0.95, clean()))
        act(result("reply", 0.95, clean()), approved: approved)
        act(result("spam", 0.95, tainted()))
      after
        :erlang.trace(self(), false, [:call])
        for mfa <- constructors, do: :erlang.trace_pattern(mfa, false, [:local])
      end

      refute_received {:trace, _, :call, {Kerf.Decide.Gate, :approve, _}}
      refute_received {:trace, _, :call, {Kerf.Decide.Gate.Approved, _, _}}
      refute_received {:trace, _, :call, {Kerf.Gate, :approve, _}}
      refute_received {:trace, _, :call, {Kerf.Gate.Approved, _, _}}
    end
  end
end
