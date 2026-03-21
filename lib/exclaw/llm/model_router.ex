defmodule ExClaw.LLM.ModelRouter do
  @moduledoc """
  Routes LLM completion requests to the correct backend based on model name.

  Each route is a {regex, backend_name} tuple evaluated in order --
  first match wins. Enables Anthropic + multiple Ollama models simultaneously
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

  defp dispatch(backend, model, messages, opts) do
    if ollama_backend?(backend) do
      ExClaw.LLM.OllamaProvider.complete(backend, model, messages, opts)
    else
      ExClaw.LLM.Provider.complete(backend, model, messages, opts)
    end
  end

  defp ollama_backend?(backend) do
    with pid when pid != nil <- Process.whereis(backend),
         {:dictionary, dict} <- Process.info(pid, :dictionary),
         {mod, _, _}         <- Keyword.get(dict, :"$initial_call") do
      mod == ExClaw.LLM.OllamaProvider
    else
      _ -> false
    end
  end
end
