defmodule ExClaw.Security.ShellSandbox do
  @moduledoc """
  Filters shell commands to block dangerous operations.
  """
  use GenServer

  # Each entry is {compiled_regex, denial_reason}.
  # Patterns are checked in order; the first match wins.
  # All reasons must contain "blocked" — one test asserts on that substring.
  @blocked_patterns [
    # --- Destructive filesystem ---
    # \s+ absorbs any number of spaces between "rm" and the flags,
    # defeating the space-padding evasion trick ("rm  -rf  /").
    {~r/\brm\s+-\S*[rf]/,
     "destructive rm command is blocked"},

    # mkfs.* variants (mkfs.ext4, mkfs.vfat, etc.) all start with "mkfs".
    {~r/\bmkfs\b/,
     "filesystem formatting command is blocked"},

    # dd writing to a raw device path — legitimate dd (copying files) wouldn't
    # use /dev/ as the output destination.
    {~r/\bdd\b.*\bof=\/dev\//,
     "dd write to block device is blocked"},

    # --- Remote code execution via pipe-to-shell ---
    # curl/wget output piped directly into a shell interpreter runs arbitrary
    # code fetched from the network.
    {~r/\|\s*(bash|sh|zsh|fish|ksh|csh)\b/,
     "pipe to shell interpreter is blocked"},

    # Backtick variant: "curl url | `bash`" — the backtick opens a subshell.
    # This bypasses a naive "|bash" check because the literal string is "|`bash`".
    {~r/\|[^|]*`(bash|sh|zsh|fish)\b/,
     "backtick shell execution via pipe is blocked"},

    # --- Network backdoors ---
    # nc -e /bin/sh spawns a shell connected to a remote host.
    # We block the -e flag specifically rather than nc altogether,
    # to leave room for safe nc uses in future (e.g. port probing in CI).
    {~r/\bnc\b.*\s-e\b/,
     "netcat reverse shell (-e flag) is blocked"},

    # ncat is the Nmap successor to nc; block it outright — no safe subset
    # is expected in this sandbox environment.
    {~r/\bncat\b/,
     "ncat is blocked"},

    # --- Privilege escalation ---
    # chmod/chown/sudo/su can escalate privileges or modify ownership of files
    # outside the workspace. All are blocked unconditionally in the sandbox.
    {~r/\bchmod\b/, "chmod is blocked"},
    {~r/\bchown\b/, "chown is blocked"},
    {~r/\bsudo\b/,  "sudo is blocked"},
    {~r/\bsu\b/,    "su is blocked"},

    # --- Sensitive system path access ---
    # /etc holds system configuration (passwd, shadow, sudoers, crontab, etc.).
    # /proc exposes kernel and process state, including environment variables
    # of running processes which may contain secrets.
    {~r/\/etc\//, "access to /etc is blocked"},
    {~r/\/proc\//, "access to /proc is blocked"},

    # ".." in a command argument is a traversal attempt toward system paths.
    {~r/\.\./, "path traversal in command is blocked"},

    # --- Resource abuse ---
    # The Bash fork bomb :(){ :|:& };: defines a function named ":" that
    # recursively forks itself. The signature "(){" (empty param list with
    # opening brace) is distinctive enough to block the pattern reliably.
    {~r/:\s*\(\s*\)\s*\{/,
     "fork bomb pattern is blocked"},

    # An infinite loop consumes CPU/memory until the process is killed.
    # "while true" is the canonical form; "while :;" is an equivalent that
    # could be added here if needed in future.
    {~r/while\s+true/,
     "infinite loop is blocked"},
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Only shell_exec commands need sandboxing; all other tools pass through.
  def check("shell_exec", %{command: command}) do
    started_at = System.monotonic_time(:microsecond)

    result =
      case Enum.find(@blocked_patterns, fn {pattern, _} -> Regex.match?(pattern, command) end) do
        nil              -> :ok
        {_, reason}      -> {:denied, reason}
      end

    duration_us = System.monotonic_time(:microsecond) - started_at
    maybe_log_denial(result, "ShellSandbox", %{command: String.slice(command, 0, 200)})
    emit_telemetry(result, "shell_exec", duration_us)
    result
  end

  def check(_tool_name, _input), do: :ok

  defp maybe_log_denial({:denied, reason}, module, input_preview) do
    try do
      ExClaw.Dashboard.EventLog.log(:security_denial, %{
        module: module,
        reason: reason,
        input_preview: String.slice(inspect(input_preview), 0, 200),
        timestamp: DateTime.utc_now()
      })
    rescue
      _ -> :ok
    end
  end

  defp maybe_log_denial(:ok, _module, _input), do: :ok

  defp emit_telemetry(result, tool_name, duration_us) do
    try do
      {security_result, error_message} =
        case result do
          :ok -> {"ok", nil}
          {:denied, reason} -> {"denied", reason}
        end

      ExClaw.Telemetry.emit(:security_check, %{
        module: "ShellSandbox",
        tool_name: tool_name,
        security_result: security_result,
        error_message: error_message,
        duration_ms: div(duration_us, 1000)
      })
    rescue
      _ -> :ok
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}
end
