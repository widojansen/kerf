defmodule ExClaw.Channels.CLI do
  @moduledoc """
  Terminal REPL channel for ExClaw.

  Not a GenServer — the CLI is a synchronous blocking REPL.
  The agent loop is already a GenServer (Agent.Session).
  Core logic extracted into testable public functions.
  """

  alias ExClaw.Agent.Supervisor, as: AgentSupervisor
  alias ExClaw.Memory.Store

  @exit_commands ~w(exit quit :q /exit /quit)

  # --- Public API ---

  @doc """
  Start the CLI REPL. Blocks until the user exits.
  """
  def start(opts \\ []) do
    config = Application.get_env(:exclaw, __MODULE__, [])
    group_id = Keyword.get(opts, :group_id, config[:group_id] || "cli")
    model = Keyword.get(opts, :model, config[:model] || "claude-sonnet-4-20250514")

    system_prompt = build_system_prompt(group_id, opts)

    print_banner(group_id, model)

    loop(group_id, Keyword.merge(opts, model: model, system_prompt: system_prompt))
  end

  @doc """
  Returns true if the input is an exit command.
  """
  def exit_command?(input) do
    trimmed = String.trim(input)
    String.downcase(trimmed) in @exit_commands
  end

  @doc """
  Build the system prompt for a group, combining the base prompt
  with any existing MEMORY.md content.
  """
  def build_system_prompt(group_id, opts \\ []) do
    config = Application.get_env(:exclaw, __MODULE__, [])
    base_prompt = Keyword.get(opts, :base_prompt, config[:base_prompt] || "")
    store = Keyword.get(opts, :store, Store)

    memory_content =
      try do
        case Store.load_group(store, group_id) do
          {:ok, ""} -> nil
          {:ok, content} -> content
          {:error, _} -> nil
        end
      catch
        :exit, _ -> nil
      end

    case memory_content do
      nil -> base_prompt
      content -> base_prompt <> "\n\n## Group Memory\n\n" <> content
    end
  end

  @doc """
  Process user input through the agent loop.
  Returns `{:respond, text}` or `{:error, reason}`.
  """
  def process_input(input, group_id, opts \\ []) do
    sup = Keyword.get(opts, :agent_supervisor, AgentSupervisor)
    registry = Keyword.get(opts, :registry, ExClaw.SessionRegistry)
    provider = Keyword.get(opts, :provider, ExClaw.LLM.Provider)
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    system_prompt = Keyword.get(opts, :system_prompt)

    session_opts =
      [provider: provider, model: model]
      |> maybe_put(:system_prompt, system_prompt)

    case AgentSupervisor.handle_message(sup, registry, group_id, input, session_opts) do
      {:ok, text} -> {:respond, text}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Persist a user/assistant exchange to the memory store.
  Never crashes — returns :ok regardless of Store availability.
  """
  def persist_exchange(group_id, user_msg, assistant_msg, opts \\ []) do
    store = Keyword.get(opts, :store, Store)

    try do
      Store.save_message(store, group_id, "user", user_msg)
      Store.save_message(store, group_id, "assistant", assistant_msg)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # --- Private ---

  defp loop(group_id, opts) do
    case IO.gets("you> ") do
      :eof ->
        IO.puts("\nGoodbye!")
        :ok

      {:error, _} ->
        IO.puts("\nGoodbye!")
        :ok

      input ->
        input = String.trim_trailing(input, "\n")

        cond do
          input == "" ->
            loop(group_id, opts)

          exit_command?(input) ->
            IO.puts("Goodbye!")
            :ok

          true ->
            case process_input(input, group_id, opts) do
              {:respond, text} ->
                IO.puts("\nexclaw> #{text}\n")
                persist_exchange(group_id, input, text, opts)

              {:error, reason} ->
                IO.puts("\n[error] #{reason}\n")
            end

            loop(group_id, opts)
        end
    end
  end

  defp print_banner(group_id, model) do
    IO.puts("""

    ExClaw CLI — #{model}
    Group: #{group_id}
    Type 'exit', 'quit', ':q', '/exit', or '/quit' to leave.
    """)
  end

  defp maybe_put(kwlist, _key, nil), do: kwlist
  defp maybe_put(kwlist, key, value), do: Keyword.put(kwlist, key, value)
end
