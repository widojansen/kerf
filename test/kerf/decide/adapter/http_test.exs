defmodule Kerf.Decide.Adapter.HTTPTest do
  @moduledoc """
  SPEC_H F03 — docs/superpowers/specs/SPEC_H_kerf_decide.json

  Adapter A: POST /v1/systemone. Every call goes through Kerf.Decide.ask/3
  (the production seam) with `adapter: Kerf.Decide.Adapter.HTTP` and a
  Req.Test plug passed as `req_options:` — no test here opens a socket.

  Fixtures under test/support/fixtures/decide/ are hand-written response
  shapes (`_fixture_note`), modelled on the TypeSafe answer shape that
  Hex jev 0.1.0 parses (lib/jev.ex:132-184). F10 replaces them with
  recorded Strands Decider / kev responses.
  """
  use ExUnit.Case, async: false

  alias Kerf.Decide
  alias Kerf.Decide.{OptionSet, Question, State}
  alias Kerf.Decide.Adapter.HTTP

  @fixtures Path.expand("../../../support/fixtures/decide", __DIR__)
  @content "Hi Wido, can you send the signed contract by Friday?"
  @levels ~w(none low medium high critical)

  @loopback "http://127.0.0.1:8900"
  @tailnet "http://100.101.102.103:8900"
  @outside_tailnet "http://100.200.1.1:8900"
  @remote "http://example.com"

  # ---------- helpers ----------

  # Kerf.Provenance does not exist yet: SPEC_G §4-shaped map (see decide_test.exs).
  defp state,
    do:
      struct!(State,
        content: @content,
        provenance: %{taint: :tainted, origin: :ingress, sources: ["doc-1"]}
      )

  defp questions do
    {:ok, categories} = OptionSet.new(~w(business personal newsletter))

    [
      Question.noul(:needs_reply, "Does this email need a reply?"),
      Question.choice(:category, "Which category is this email?", categories),
      Question.score(:urgency, "How urgent is this email?", @levels)
    ]
  end

  defp ask(base_url, opts \\ []) do
    Decide.ask(
      state(),
      questions(),
      [
        adapter: HTTP,
        base_url: base_url,
        req_options: [plug: {Req.Test, __MODULE__}, retry: false]
      ] ++ opts
    )
  end

  defp fixture!(name), do: File.read!(Path.join(@fixtures, name))

  # Serves `raw` byte-for-byte: Req.Test.json/2 would re-encode the body and
  # silently erase a duplicated key.
  defp serve(raw, status \\ 200) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, raw)
    end)
  end

  defp keys(%Jason.OrderedObject{values: values}), do: Enum.map(values, &elem(&1, 0))

  defp comparable(results),
    do:
      Map.new(results, fn {name, r} ->
        {name, Map.drop(r, [:backend, :latency_ms, :provenance])}
      end)

  defp assert_close(actual, expected) when is_number(expected),
    do: assert_in_delta(actual, expected, 1.0e-9)

  defp assert_close(actual, expected) when is_map(expected) do
    assert MapSet.new(Map.keys(actual)) == MapSet.new(Map.keys(expected))
    Enum.each(expected, fn {k, v} -> assert_close(Map.fetch!(actual, k), v) end)
  end

  defp assert_close(actual, expected) when is_list(expected) do
    assert length(actual) == length(expected)
    Enum.zip_with(actual, expected, &assert_close/2)
  end

  defp assert_close({ak, av}, {ek, ev}) do
    assert ak == ek
    assert_close(av, ev)
  end

  defp assert_close(actual, expected), do: assert(actual == expected)

  @doc false
  def handle_telemetry(event, measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, measurements, metadata})

  # ---------- F03.1 ----------

  describe "F03.1 request mapping" do
    test "outgoing body is exactly {state, questions: {id: {type, instructions, criteria}}} with options in caller order" do
      serve(fixture!("strands-decider-2026-10.json"))
      assert {:ok, _} = ask(@loopback)

      assert_received {:request, "POST", "/v1/systemone", body}
      decoded = Jason.decode!(body, objects: :ordered_objects)

      assert Enum.sort(keys(decoded)) == ["questions", "state"]
      assert decoded["state"] == @content

      questions = decoded["questions"]
      assert Enum.sort(keys(questions)) == ["category", "needs_reply", "urgency"]

      for {_id, question} <- questions.values do
        assert Enum.sort(keys(question)) == ["criteria", "instructions", "type"]
      end

      assert questions["needs_reply"]["type"] == "noul"
      assert questions["needs_reply"]["instructions"] == "Does this email need a reply?"

      assert questions["category"]["type"] == "choice"
      assert keys(questions["category"]["criteria"]) == ~w(business personal newsletter)

      assert questions["urgency"]["type"] == "score"
      assert questions["urgency"]["criteria"] == @levels
    end
  end

  describe "F03.1 response mapping (round trip)" do
    test "strands-decider-2026-10 maps to F01 result maps" do
      serve(fixture!("strands-decider-2026-10.json"))
      assert {:ok, results} = ask(@loopback)

      assert_close(comparable(results), %{
        needs_reply: %{p_yes: 0.82},
        category: %{
          label: "business",
          probs: [{"business", 0.8}, {"personal", 0.15}, {"newsletter", 0.05}],
          # Recomputed (p_max - 1/K)/(1 - 1/K); the fixture's 0.99 is ignored (F01.3).
          confidence: (0.8 - 1 / 3) / (1 - 1 / 3)
        },
        urgency: %{
          expected: 2.15,
          probs: [
            {"none", 0.05},
            {"low", 0.15},
            {"medium", 0.45},
            {"high", 0.3},
            {"critical", 0.05}
          ],
          confidence: 0.55
        }
      })
    end

    test "kev-2026-10 maps to F01 result maps" do
      serve(fixture!("kev-2026-10.json"))
      assert {:ok, results} = ask(@loopback)

      assert_close(comparable(results), %{
        needs_reply: %{p_yes: 0.11},
        category: %{
          label: "personal",
          probs: [{"business", 0.3}, {"personal", 0.6}, {"newsletter", 0.1}],
          confidence: (0.6 - 1 / 3) / (1 - 1 / 3)
        },
        urgency: %{
          expected: 0.7,
          probs: [
            {"none", 0.5},
            {"low", 0.35},
            {"medium", 0.1},
            {"high", 0.05},
            {"critical", 0.0}
          ],
          confidence: 0.31
        }
      })
    end

    test "results name the HTTP adapter as backend and never surface usage or cost (F02.5)" do
      serve(fixture!("strands-decider-2026-10.json"))
      assert {:ok, results} = ask(@loopback)

      for {_name, result} <- results do
        assert result.backend == HTTP
        refute Map.has_key?(result, :usage)
        refute Map.has_key?(result, :cost)
      end
    end
  end

  # ---------- F03.2 ----------

  describe "F03.2 base_url host policy" do
    test "loopback base_url is accepted" do
      serve(fixture!("strands-decider-2026-10.json"))
      assert {:ok, _} = ask(@loopback)
    end

    test "tailnet (100.64.0.0/10) base_url is accepted" do
      serve(fixture!("strands-decider-2026-10.json"))
      assert {:ok, _} = ask(@tailnet)
    end

    test "a 100.x address outside the tailnet range is refused" do
      serve(fixture!("strands-decider-2026-10.json"))
      assert {:error, {:remote_refused, "100.200.1.1"}} = ask(@outside_tailnet)
      refute_received {:request, _, _, _}
    end

    test "a remote host is refused before any request is made" do
      serve(fixture!("strands-decider-2026-10.json"))
      assert {:error, {:remote_refused, "example.com"}} = ask(@remote)
      refute_received {:request, _, _, _}
    end

    test "a remote host is accepted with allow_remote: true" do
      serve(fixture!("strands-decider-2026-10.json"))
      assert {:ok, _} = ask(@remote, allow_remote: true)
    end
  end

  # ---------- F03.3 ----------

  describe "F03.3 schema violations are never a partial {:ok, ...}" do
    for {fixture, malformation} <- [
          {"malformed-missing-question-2026-10.json", "a missing answer"},
          {"malformed-duplicate-answer-2026-10.json", "a duplicated answer"},
          {"malformed-label-outside-set-2026-10.json", "a label outside the sent option set"}
        ] do
      @fixture fixture
      test "#{malformation} is {:error, {:schema_violation, detail}}" do
        serve(fixture!(@fixture))
        result = ask(@loopback)

        refute match?({:ok, _}, result), "got a partial result: #{inspect(result)}"
        assert {:error, {:schema_violation, _detail}} = result
      end
    end
  end

  # ---------- F03.4 ----------

  describe "F03.4 transport failures" do
    setup do
      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:kerf, :decide, :error],
          &__MODULE__.handle_telemetry/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "non-2xx, timeout and connection refused map to distinct reasons and each emits [:kerf, :decide, :error]" do
      serve(~s({"error": "internal"}), 500)
      assert {:error, {:http_status, 500}} = ask(@loopback)
      assert_receive {:telemetry, [:kerf, :decide, :error], _, %{reason: {:http_status, 500}}}

      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))
      assert {:error, :timeout} = ask(@loopback)
      assert_receive {:telemetry, [:kerf, :decide, :error], _, %{reason: :timeout}}

      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, :econnrefused} = ask(@loopback)
      assert_receive {:telemetry, [:kerf, :decide, :error], _, %{reason: :econnrefused}}
    end
  end
end
