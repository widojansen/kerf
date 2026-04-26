defmodule Kerf.LLM.ModelRouter do
  @moduledoc """
  Routes LLM completion requests to the correct backend based on model name.

  Each route is a {regex, backend_name} tuple evaluated in order --
  first match wins. Enables Anthropic + vLLM + Ollama simultaneously
  with zero changes to Session, CLI, or Scheduler callers.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def complete(router \\ __MODULE__, model, messages, opts \\ []) do
    GenServer.call(router, {:complete, model, messages, opts}, 120_000)
  end

  def list_routes(router \\ __MODULE__) do
    GenServer.call(router, :list_routes)
  end

  def add_route(router \\ __MODULE__, pattern, backend) do
    GenServer.call(router, {:add_route, pattern, backend})
  end

  def remove_route(router \\ __MODULE__, pattern) do
    GenServer.call(router, {:remove_route, pattern})
  end

  @impl true
  def init(opts) do
    {:ok, %{routes: Keyword.get(opts, :routes, [])}}
  end

  @impl true
  def handle_call({:complete, model, messages, opts}, _from, state) do
    result =
      case find_backend(state.routes, model) do
        {:ok, backend} -> dispatch(backend, model, messages, opts)
        :error         -> {:error, "no route for model: " <> model}
      end

    {:reply, result, state}
  end

  def handle_call(:list_routes, _from, state),
    do: {:reply, state.routes, state}

  def handle_call({:add_route, pattern, backend}, _from, state) do
    {:reply, :ok, %{state | routes: state.routes ++ [{pattern, backend}]}}
  end

  def handle_call({:remove_route, pattern}, _from, state) do
    routes = Enum.reject(state.routes, fn {p, _} -> p.source == pattern.source end)
    {:reply, :ok, %{state | routes: routes}}
  end

  defp find_backend(routes, model) do
    case Enum.find(routes, fn {pat, _} -> Regex.match?(pat, model) end) do
      {_, backend} -> {:ok, backend}
      nil          -> :error
    end
  end

  # Dispatch to the correct provider module based on what's registered.
  # All three providers share the same complete/4 API shape.
  defp dispatch(backend, model, messages, opts) do
    case backend_module(backend) do
      Kerf.LLM.VLLMProvider ->
        Kerf.LLM.VLLMProvider.complete(backend, model, messages, opts)

      Kerf.LLM.OllamaProvider ->
        Kerf.LLM.OllamaProvider.complete(backend, model, messages, opts)

      _ ->
        Kerf.LLM.Provider.complete(backend, model, messages, opts)
    end
  end

  # Detect the module of a registered GenServer by inspecting $initial_call.
  defp backend_module(backend) do
    with pid when pid != nil <- Process.whereis(backend),
         {:dictionary, dict} <- Process.info(pid, :dictionary),
         {mod, _, _}         <- Keyword.get(dict, :"$initial_call") do
      mod
    else
      _ -> nil
    end
  end
end
