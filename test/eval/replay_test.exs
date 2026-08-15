defmodule Kerf.Eval.ReplayTest do
  @moduledoc """
  SPEC_D §3/§9 — docs/superpowers/specs/SPEC_D_lightning_phase1_eval.md.
  Harness core, tested as plain functions (no live endpoint, no Mix.Task.run).
  """
  use ExUnit.Case, async: true

  alias Kerf.Eval.Replay

  # Golden-set-v1.jsonl shape per the Phase 0 baseline spec §5.3 (outer
  # private docs tree) — sender_domain, not a full address.
  defp golden_line(attrs \\ %{}) do
    Map.merge(
      %{
        "doc_id" => "doc-abc123",
        "stratum" => "llm_fallback",
        "label_prod" => "business",
        "classifier" => "llm_classifier",
        "corrected" => false,
        "subject" => "Q3 renewal terms",
        "sender_domain" => "example.com",
        "body" => "Please review the attached renewal terms before Friday.",
        "inserted_at" => "2026-05-01T10:00:00Z"
      },
      attrs
    )
    |> Jason.encode!()
  end

  defp write_tmp_jsonl!(lines) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kerf_eval_replay_test_#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, Enum.join(lines, "\n"))
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "parse_golden_line/1" do
    test "valid line parses into a doc_id + email map with the prompt builder's fields" do
      assert {:ok, %{doc_id: "doc-abc123", email: email}} = Replay.parse_golden_line(golden_line())
      assert email.subject == "Q3 renewal terms"
      assert email.body_text == "Please review the attached renewal terms before Friday."
      assert email.from.email == "unknown@example.com"
      assert is_nil(email.from.name)
    end

    test "malformed JSON returns an error tuple, not a raise" do
      assert {:error, _reason} = Replay.parse_golden_line("{not json")
    end

    test "missing required field (doc_id) returns an error tuple" do
      line = Jason.encode!(%{"subject" => "no doc id", "body" => "x", "sender_domain" => "x.com"})
      assert {:error, _reason} = Replay.parse_golden_line(line)
    end

    test "missing required field (body) returns an error tuple" do
      line = Jason.encode!(%{"doc_id" => "d1", "subject" => "no body", "sender_domain" => "x.com"})
      assert {:error, _reason} = Replay.parse_golden_line(line)
    end
  end

  describe "parse_golden_jsonl/1" do
    test "parses every valid line in file order" do
      path =
        write_tmp_jsonl!([
          golden_line(%{"doc_id" => "d1", "subject" => "s1"}),
          golden_line(%{"doc_id" => "d2", "subject" => "s2"})
        ])

      assert {:ok, results} = Replay.parse_golden_jsonl(path)
      assert [{:ok, %{doc_id: "d1"}}, {:ok, %{doc_id: "d2"}}] = results
    end

    test "a malformed line in the middle is recorded as an error; surrounding valid lines still parse" do
      path =
        write_tmp_jsonl!([
          golden_line(%{"doc_id" => "d1"}),
          "{not json",
          golden_line(%{"doc_id" => "d3"})
        ])

      assert {:ok, results} = Replay.parse_golden_jsonl(path)
      assert [{:ok, %{doc_id: "d1"}}, {:error, %{line: 2}}, {:ok, %{doc_id: "d3"}}] = results
    end
  end

  describe "build_output_record/1" do
    test "includes all output fields for a successful classification" do
      record =
        Replay.build_output_record(%{
          doc_id: "d1",
          run_tag: "cascade2-prod-settings",
          category_out: "business",
          priority_out: 4,
          raw_response: %{category: "business", priority: 4},
          schema_valid: true,
          latency_ms: 812,
          input_tokens: 150,
          output_tokens: 40,
          error: nil
        })

      assert record.doc_id == "d1"
      assert record.run_tag == "cascade2-prod-settings"
      assert record.category_out == "business"
      assert record.priority_out == 4
      assert record.raw_response == %{category: "business", priority: 4}
      assert record.schema_valid == true
      assert record.latency_ms == 812
      assert record.input_tokens == 150
      assert record.output_tokens == 40
      assert record.error == nil
    end

    test "defaults omitted fields to nil rather than raising" do
      record =
        Replay.build_output_record(%{
          doc_id: "d1",
          run_tag: "t",
          schema_valid: false,
          error: "boom"
        })

      assert record.category_out == nil
      assert record.priority_out == nil
      assert record.raw_response == nil
      assert record.input_tokens == nil
      assert record.output_tokens == nil
      assert record.error == "boom"
    end
  end

  describe "build_run_manifest/1" do
    test "includes endpoint, model, sampling params, thinking flag, and input SHA-256" do
      path =
        Path.join(
          System.tmp_dir!(),
          "kerf_eval_manifest_test_#{System.unique_integer([:positive])}.jsonl"
        )

      content = "{\"doc_id\":\"d1\"}\n"
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      expected_sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      manifest =
        Replay.build_run_manifest(
          input_path: path,
          endpoint: "http://localhost:8001",
          model: "nemotron-3.5-lightning",
          run_tag: "lightning-thinking-off",
          temperature: 1.0,
          top_p: 0.95,
          thinking: false
        )

      assert manifest.endpoint == "http://localhost:8001"
      assert manifest.model == "nemotron-3.5-lightning"
      assert manifest.temperature == 1.0
      assert manifest.top_p == 0.95
      assert manifest.thinking == false
      assert manifest.input_sha256 == expected_sha
    end
  end

  describe "classify_email/5 — provider wiring" do
    @email %{from: %{email: "unknown@example.com", name: nil}, subject: "Test", body_text: "Body"}

    test "calls Classifier.classify/2 with the given provider_fn and model, surfacing category/priority" do
      provider_fn = fn :email_classification, "test-model", _messages, _opts ->
        {:ok,
         %{
           "category" => "business",
           "priority" => 4,
           "action" => "follow_up",
           "confidence" => 0.9,
           "summary" => "Renewal terms"
         }}
      end

      record = Replay.classify_email(@email, "d1", "run-1", provider_fn, "test-model")

      assert record.doc_id == "d1"
      assert record.run_tag == "run-1"
      assert record.category_out == "business"
      assert record.priority_out == 4
      assert record.schema_valid == true
      assert record.error == nil
      assert is_integer(record.latency_ms)
      assert record.latency_ms >= 0
    end

    test "a provider_fn error produces an error record with schema_valid: false" do
      provider_fn = fn :email_classification, _model, _messages, _opts ->
        {:error, {:validation_failed, "category not in enum"}}
      end

      record = Replay.classify_email(@email, "d2", "run-1", provider_fn, "test-model")

      assert record.doc_id == "d2"
      assert record.category_out == nil
      assert record.priority_out == nil
      assert record.schema_valid == false
      refute is_nil(record.error)
    end
  end

  describe "classify_batch/4 — partial-failure tolerance" do
    @records [
      %{doc_id: "d1", email: %{from: %{email: "a@x.com", name: nil}, subject: "s1", body_text: "b1"}},
      %{doc_id: "d2", email: %{from: %{email: "b@x.com", name: nil}, subject: "s2", body_text: "b2"}},
      %{doc_id: "d3", email: %{from: %{email: "c@x.com", name: nil}, subject: "s3", body_text: "b3"}}
    ]

    test "a provider_fn error for one email yields an error record for that email; the batch continues" do
      provider_fn = fn :email_classification, _model, messages, _opts ->
        [%{"content" => content}] = messages

        if content =~ "s2" do
          {:error, "boom"}
        else
          {:ok,
           %{
             "category" => "business",
             "priority" => 3,
             "action" => "follow_up",
             "confidence" => 0.8,
             "summary" => "ok"
           }}
        end
      end

      results = Replay.classify_batch(@records, "run-1", provider_fn, "test-model")

      assert length(results) == 3
      [r1, r2, r3] = results
      assert r1.schema_valid == true
      assert r2.schema_valid == false
      refute is_nil(r2.error)
      assert r3.schema_valid == true
      assert Enum.map(results, & &1.doc_id) == ["d1", "d2", "d3"]
    end

    test "a raising provider_fn for one email yields an error record with the exception message; the batch continues" do
      provider_fn = fn :email_classification, _model, messages, _opts ->
        [%{"content" => content}] = messages

        if content =~ "s2" do
          raise "boom exploded"
        else
          {:ok,
           %{
             "category" => "business",
             "priority" => 3,
             "action" => "follow_up",
             "confidence" => 0.8,
             "summary" => "ok"
           }}
        end
      end

      results = Replay.classify_batch(@records, "run-1", provider_fn, "test-model")

      assert length(results) == 3
      [r1, r2, r3] = results
      assert r1.schema_valid == true
      assert r2.schema_valid == false
      assert r2.error =~ "boom exploded"
      assert r3.schema_valid == true
      assert Enum.map(results, & &1.doc_id) == ["d1", "d2", "d3"]
    end
  end

  describe "parse_args/1 — CLI contract (SPEC_D §2)" do
    @required ~w(--input golden.jsonl --output results.jsonl --endpoint http://localhost:8001 --model nemotron-3.5-lightning --tag lightning-thinking-off)

    test "valid argv (required flags only) parses into a config map with correct types and nil defaults" do
      assert {:ok, config} = Replay.parse_args(@required)

      assert config.input == "golden.jsonl"
      assert config.output == "results.jsonl"
      assert config.endpoint == "http://localhost:8001"
      assert config.model == "nemotron-3.5-lightning"
      assert config.tag == "lightning-thinking-off"
      assert config.thinking == nil
      assert config.temperature == nil
      assert config.top_p == nil
      assert config.limit == nil
    end

    test "optional flags are parsed with correct types when provided" do
      argv =
        @required ++
          ~w(--thinking off --temperature 1.0 --top-p 0.95 --limit 50)

      assert {:ok, config} = Replay.parse_args(argv)

      assert config.thinking == :off
      assert config.temperature == 1.0
      assert config.top_p == 0.95
      assert config.limit == 50
      assert is_float(config.temperature)
      assert is_float(config.top_p)
      assert is_integer(config.limit)
    end

    test "--thinking on parses to the :on atom" do
      argv = @required ++ ~w(--thinking on)
      assert {:ok, config} = Replay.parse_args(argv)
      assert config.thinking == :on
    end

    test "missing --input returns a clear error naming the flag" do
      argv = ~w(--output r.jsonl --endpoint http://x --model m --tag t)
      assert {:error, reason} = Replay.parse_args(argv)
      assert reason =~ "input"
    end

    test "missing --output returns a clear error naming the flag" do
      argv = ~w(--input g.jsonl --endpoint http://x --model m --tag t)
      assert {:error, reason} = Replay.parse_args(argv)
      assert reason =~ "output"
    end

    test "missing --endpoint returns a clear error naming the flag" do
      argv = ~w(--input g.jsonl --output r.jsonl --model m --tag t)
      assert {:error, reason} = Replay.parse_args(argv)
      assert reason =~ "endpoint"
    end

    test "missing --model returns a clear error naming the flag" do
      argv = ~w(--input g.jsonl --output r.jsonl --endpoint http://x --tag t)
      assert {:error, reason} = Replay.parse_args(argv)
      assert reason =~ "model"
    end

    test "missing --tag returns a clear error naming the flag" do
      argv = ~w(--input g.jsonl --output r.jsonl --endpoint http://x --model m)
      assert {:error, reason} = Replay.parse_args(argv)
      assert reason =~ "tag"
    end
  end
end
