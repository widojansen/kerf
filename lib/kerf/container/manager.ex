defmodule Kerf.Container.Manager do
  @moduledoc """
  GenServer managing Docker container lifecycle per group.

  Each group gets a persistent container (`sleep infinity` + `docker exec`).
  Containers are lazily created on first tool call and cleaned up on
  session end or application shutdown.

  Docker commands are executed through an injected adapter function for testability.
  """
  use GenServer

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  def ensure_container(name, group_id) do
    GenServer.call(name, {:ensure_container, group_id})
  end

  def exec(name, group_id, command, opts \\ []) do
    GenServer.call(name, {:exec, group_id, command, opts}, :infinity)
  end

  def cleanup(name, group_id) do
    GenServer.call(name, {:cleanup, group_id})
  end

  def cleanup_all(name) do
    GenServer.call(name, :cleanup_all)
  end

  def list_containers(name) do
    GenServer.call(name, :list_containers)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    config = Application.get_env(:kerf, __MODULE__, [])

    workspaces_dir =
      Keyword.get(opts, :workspaces_dir) ||
        Keyword.get(config, :workspaces_dir, "priv/workspaces")

    workspaces_dir = Path.expand(workspaces_dir)

    image =
      Keyword.get(opts, :image) ||
        Keyword.get(config, :image, "kerf-sandbox:latest")

    docker_adapter =
      Keyword.get(opts, :docker_adapter) ||
        Keyword.get(config, :docker_adapter, &default_docker_adapter/1)

    exec_timeout =
      Keyword.get(opts, :exec_timeout) ||
        Keyword.get(config, :exec_timeout, 30_000)

    max_output_size =
      Keyword.get(opts, :max_output_size) ||
        Keyword.get(config, :max_output_size, 102_400)

    container_opts =
      Keyword.get(opts, :container_opts) ||
        Keyword.get(config, :container_opts, [])

    state = %{
      containers: %{},
      workspaces_dir: workspaces_dir,
      image: image,
      docker_adapter: docker_adapter,
      exec_timeout: exec_timeout,
      max_output_size: max_output_size,
      container_opts: container_opts
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:ensure_container, group_id}, _from, state) do
    case do_ensure_container(state, group_id) do
      {:ok, container_name, new_state} ->
        {:reply, {:ok, container_name}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:exec, group_id, command, opts}, _from, state) do
    case do_ensure_container(state, group_id) do
      {:ok, container_name, state} ->
        timeout = Keyword.get(opts, :timeout, state.exec_timeout)
        result = do_exec(state, container_name, command, timeout)
        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:cleanup, group_id}, _from, state) do
    state = do_cleanup(state, group_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:cleanup_all, _from, state) do
    state = do_cleanup_all(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_containers, _from, state) do
    entries =
      Enum.map(state.containers, fn {group_id, info} ->
        %{
          group_id: group_id,
          container_name: info.name,
          created_at: info.created_at
        }
      end)

    {:reply, {:ok, entries}, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_cleanup_all(state)
    :ok
  end

  # --- Private ---

  defp do_ensure_container(state, group_id) do
    safe_id = sanitize_group_id(group_id)

    case Map.get(state.containers, group_id) do
      nil ->
        create_container(state, group_id, safe_id)

      %{name: container_name} ->
        if container_alive?(state, container_name) do
          {:ok, container_name, state}
        else
          # Container is dead — remove and recreate
          docker_rm(state, container_name)
          state = %{state | containers: Map.delete(state.containers, group_id)}
          create_container(state, group_id, safe_id)
        end
    end
  end

  defp create_container(state, group_id, safe_id) do
    workspace_path = Path.join(state.workspaces_dir, safe_id)
    File.mkdir_p!(workspace_path)

    container_name = "kerf-#{safe_id}"

    create_args = build_create_args(state, container_name, workspace_path)

    case state.docker_adapter.(create_args) do
      {_output, 0} ->
        # Start the container
        case state.docker_adapter.(["start", container_name]) do
          {_output, 0} ->
            # Fix workspace ownership so the exec user (1000) can write
            init_workspace(state, container_name)
            info = %{name: container_name, created_at: DateTime.utc_now()}
            new_state = %{state | containers: Map.put(state.containers, group_id, info)}
            {:ok, container_name, new_state}

          {output, _code} ->
            {:error, "docker start failed: #{String.trim(output)}"}
        end

      {output, _code} ->
        {:error, "docker create failed: #{String.trim(output)}"}
    end
  end

  defp init_workspace(state, container_name) do
    # chown workspace to the sandbox user so exec commands can write.
    # Runs as root since the Dockerfile USER is non-root.
    user = Keyword.get(state.container_opts, :user, "1000:1000")
    state.docker_adapter.(["exec", "--user", "root", container_name, "chown", user, "/workspace"])
  end

  defp build_create_args(state, container_name, workspace_path) do
    opts = state.container_opts
    args = ["create", "--name", container_name]

    args = if Keyword.get(opts, :read_only, false), do: args ++ ["--read-only"], else: args

    args =
      case Keyword.get(opts, :network) do
        nil -> args
        net -> args ++ ["--network", net]
      end

    args =
      case Keyword.get(opts, :memory) do
        nil -> args
        mem -> args ++ ["--memory", mem]
      end

    args =
      case Keyword.get(opts, :cpus) do
        nil -> args
        cpus -> args ++ ["--cpus", cpus]
      end

    args =
      case Keyword.get(opts, :pids_limit) do
        nil -> args
        limit -> args ++ ["--pids-limit", to_string(limit)]
      end

    args =
      Enum.reduce(Keyword.get(opts, :cap_drop, []), args, fn cap, acc ->
        acc ++ ["--cap-drop", cap]
      end)

    args =
      Enum.reduce(Keyword.get(opts, :cap_add, []), args, fn cap, acc ->
        acc ++ ["--cap-add", cap]
      end)

    args =
      Enum.reduce(Keyword.get(opts, :security_opt, []), args, fn opt, acc ->
        acc ++ ["--security-opt", opt]
      end)

    args =
      Enum.reduce(Keyword.get(opts, :tmpfs, []), args, fn tmpfs, acc ->
        acc ++ ["--tmpfs", tmpfs]
      end)

    # Note: --user is NOT set on create. The container's sleep process runs
    # as root (harmless). After start, init_workspace chowns /workspace to
    # the sandbox user, and all docker exec commands use --user.

    args ++ [
      "-v", "#{workspace_path}:/workspace",
      "-w", "/workspace",
      state.image,
      "sleep", "infinity"
    ]
  end

  defp container_alive?(state, container_name) do
    case state.docker_adapter.(["inspect", "-f", "{{.State.Running}}", container_name]) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  end

  defp do_exec(state, container_name, command, _timeout) do
    user = Keyword.get(state.container_opts, :user, "1000:1000")
    args = ["exec", "--user", user, container_name, "sh", "-c", command]

    case state.docker_adapter.(args) do
      {output, 0} ->
        {:ok, maybe_truncate(output, state.max_output_size)}

      {output, code} ->
        {:error, "exit code #{code}: #{String.trim(output)}"}
    end
  end

  defp maybe_truncate(output, max_size) when byte_size(output) <= max_size, do: output

  defp maybe_truncate(output, max_size) do
    truncated = binary_part(output, 0, max_size)
    truncated <> "\n... (output truncated)"
  end

  defp do_cleanup(state, group_id) do
    case Map.get(state.containers, group_id) do
      nil ->
        state

      %{name: container_name} ->
        docker_rm(state, container_name)
        %{state | containers: Map.delete(state.containers, group_id)}
    end
  end

  defp do_cleanup_all(state) do
    Enum.each(state.containers, fn {_group_id, %{name: container_name}} ->
      docker_rm(state, container_name)
    end)

    %{state | containers: %{}}
  end

  defp docker_rm(state, container_name) do
    try do
      state.docker_adapter.(["rm", "-f", container_name])
    rescue
      _ -> :ok
    end
  end

  defp sanitize_group_id(group_id) do
    group_id
    |> String.replace(~r/[^a-zA-Z0-9_\-]/, "_")
  end

  defp default_docker_adapter(args) do
    System.cmd("docker", args, stderr_to_stdout: true)
  end
end
