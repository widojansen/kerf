defmodule Mix.Tasks.Kerf.Eval.Replay do
  @shortdoc "Replay the frozen golden set through a classifier endpoint (SPEC_D)"
  @moduledoc """
  Lightning Phase 1 replay harness
  (docs/superpowers/specs/SPEC_D_lightning_phase1_eval.md).

  ## Usage

      mix kerf.eval.replay --input <golden.jsonl> --output <results.jsonl> \\
        --endpoint <url> --model <served-model-name> --tag <run-tag> \\
        [--thinking on|off] [--temperature T --top-p P] [--limit N]

  Read-only with respect to production state (SPEC_D §2): never writes
  `kb_feedback` rows, never enqueues Oban jobs, never touches the Router.
  Classifies through the real `Kerf.Agents.EmailTriage.Classifier.classify/2`
  seam, against a harness-owned, uniquely-named `VLLMProvider` +
  `RateLimiter` pair pointed at `--endpoint` — never the app-supervised
  `Kerf.LLM.VLLMProvider` / `Kerf.LLM.RateLimiter` singletons, even though
  `mix app.start` boots them too (production's `VLLM_URL`/`VLLM_MODEL`).

  Known gap: `--top-p` is parsed but not currently wired into the request —
  `Kerf.LLM.VLLMProvider.build_request_body/4` has no `top_p` passthrough
  (out of this task's authorized scope, which added only
  `chat_template_kwargs`). C1's model-card sampling config
  ("temp 1.0 / top-p 0.95") will only apply temperature until that gap is
  closed.
  """
  use Mix.Task

  alias Kerf.Eval.Replay
  alias Kerf.LLM.{RateLimiter, VLLMProvider}
  alias Kerf.StructuredOutput.Builtins

  def run(argv) do
    Mix.Task.run("app.start")

    case Replay.parse_args(argv) do
      {:ok, config} -> do_run(config)
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp do_run(config) do
    case Replay.parse_golden_jsonl(config.input) do
      {:ok, parsed} ->
        {valid, parse_errors} = split_parsed(parsed)
        valid = maybe_limit(valid, config.limit)

        provider_fn = build_provider_fn(config)
        results = Replay.classify_batch(valid, config.tag, provider_fn, config.model)

        manifest =
          Replay.build_run_manifest(
            input_path: config.input,
            endpoint: config.endpoint,
            model: config.model,
            run_tag: config.tag,
            temperature: config.temperature,
            top_p: config.top_p,
            thinking: config.thinking
          )

        write_output(config.output, manifest, results, parse_errors)

        Mix.shell().info(
          "[kerf.eval.replay] #{length(results)} classified, " <>
            "#{length(parse_errors)} input-parse errors -> #{config.output}"
        )

      {:error, reason} ->
        Mix.raise("failed to read golden set at #{config.input}: #{inspect(reason)}")
    end
  end

  defp split_parsed(parsed) do
    {ok, err} =
      Enum.reduce(parsed, {[], []}, fn
        {:ok, record}, {ok, err} -> {[record | ok], err}
        {:error, reason}, {ok, err} -> {ok, [reason | err]}
      end)

    {Enum.reverse(ok), Enum.reverse(err)}
  end

  defp maybe_limit(records, nil), do: records
  defp maybe_limit(records, limit), do: Enum.take(records, limit)

  defp write_output(path, manifest, results, parse_errors) do
    parse_error_lines =
      Enum.map(parse_errors, fn %{line: line, reason: reason} ->
        Jason.encode!(%{type: "parse_error", line: line, error: reason})
      end)

    lines = [Jason.encode!(manifest)] ++ Enum.map(results, &Jason.encode!/1) ++ parse_error_lines

    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  # Harness-owned VLLMProvider + RateLimiter, never the app-supervised
  # singletons (SPEC_D §2's read-only-w.r.t.-production-state constraint,
  # and Stage 1 read-back flag 2: sharing the production rate limiter's
  # budget counters would contaminate live traffic and vice versa).
  defp build_provider_fn(config) do
    suffix = System.unique_integer([:positive])
    rl_name = :"kerf_eval_rl_#{suffix}"
    vllm_name = :"kerf_eval_vllm_#{suffix}"

    {:ok, _} =
      RateLimiter.start_link(
        name: rl_name,
        max_requests_per_minute: 10_000,
        max_tokens_per_minute: 10_000_000
      )

    {:ok, _} =
      VLLMProvider.start_link(name: vllm_name, base_url: config.endpoint, rate_limiter: rl_name)

    schema_def = fetch_schema!(:email_classification)
    thinking_opts = chat_template_kwargs_opt(config.thinking)
    temperature = config.temperature

    fn :email_classification, model, messages, classifier_opts ->
      vllm_wrapper = fn inner_model, inner_messages, inner_opts ->
        request_opts =
          inner_opts
          |> Keyword.merge(thinking_opts)
          |> maybe_put(:temperature, temperature)

        case VLLMProvider.complete(vllm_name, inner_model, inner_messages, request_opts) do
          {:ok, %{type: :text, content: content, usage: usage}} = ok ->
            Replay.stash_raw_response(content, usage)
            ok

          other ->
            other
        end
      end

      Kerf.StructuredOutput.complete_with_schema(
        schema_def,
        model,
        messages,
        Keyword.merge(classifier_opts, provider_fn: vllm_wrapper)
      )
    end
  end

  defp chat_template_kwargs_opt(:off), do: [chat_template_kwargs: %{"enable_thinking" => false}]
  defp chat_template_kwargs_opt(:on), do: [chat_template_kwargs: %{"enable_thinking" => true}]
  defp chat_template_kwargs_opt(nil), do: []

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp fetch_schema!(name) do
    {^name, schema} = Enum.find(Builtins.schemas(), fn {schema_name, _} -> schema_name == name end)
    schema
  end
end
