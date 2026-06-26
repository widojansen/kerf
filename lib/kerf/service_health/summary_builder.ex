defmodule Kerf.ServiceHealth.SummaryBuilder do
  @moduledoc """
  Builds the plain-text alert summary — the Kerf port of the Python
  `generate_summary` (`docs/specs/izimonitoring_legacy/health_monitor.py`). See
  `docs/specs/SPEC_03_MONITOR_WORKER.md`.

  * `reason == :recovered` → fixed one-liner, no LLM call.
  * otherwise → call the injected `:llm_fn` (`(model, messages, opts)`,
    defaulting to a wrapper over `Kerf.LLM.VLLMProvider.complete/4`, model
    "nemotron-cascade-2") with a prompt interpolating status, alerts, anomalies,
    request_rps, service_error_rate, queue total/high_wait/at_ceiling, and the
    baseline service error rate.

  PROMPT CAVEAT: the prompt does NOT contain `/no_think` (a Qwen-3 token); Kerf's
  Nemotron-Cascade-2 uses the step3 parser. Response handling: if a `</think>`
  appears, take the content AFTER it (Python's `split("</think>")[-1]`). Note
  `Kerf.LLM.Sanitize.strip_thinking/1` only strips PAIRED `<think>...</think>`
  blocks, so it does NOT handle Nemotron's closer-only emission — hence the
  hand-rolled split here.

  `build/2` falls back to `fallback/1` (a pure assembly from `alerts[]`/
  `anomalies[]` messages) when the LLM call errors OR returns an unusably short
  response (Python's `len(response) > 10`).

  RED SKELETON: bodies raise; GREEN implements.
  """

  alias Kerf.ServiceHealth.Context

  @recovered_summary "izi2connect recovered. All systems healthy."
  @default_model "nemotron-cascade-2"

  @spec build(Context.t(), atom(), keyword()) :: String.t()
  def build(context, reason, opts \\ [])

  # Recovery doesn't need inference — fixed one-liner, no LLM call.
  def build(_context, :recovered, _opts), do: @recovered_summary

  def build(%Context{} = context, _reason, opts) do
    llm_fn = Keyword.get(opts, :llm_fn, &default_llm_fn/3)
    messages = [%{role: "user", content: build_prompt(context)}]

    case llm_fn.(@default_model, messages, []) do
      {:ok, %{content: content}} when is_binary(content) ->
        summary = content |> after_think() |> String.trim()
        # Strict length gate AFTER </think> stripping (order matters): 10 -> fallback.
        if String.length(summary) > 10, do: summary, else: fallback(context)

      _ ->
        fallback(context)
    end
  end

  @spec fallback(Context.t()) :: String.t()
  def fallback(%Context{} = context) do
    # Trigger on LIST presence (matching Python's `if alert_msgs:`), not message non-emptiness.
    parts =
      []
      |> maybe_part("Alerts: ", context.alerts)
      |> maybe_part("Anomalies: ", context.anomalies)

    case parts do
      [] -> "Status: #{context.status}"
      parts -> parts |> Enum.reverse() |> Enum.join(". ")
    end
  end

  # --- internal ---

  defp maybe_part(parts, _label, []), do: parts

  defp maybe_part(parts, label, list) when is_list(list) do
    messages = Enum.map(list, fn item -> Map.get(item, "message", "") end)
    [label <> Enum.join(messages, "; ") | parts]
  end

  # Nemotron-Cascade-2 (step3 parser) emits a closer-only `</think>` with no opener,
  # so `Kerf.LLM.Sanitize.strip_thinking/1` (which strips PAIRED `<think>...</think>`
  # blocks) does NOT apply here. Reproduce Python's `split("</think>")[-1]`.
  defp after_think(content), do: content |> String.split("</think>") |> List.last()

  defp build_prompt(%Context{} = context) do
    current = context.current
    queues = current.queues
    baseline_error_rate = get_in(context.baseline.services, ["averages", "error_rate"]) || "unknown"

    """
    You are a concise production monitoring assistant. Write a Telegram alert in 2-4 sentences. Include key numbers. No markdown formatting, no headers, no bullet points. Plain text only.

    Status: #{context.status}
    Alerts: #{Jason.encode!(context.alerts)}
    Anomalies: #{Jason.encode!(context.anomalies)}
    Web: #{current.request_rps} RPS, service error rate #{current.service_error_rate}%
    Queues: #{queues.total} total, #{queues.high_wait} high wait, #{queues.at_ceiling} at ceiling
    Baseline service error rate: #{baseline_error_rate}%

    Write ONLY the plain text alert message.
    """
  end

  # Explicit wrapper, mirroring Enrich.default_provider/3 — NEVER &VLLMProvider.complete/3
  # (that capture hits the default-arg ambiguity trap).
  defp default_llm_fn(model, messages, opts) do
    Kerf.LLM.VLLMProvider.complete(Kerf.LLM.VLLMProvider, model, messages, opts)
  end
end
