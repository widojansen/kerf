defmodule Kerf.Decide.ServerTest.Adapters do
  @moduledoc false
  # Stub adapters for the server tests. Each reads its behaviour from opts so
  # one router can exercise every failure mode.

  defmodule Scripted do
    @moduledoc false
    @behaviour Kerf.Decide.Adapter

    @impl true
    def ask(_state, questions, opts) do
      responses = Keyword.fetch!(opts, :responses)
      {:ok, Map.new(questions, fn %{name: name} -> {name, Map.fetch!(responses, name)} end)}
    end

    @impl true
    def info,
      do: %{
        model_id: "scripted-stub",
        types: [:noul, :choice],
        max_state_tokens: 4096,
        languages: ~w(en)
      }
  end

  defmodule Fixed do
    @moduledoc false
    # For the 3-tuple reply form, which carries no opts: always 0.95 confidence.
    @behaviour Kerf.Decide.Adapter

    @impl true
    def ask(_state, _questions, _opts),
      do: {:ok, %{category: %{probs: [{"a", 0.975}, {"b", 0.025}]}}}

    @impl true
    def info,
      do: %{model_id: "fixed-stub", types: [:choice], max_state_tokens: 4096, languages: ~w(en)}
  end

  defmodule Raising do
    @moduledoc false
    @behaviour Kerf.Decide.Adapter

    @impl true
    def ask(_state, _questions, _opts), do: raise("adapter blew up")

    @impl true
    def info,
      do: %{model_id: "raising-stub", types: [:choice], max_state_tokens: 4096, languages: ~w(en)}
  end

  defmodule Exiting do
    @moduledoc false
    @behaviour Kerf.Decide.Adapter

    @impl true
    def ask(_state, _questions, _opts), do: exit(:adapter_exited)

    @impl true
    def info,
      do: %{model_id: "exiting-stub", types: [:choice], max_state_tokens: 4096, languages: ~w(en)}
  end

  defmodule Sleeping do
    @moduledoc false
    # Reports its pid and $callers so the test can find it under the Task.Supervisor.
    @behaviour Kerf.Decide.Adapter

    @impl true
    def ask(_state, _questions, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:adapter_running, self(), Process.get(:"$callers", [])}
      )

      Process.sleep(Keyword.fetch!(opts, :sleep_ms))
      {:ok, %{category: %{probs: [{"a", 0.975}, {"b", 0.025}]}}}
    end

    @impl true
    def info,
      do: %{
        model_id: "sleeping-stub",
        types: [:choice],
        max_state_tokens: 4096,
        languages: ~w(en)
      }
  end
end

