defmodule ExClaw.Security.PromptGuard do
  @moduledoc """
  Detects prompt injection attempts in user input and tool arguments.
  Scans all string values in the input map, not just the primary text field.
  """
  use GenServer

  # Each entry is {compiled_regex, denial_reason}.
  # All reasons contain "injection" — one test asserts on that substring.
  @injection_patterns [
    # --- System prompt / instruction override ---
    # The canonical jailbreak opener. Variations include "ignore all previous
    # instructions", "ignore the above instructions", etc. The flexible pattern
    # absorbs common filler words between "ignore" and "instructions".
    {~r/ignore\s+(all\s+|previous\s+)*instructions/i,
     "prompt injection detected: instruction override attempt"},

    # Synonym variant — "disregard" is used to sidestep "ignore" keyword filters.
    {~r/disregard\s+(your\s+)?instructions/i,
     "prompt injection detected: instruction override attempt"},

    # "[SYSTEM]" pseudo-tag impersonates a privileged system channel.
    # It is not a real API delimiter but is recognised by some models that
    # have been fine-tuned on chat templates using bracket notation.
    {~r/\[SYSTEM\]/i,
     "prompt injection detected: fake [SYSTEM] tag"},

    # "Override your programming" is a common framing used to convince the
    # model to abandon its guidelines by appealing to its self-image.
    {~r/override\s+(your\s+)?programming/i,
     "prompt injection detected: programming override attempt"},

    # --- Role confusion attacks ---
    # "###SYSTEM###" mimics delimiter conventions used in some chat templates.
    # Placing it in user input attempts to inject a fake system-level message.
    {~r/###\s*SYSTEM\s*###/i,
     "prompt injection detected: fake ###SYSTEM### marker"},

    # Writing "Assistant: ... User: ..." inside a user turn confuses models
    # that format context with role prefixes by injecting a fake assistant
    # turn followed by a new user instruction.
    {~r/\bAssistant:\s*.+\bUser:/i,
     "prompt injection detected: fake conversation role injection"},

    # Closing a supposed "user" XML tag and opening a "system" tag attempts
    # to escape the user context in models that use XML role delimiters.
    {~r/<\/?(system|user|assistant|admin|role|prompt)\b/i,
     "prompt injection detected: XML role tag injection"},

    # A markdown heading containing "SYSTEM" imitates a system instruction
    # block in models that parse markdown structure for context boundaries.
    # The `m` flag makes `^` match the start of any line within the string.
    {~r/^#+\s+SYSTEM\b/im,
     "prompt injection detected: markdown system heading injection"},

    # --- Encoding-based attacks ---
    # "Decode and execute" paired with a long base64-like token is a common
    # technique for smuggling instructions past keyword-based filters. We
    # require both the action verb and a plausibly base64-length string (>=20
    # chars of the base64 alphabet) to avoid false positives on normal text.
    {~r/(decode|execute).*[A-Za-z0-9+\/]{20,}={0,2}/i,
     "prompt injection detected: base64-encoded payload with execute context"},

    # "Run this hex payload" instructs the model to interpret and act on
    # hex-encoded content, bypassing readable-text pattern matching.
    {~r/(run|execute|decode).*\bhex\b.*(payload|code|data)/i,
     "prompt injection detected: hex-encoded payload"},

    # --- Data exfiltration prompts ---
    # Asking the model to print its "system prompt" is the most direct attempt
    # to extract the confidential instructions injected by the operator.
    {~r/system\s+prompt/i,
     "prompt injection detected: system prompt exfiltration attempt"},

    # "Full/entire/complete instructions" targets the same information via
    # synonym variation to evade a simple "system prompt" keyword check.
    {~r/(full|entire|complete|whole)\s+(instructions|prompt|directives)/i,
     "prompt injection detected: instruction exfiltration attempt"},

    # Asking for API keys attempts to extract secrets that may be present in
    # the agent's context window or environment.
    {~r/api\s+keys?/i,
     "prompt injection detected: API key exfiltration attempt"},
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Scan every string value in the map, not just the top-level :text field.
  # This prevents attacks that hide the payload in a different field (e.g.
  # %{text: "normal", command: "ignore previous instructions..."}).
  def check(input) when is_map(input) do
    input
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.find_value(:ok, fn value ->
      case find_injection(value) do
        nil         -> false
        {_, reason} -> {:denied, reason}
      end
    end)
  end

  # --- private ---

  defp find_injection(text) do
    Enum.find(@injection_patterns, fn {pattern, _} ->
      Regex.match?(pattern, text)
    end)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}
end
