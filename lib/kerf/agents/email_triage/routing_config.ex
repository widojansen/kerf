defmodule Kerf.Agents.EmailTriage.RoutingConfig do
  @moduledoc """
  Holds the active email-routing rule set and reloads it on edit (spec §4.6).

  Two paths are consulted:

    * `:override_path` (default `/opt/kerf/email_routing.exs`) — operator-owned host file
    * `:default_path`  (default `priv/email_routing.exs`)      — release-shipped baseline

  Override wins if present and valid. If the override is invalid at boot, the
  release default is loaded and an error telemetry event is emitted. If both
  paths fail validation, `init/1` returns `{:stop, _}` so the supervisor sees
  the fault rather than running with empty routing state.

  After boot, a single FileSystem watcher is subscribed on `Path.dirname(override_path)`.
  File events with `Path.basename == Path.basename(override_path)` trigger a
  reload attempt. Successful reloads emit `[:kerf, :routing_config, :reloaded]`;
  failed reloads emit `[:kerf, :routing_config, :error]` and leave in-memory
  state untouched.

  Removing the override file (`rm /opt/kerf/email_routing.exs`) reverts to the
  release default on the next reload — useful for incident recovery.

  `current/1` is a fast in-memory read; no file I/O per call.
  """

  use GenServer
  require Logger

  @valid_actions [:telegram_ping, :telegram_digest, :silent]

  # ---------- public API ----------

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      registered when is_atom(registered) -> GenServer.start_link(__MODULE__, opts, name: registered)
    end
  end

  @spec current(GenServer.server()) :: %{version: String.t(), rules: [map()]}
  def current(name \\ __MODULE__), do: GenServer.call(name, :current)

  # ---------- GenServer callbacks ----------

  @impl true
  def init(opts) do
    override_path = Keyword.fetch!(opts, :override_path)
    default_path = Keyword.fetch!(opts, :default_path)

    case load_initial_config(override_path, default_path) do
      {:ok, config} ->
        {:ok, fs_pid} = start_watcher(override_path)

        state = %{
          config: config,
          override_path: override_path,
          default_path: default_path,
          fs_pid: fs_pid
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, state.config, state}
  end

  @impl true
  def handle_info({:file_event, _watcher, {_path, _events}}, state) do
    # macOS fsevents emits directory-level events (event path = the dir).
    # Linux inotify emits file-level events. We watch only the override's
    # parent directory, so ANY event in there means "the override might
    # have changed" — re-read and reconcile against current state.
    # Reload telemetry fires only on actual content change to suppress
    # spurious events from unrelated activity in /opt/kerf/ (deploy
    # symlink swaps, etc.).
    case reconcile(state) do
      {:changed, new_config} ->
        :telemetry.execute(
          [:kerf, :routing_config, :reloaded],
          %{rules_count: length(new_config.rules)},
          %{path: state.override_path, version: new_config.version}
        )

        {:noreply, %{state | config: new_config}}

      :unchanged ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("[RoutingConfig] reload failed: #{inspect(reason)}")
        emit_error(state.override_path, reason)
        {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher, :stop}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------- private: reconciliation on file event ----------

  defp reconcile(state) do
    load_result =
      if File.exists?(state.override_path) do
        load_and_validate(state.override_path)
      else
        # Override was removed (e.g. `rm /opt/kerf/email_routing.exs`).
        # Fall back to release default — useful for incident recovery.
        load_and_validate(state.default_path)
      end

    current_config = state.config

    case load_result do
      {:ok, ^current_config} -> :unchanged
      {:ok, new_config} -> {:changed, new_config}
      {:error, _} = err -> err
    end
  end

  # ---------- private: loading ----------

  defp load_initial_config(override_path, default_path) do
    cond do
      File.exists?(override_path) ->
        case load_and_validate(override_path) do
          {:ok, config} ->
            {:ok, config}

          {:error, reason} ->
            # Override exists but failed validation: emit error telemetry and
            # fall back to release default at boot.
            Logger.error(
              "[RoutingConfig] override invalid at boot, falling back to default: #{inspect(reason)}"
            )

            emit_error(override_path, reason)
            load_and_validate(default_path)
        end

      true ->
        load_and_validate(default_path)
    end
  end

  defp load_and_validate(path) do
    try do
      {config, _bindings} = Code.eval_file(path)
      validate(config)
    rescue
      e -> {:error, {:eval_error, Exception.message(e)}}
    catch
      kind, reason ->
        {:error, {:eval_error, "#{kind}: #{inspect(reason)}"}}
    end
  end

  # ---------- private: validation ----------

  defp validate(config) when not is_map(config), do: {:error, :not_a_map}

  defp validate(config) when is_map(config) do
    cond do
      not is_map_key(config, :version) ->
        {:error, :missing_version}

      not is_binary(config.version) ->
        {:error, :invalid_version}

      not is_map_key(config, :rules) ->
        {:error, :missing_rules}

      not is_list(config.rules) ->
        {:error, :invalid_rules}

      true ->
        with :ok <- validate_rules(config.rules),
             :ok <- validate_unique_names(config.rules) do
          {:ok, %{version: config.version, rules: config.rules}}
        end
    end
  end

  defp validate_rules(rules) do
    Enum.reduce_while(rules, :ok, fn rule, _acc ->
      case validate_rule(rule) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp validate_rule(rule) when not is_map(rule), do: {:error, {:invalid_rule, rule}}

  defp validate_rule(rule) do
    cond do
      not is_map_key(rule, :name) -> {:error, {:invalid_rule, rule}}
      not is_binary(rule.name) -> {:error, {:invalid_rule, rule}}
      not is_map_key(rule, :match) -> {:error, {:invalid_rule, rule}}
      not is_map(rule.match) -> {:error, {:invalid_rule, rule}}
      not is_map_key(rule, :action) -> {:error, {:invalid_rule, rule}}
      not is_atom(rule.action) -> {:error, {:invalid_rule, rule}}
      rule.action not in @valid_actions -> {:error, {:invalid_action, rule.action}}
      true -> :ok
    end
  end

  defp validate_unique_names(rules) do
    names = Enum.map(rules, & &1.name)
    duplicates = names -- Enum.uniq(names)

    case duplicates do
      [] -> :ok
      dups -> {:error, {:duplicate_rule_names, Enum.uniq(dups)}}
    end
  end

  # ---------- private: watcher + telemetry ----------

  defp start_watcher(override_path) do
    dir = Path.dirname(override_path)
    {:ok, pid} = FileSystem.start_link(dirs: [dir])
    :ok = FileSystem.subscribe(pid)
    {:ok, pid}
  end

  defp emit_error(path, reason) do
    :telemetry.execute(
      [:kerf, :routing_config, :error],
      %{},
      %{path: path, reason: reason}
    )
  end
end