defmodule Kerf.Decide.ServerTest do
  @moduledoc """
  SPEC_H F02 — docs/superpowers/specs/SPEC_H_kerf_decide.json

  Kerf.Decide.Server: Jev.Server-pattern GenServer. Contract pinned here:

    * a callback returns `{:reply, {tag, state, questions}, s}` or
      `{:reply, {tag, state, questions, opts}, s}` to ask a decision;
    * the answer arrives as `handle_answer(tag, results, s)` — tag FIRST, per
      SPEC_H F02.1 (jev 0.1 uses `handle_answer(reply, tag, s)`; see RED report);
    * `results` is the bare `%{name => result}` map, or `{:error, reason}`;
    * a speculative request marks follow-ups with `branch:`; handle_answer
      commits one by returning `{:branch, name, callback_return}`.

  The router is compiled at runtime by `router!/0` (written before the
  Kerf.Decide.Server skeleton existed).
  """
  use ExUnit.Case, async: false

  alias Kerf.Decide.{OptionSet, Question, State}
  alias Kerf.Decide.ServerTest.Adapters

  @router Kerf.Decide.ServerTest.Router

  setup do
    router!()
    :ok
  end

  defp router! do
    unless Code.ensure_loaded?(@router) do
      Code.compile_quoted(
        quote do
          defmodule Kerf.Decide.ServerTest.Router do
            use Kerf.Decide.Server

            def init(test_pid), do: {:ok, %{test: test_pid}}

            def handle_call(:ping, from, s) do
              GenServer.reply(from, :pong)
              {:noreply, s}
            end

            def handle_call({:ask, ref, state, questions}, from, s) do
              GenServer.reply(from, :ok)
              {:reply, {{:tag, ref}, state, questions}, s}
            end

            def handle_call({:ask, ref, state, questions, opts}, from, s) do
              GenServer.reply(from, :ok)
              {:reply, {{:tag, ref}, state, questions, opts}, s}
            end

            def handle_call({:speculate, ref, state, questions, opts}, from, s) do
              GenServer.reply(from, :ok)
              {:reply, {{:speculative, ref}, state, questions, opts}, s}
            end

            def handle_answer({:speculative, ref}, results, s) when is_map(results) do
              send(s.test, {:answered, ref, results |> Map.keys() |> Enum.sort()})
              {:branch, :a, {:noreply, s}}
            end

            # Clause order is the routing; the guards are the thresholds.
            def handle_answer({:tag, ref}, {:error, reason}, s),
              do: routed(s, ref, {:error, reason})

            def handle_answer({:tag, ref}, %{category: %{confidence: c}}, s) when c >= 0.9,
              do: routed(s, ref, :act)

            def handle_answer({:tag, ref}, %{category: %{confidence: c}}, s) when c >= 0.5,
              do: routed(s, ref, :llm)

            def handle_answer({:tag, ref}, _results, s), do: routed(s, ref, :human)

            defp routed(s, ref, branch) do
              send(s.test, {:routed, ref, branch})
              {:noreply, s}
            end
          end
        end
      )
    end

    :ok
  end

  # ---------- helpers ----------

  # Kerf.Provenance does not exist yet: SPEC_G §4-shaped map (see decide_test.exs).
  defp state,
    do:
      struct!(State,
        content: "Subject: invoice 2026-10",
        provenance: %{taint: :tainted, origin: :ingress, sources: ["doc-1"]}
      )

  defp category_question do
    {:ok, set} = OptionSet.new(["a", "b"])
    Question.choice(:category, "Which?", set)
  end

  # K = 2, so confidence = 2 * p_max - 1: p 0.975 -> 0.95, 0.85 -> 0.7, 0.6 -> 0.2.
  defp scripted(p_max),
    do: [
      adapter: Adapters.Scripted,
      responses: %{category: %{probs: [{"a", p_max}, {"b", 1 - p_max}]}}
    ]

  defp start_router!, do: start_supervised!({@router, self()})

  defp ask!(server, opts) do
    ref = make_ref()
    :ok = GenServer.call(server, {:ask, ref, state(), [category_question()], opts})
    ref
  end

  defp literal_result(confidence) do
    %{
      category: %{
        label: "a",
        probs: [{"a", 0.5 + confidence / 2}, {"b", 0.5 - confidence / 2}],
        confidence: confidence,
        backend: Adapters.Scripted,
        latency_ms: 3,
        provenance: %{taint: :tainted, origin: :derived, sources: ["doc-1"]}
      }
    }
  end

  @doc false
  def handle_telemetry(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:decide_answer, metadata.question_name})

  # ---------- F02.1 ----------

  describe "F02.1 handle_answer routing by clause order" do
    test "literal result maps route by confidence guard, in clause order" do
      s = %{test: self()}

      for {confidence, branch} <- [{0.95, :act}, {0.7, :llm}, {0.2, :human}] do
        ref = make_ref()
        assert {:noreply, ^s} = @router.handle_answer({:tag, ref}, literal_result(confidence), s)
        assert_received {:routed, ^ref, ^branch}
      end
    end

    test "answers delivered by the server reach handle_answer(tag, results, s) and route by confidence" do
      server = start_router!()

      for {p_max, branch} <- [{0.975, :act}, {0.85, :llm}, {0.6, :human}] do
        ref = ask!(server, scripted(p_max))
        assert_receive {:routed, ^ref, ^branch}, 500
      end
    end

    test "the 3-tuple reply form uses the configured adapter" do
      previous = Application.get_env(:kerf, Kerf.Decide)
      Application.put_env(:kerf, Kerf.Decide, adapter: Adapters.Fixed)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kerf, Kerf.Decide, previous),
          else: Application.delete_env(:kerf, Kerf.Decide)
      end)

      server = start_router!()
      ref = make_ref()
      :ok = GenServer.call(server, {:ask, ref, state(), [category_question()]})
      assert_receive {:routed, ^ref, :act}, 500
    end
  end

  # ---------- F02.2 ----------

  describe "F02.2 isolation under a dedicated Task.Supervisor" do
    test "the Decide subtree owns a named Task.Supervisor" do
      sup = Process.whereis(Kerf.Decide.Supervisor)
      task_sup = Process.whereis(Kerf.Decide.TaskSupervisor)
      assert is_pid(sup), "Kerf.Decide.Supervisor is not running"
      assert is_pid(task_sup), "Kerf.Decide.TaskSupervisor is not running"

      child_pids = sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 1))
      assert task_sup in child_pids
    end

    test "raise, exit and timeout each arrive as handle_answer(tag, {:error, reason}, s) with distinct reasons" do
      server = start_router!()

      raised = ask!(server, adapter: Adapters.Raising)
      assert_receive {:routed, ^raised, {:error, raise_reason}}, 500

      exited = ask!(server, adapter: Adapters.Exiting)
      assert_receive {:routed, ^exited, {:error, exit_reason}}, 500

      slept =
        ask!(server, adapter: Adapters.Sleeping, timeout: 50, test_pid: self(), sleep_ms: 300)

      assert_receive {:routed, ^slept, {:error, timeout_reason}}, 500

      assert timeout_reason == :timeout
      assert length(Enum.uniq([raise_reason, exit_reason, timeout_reason])) == 3
      assert Process.alive?(server)
      assert GenServer.call(server, :ping) == :pong
    end

    test "the mailbox keeps draining while a request is stalled, and the stall runs under Kerf.Decide.TaskSupervisor" do
      server = start_router!()
      ref = ask!(server, adapter: Adapters.Sleeping, timeout: 50, test_pid: self(), sleep_ms: 300)

      assert_receive {:adapter_running, adapter_pid, callers}, 40

      {elapsed_us, reply} = :timer.tc(fn -> GenServer.call(server, :ping) end)
      assert reply == :pong
      assert elapsed_us < 10_000, "ping took #{elapsed_us} µs while a decision was in flight"

      supervised = Task.Supervisor.children(Kerf.Decide.TaskSupervisor)

      assert Enum.any?([adapter_pid | callers], &(&1 in supervised)),
             "stalled adapter call is not running under Kerf.Decide.TaskSupervisor"

      assert_receive {:routed, ^ref, {:error, :timeout}}, 200
      # The stalled adapter's late result must not produce a second answer.
      refute_receive {:routed, ^ref, _}, 400
    end
  end

  # ---------- F02.4 ----------

  describe "F02.4 speculative fan-out" do
    setup do
      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:kerf, :decide, :answer],
          &__MODULE__.handle_telemetry/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "only the taken branch's answers emit [:kerf, :decide, :answer]; the discarded branch emits nothing" do
      server = start_router!()

      questions = [
        category_question(),
        Question.noul(:follow_up_a, "Is a reply needed (branch a)?", branch: :a),
        Question.noul(:follow_up_b, "Is a client named (branch b)?", branch: :b)
      ]

      responses = %{
        category: %{probs: [{"a", 0.9}, {"b", 0.1}]},
        follow_up_a: %{p_yes: 0.8},
        follow_up_b: %{p_yes: 0.3}
      }

      ref = make_ref()

      :ok =
        GenServer.call(
          server,
          {:speculate, ref, state(), questions,
           [adapter: Adapters.Scripted, responses: responses]}
        )

      # Speculative: every branch is answered in the one request...
      assert_receive {:answered, ^ref, [:category, :follow_up_a, :follow_up_b]}, 500

      # ...but only the committed branch (plus unconditional questions) is logged.
      assert_receive {:decide_answer, :category}, 200
      assert_receive {:decide_answer, :follow_up_a}, 200
      refute_receive {:decide_answer, :follow_up_b}, 200
    end
  end

  # ---------- F02.3 ----------

  describe "F02.3 no test in test/kerf/decide/ reaches a real network" do
    # Every URL literal must be a Req.Test-plugged base URL: loopback, the
    # tailnet range, or the refused-remote probe, which is also plugged.
    @allowed_hosts ["127.0.0.1", "100.101.102.103", "100.200.1.1", "example.com"]
    @url ~r{https?://([^/"\s:]+)}

    test "URL literals are limited to plugged hosts, in files that use Req.Test" do
      files = Path.wildcard(Path.expand("**/*.exs", __DIR__))
      assert files != []

      files
      |> Enum.map(&{&1, File.read!(&1)})
      |> Enum.reject(fn {_file, source} -> hosts_in(source) == [] end)
      |> Enum.each(fn {file, source} ->
        unplugged = hosts_in(source) -- @allowed_hosts

        assert source =~ "Req.Test",
               "#{Path.relative_to_cwd(file)} has URL literals but no Req.Test plug"

        assert unplugged == [],
               "#{Path.relative_to_cwd(file)} names unplugged host(s) #{inspect(unplugged)}"
      end)
    end

    defp hosts_in(source),
      do: @url |> Regex.scan(source, capture: :all_but_first) |> List.flatten() |> Enum.uniq()
  end
end
