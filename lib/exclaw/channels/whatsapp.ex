defmodule ExClaw.Channels.WhatsApp do
  @moduledoc """
  WhatsApp channel for ExClaw via Node.js Baileys sidecar.

  Communicates with a Node.js process (whatsapp-bridge/bridge.js) over
  an Erlang Port using newline-delimited JSON on stdin/stdout.

  Not started by default — requires `enabled: true` in config and
  Node.js bridge installed (`cd whatsapp-bridge && npm install`).
  """
  use GenServer
  require Logger

  alias ExClaw.Agent.Supervisor, as: AgentSupervisor
  alias ExClaw.Memory.Store
  alias ExClaw.Tools.Dispatcher

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  @doc "Returns the current connection status."
  def status(name \\ __MODULE__) do
    GenServer.call(name, :status)
  end

  @doc "Send a text message to a WhatsApp JID."
  def send_message(name \\ __MODULE__, jid, text) do
    GenServer.call(name, {:send_message, jid, text})
  end

  @doc "Returns status, user_info, and config."
  def get_info(name \\ __MODULE__) do
    GenServer.call(name, :get_info)
  end

  # --- Pure functions (testable without GenServer) ---

  @doc """
  Derive an ExClaw group_id from a WhatsApp message event.

  DM:    %{"from" => "12345@s.whatsapp.net"} -> "wa_12345"
  Group: %{"from" => "12345-67890@g.us"}     -> "wa_12345-67890_g"
  """
  def derive_group_id(event, prefix) do
    jid = event["from"]

    safe =
      jid
      |> String.replace("@s.whatsapp.net", "")
      |> String.replace("@g.us", "_g")
      |> String.replace(~r/[^a-zA-Z0-9_\-]/, "_")

    "#{prefix}_#{safe}"
  end

  @doc """
  Returns true if this message event should be processed.
  Skips: fromMe, empty/nil text, status@broadcast.
  """
  def should_process_message?(event, _config) do
    cond do
      event["fromMe"] == true -> false
      is_nil(event["text"]) or event["text"] == "" -> false
      event["from"] == "status@broadcast" -> false
      true -> true
    end
  end

  @doc "Parse a JSON line into a map."
  def parse_event(json_line) do
    case Jason.decode(json_line) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "expected JSON object"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Build a send command map for the bridge."
  def build_send_command(jid, text) do
    %{
      "type" => "send",
      "to" => jid,
      "text" => text,
      "id" => "ref_#{System.unique_integer([:positive])}"
    }
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    config = Application.get_env(:exclaw, __MODULE__, [])

    bridge_dir =
      Keyword.get(opts, :bridge_dir) ||
        Keyword.get(config, :bridge_dir, "whatsapp-bridge")

    auth_dir =
      Keyword.get(opts, :auth_dir) ||
        Keyword.get(config, :auth_dir, "priv/whatsapp_auth")

    node_path =
      Keyword.get(opts, :node_path) ||
        Keyword.get(config, :node_path, "node")

    group_id_prefix =
      Keyword.get(opts, :group_id_prefix) ||
        Keyword.get(config, :group_id_prefix, "wa")

    mention_required =
      Keyword.get(opts, :mention_required_in_groups) ||
        Keyword.get(config, :mention_required_in_groups, true)

    model =
      Keyword.get(opts, :model) ||
        Keyword.get(config, :model, "claude-sonnet-4-20250514")

    base_prompt =
      Keyword.get(opts, :base_prompt) ||
        Keyword.get(config, :base_prompt, "You are ExClaw, a personal AI assistant on WhatsApp.")

    port_opener =
      Keyword.get(opts, :port_opener, &default_port_opener/3)

    agent_supervisor =
      Keyword.get(opts, :agent_supervisor, AgentSupervisor)

    registry =
      Keyword.get(opts, :registry, ExClaw.SessionRegistry)

    store =
      Keyword.get(opts, :store, Store)

    provider =
      Keyword.get(opts, :provider, ExClaw.LLM.Provider)

    state = %{
      port: nil,
      status: :starting,
      user_info: nil,
      buffer: "",
      config: %{
        bridge_dir: bridge_dir,
        auth_dir: auth_dir,
        node_path: node_path,
        group_id_prefix: group_id_prefix,
        mention_required: mention_required,
        model: model,
        base_prompt: base_prompt,
        bot_jid: nil
      },
      pending_sends: %{},
      port_opener: port_opener,
      agent_supervisor: agent_supervisor,
      registry: registry,
      store: store,
      provider: provider
    }

    port = open_port(state)
    {:ok, %{state | port: port}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      status: state.status,
      user_info: state.user_info,
      config: state.config
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call({:send_message, jid, text}, _from, state) do
    cmd = build_send_command(jid, text)
    send_to_port(state.port, cmd)
    {:reply, :ok, state}
  end

  # --- Port data handling ---

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    full_line =
      if state.buffer == "" do
        line
      else
        state.buffer <> line
      end

    state = %{state | buffer: ""}
    handle_port_line(full_line, state)
  end

  @impl true
  def handle_info({port, {:data, {:noeol, partial}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> partial}}
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("WhatsApp bridge exited with code #{code}")

    if state.status == :stopped do
      {:noreply, %{state | port: nil}}
    else
      emit_telemetry("bridge_exit", %{code: code})
      Process.send_after(self(), :restart_port, 5_000)
      {:noreply, %{state | port: nil, status: :disconnected}}
    end
  end

  @impl true
  def handle_info(:restart_port, state) do
    Logger.info("Restarting WhatsApp bridge...")
    port = open_port(state)
    {:noreply, %{state | port: port, status: :starting}}
  end

  # Simulate events for testing (no real Port)
  @impl true
  def handle_info({:simulate_event, json_line}, state) do
    handle_port_line(json_line, state)
  end

  # Agent response from spawned process
  @impl true
  def handle_info({:agent_response, jid, group_id, user_text, result}, state) do
    case result do
      {:ok, response_text} ->
        # Send response back via bridge
        cmd = build_send_command(jid, response_text)
        send_to_port(state.port, cmd)

        # Persist exchange
        persist_exchange(group_id, user_text, response_text, state)

      {:error, reason} ->
        Logger.error("Agent error for #{group_id}: #{inspect(reason)}")
    end

    # Stop typing indicator
    send_to_port(state.port, %{"type" => "typing", "jid" => jid, "composing" => false})

    {:noreply, state}
  end

  # Catch-all for unhandled messages (Port messages when port is nil in tests, etc.)
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      send_to_port(state.port, %{"type" => "shutdown"})
      Process.sleep(500)
    end

    :ok
  end

  # --- Private: event dispatch ---

  defp handle_port_line(line, state) do
    case parse_event(line) do
      {:ok, event} ->
        dispatch_event(event, state)

      {:error, reason} ->
        Logger.warning("Failed to parse bridge event: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp dispatch_event(%{"type" => "ready"}, state) do
    Logger.info("WhatsApp bridge ready")
    {:noreply, state}
  end

  defp dispatch_event(%{"type" => "qr", "data" => qr_data}, state) do
    Logger.info("WhatsApp QR code received (scan with phone)")
    emit_telemetry("qr_received", %{data_length: byte_size(qr_data)})
    {:noreply, %{state | status: :waiting_qr}}
  end

  defp dispatch_event(%{"type" => "connected"} = event, state) do
    user_info = event["user"]
    bot_jid = if user_info, do: user_info["id"]
    Logger.info("WhatsApp connected as #{inspect(bot_jid)}")

    config = %{state.config | bot_jid: bot_jid}
    emit_telemetry("connected", %{user: user_info})

    {:noreply, %{state | status: :connected, user_info: user_info, config: config}}
  end

  defp dispatch_event(%{"type" => "disconnected"} = event, state) do
    Logger.warning("WhatsApp disconnected: #{event["reason"]} (code: #{event["code"]})")
    emit_telemetry("disconnected", %{reason: event["reason"], code: event["code"]})
    {:noreply, %{state | status: :disconnected}}
  end

  defp dispatch_event(%{"type" => "logged_out"}, state) do
    Logger.warning("WhatsApp logged out — stopping channel")
    emit_telemetry("logged_out", %{})
    {:stop, :normal, %{state | status: :stopped}}
  end

  defp dispatch_event(%{"type" => "message"} = event, state) do
    if should_process_message?(event, state.config) do
      handle_incoming_message(event, state)
    else
      {:noreply, state}
    end
  end

  defp dispatch_event(%{"type" => "send_result"} = event, state) do
    id = event["id"]

    if event["success"] do
      Logger.debug("Send confirmed: #{id}")
    else
      Logger.warning("Send failed (#{id}): #{event["error"]}")
    end

    {:noreply, state}
  end

  defp dispatch_event(%{"type" => "error"} = event, state) do
    Logger.error("Bridge error: #{event["message"]}")
    emit_telemetry("bridge_error", %{message: event["message"]})
    {:noreply, state}
  end

  defp dispatch_event(event, state) do
    Logger.debug("Unknown bridge event: #{inspect(event["type"])}")
    {:noreply, state}
  end

  # --- Private: message handling ---

  defp handle_incoming_message(event, state) do
    group_id = derive_group_id(event, state.config.group_id_prefix)
    jid = event["from"]
    text = event["text"]

    # Send typing indicator
    send_to_port(state.port, %{"type" => "typing", "jid" => jid, "composing" => true})

    # Mark as read
    send_to_port(state.port, %{
      "type" => "read",
      "jid" => jid,
      "id" => event["id"],
      "participant" => event["participant"]
    })

    # Spawn async handler — Agent.Session serializes per group_id
    parent = self()
    sup = state.agent_supervisor
    registry = state.registry
    provider = state.provider
    model = state.config.model
    base_prompt = state.config.base_prompt
    store = state.store

    spawn(fn ->
      system_prompt = build_system_prompt_for_group(group_id, base_prompt, store)

      container_manager_config =
        Application.get_env(:exclaw, ExClaw.Container.Manager, [])

      workspaces_dir =
        container_manager_config[:workspaces_dir] || "priv/workspaces"

      tool_executor =
        Dispatcher.build_executor(
          container_manager: ExClaw.Container.Manager,
          group_id: group_id,
          workspaces_dir: workspaces_dir
        )

      session_opts = [
        provider: provider,
        model: model,
        system_prompt: system_prompt,
        tool_executor: tool_executor,
        tools: Dispatcher.tool_definitions()
      ]

      result = AgentSupervisor.handle_message(sup, registry, group_id, text, session_opts)
      send(parent, {:agent_response, jid, group_id, text, result})
    end)

    {:noreply, state}
  end

  defp build_system_prompt_for_group(group_id, base_prompt, store) do
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

  defp persist_exchange(group_id, user_msg, assistant_msg, state) do
    try do
      Store.save_message(state.store, group_id, "user", user_msg)
      Store.save_message(state.store, group_id, "assistant", assistant_msg)
    catch
      :exit, _ -> :ok
    end
  end

  # --- Private: Port helpers ---

  defp open_port(state) do
    abs_auth_dir = Path.expand(state.config.auth_dir)

    try do
      state.port_opener.(
        state.config.node_path,
        ["bridge.js"],
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:line, 16_384},
          {:cd, Path.expand(state.config.bridge_dir)},
          {:env, [{~c"EXCLAW_WA_AUTH_DIR", String.to_charlist(abs_auth_dir)}]}
        ]
      )
    rescue
      e ->
        Logger.error("Failed to open WhatsApp bridge Port: #{inspect(e)}")
        nil
    end
  end

  defp send_to_port(nil, _data), do: :ok

  defp send_to_port(port, data) do
    try do
      json = Jason.encode!(data)
      Port.command(port, json <> "\n")
    rescue
      _ -> :ok
    end
  end

  defp default_port_opener(cmd, args, opts) do
    Port.open({:spawn_executable, System.find_executable(cmd)}, [{:args, args} | opts])
  end

  defp emit_telemetry(event_name, metadata) do
    try do
      ExClaw.Telemetry.emit(:channel_event, Map.merge(metadata, %{
        channel: "whatsapp",
        event: event_name
      }))
    rescue
      _ -> :ok
    end
  end
end
