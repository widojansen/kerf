defmodule Kerf.LLM.Sanitize do
  @moduledoc """
  Sanitisation helpers for LLM output text.

  Currently a single defensive strip for `<think>...</think>` blocks that
  thinking-mode models (vLLM/Qwen3, Nemotron-Cascade-2) may emit. The strip
  is applied at parsing boundaries where the model's reasoning markup
  shouldn't reach a JSON decoder or a downstream consumer.

  See also `Kerf.StructuredOutput.JSONParser` which inlines the same regex
  as part of its text-mode JSON extraction pipeline. The two consumers were
  added at different times; consolidating JSONParser onto this helper is a
  small follow-up.
  """

  @think_block ~r/<think>[\s\S]*?<\/think>/s

  @doc """
  Remove all `<think>...</think>` blocks from a string. Safe on nil and empty.
  """
  @spec strip_thinking(binary() | nil) :: binary()
  def strip_thinking(nil), do: ""
  def strip_thinking(content) when is_binary(content) do
    Regex.replace(@think_block, content, "")
  end
end
