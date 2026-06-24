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

  @spec build(Context.t(), atom(), keyword()) :: String.t()
  def build(context, reason, opts \\ [])

  def build(_context, _reason, _opts) do
    raise "not implemented: SummaryBuilder.build/3"
  end

  @spec fallback(Context.t()) :: String.t()
  def fallback(_context) do
    raise "not implemented: SummaryBuilder.fallback/1"
  end
end
