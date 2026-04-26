defmodule Kerf.Tools.Registry do
  @moduledoc """
  Dynamic tool registry backed by ETS.

  Tools register with name, description, schema, module, and function.
  Reads go directly through ETS (public table) for performance.
  Writes are serialized through the GenServer.
  """
  use GenServer

  @required_fields [:name, :module, :function, :input_schema]

  # --- Public API (reads bypass GenServer via ETS) ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register a tool spec. Upserts if the tool name already exists."
  def register_tool(name \\ __MODULE__, tool_spec) do
    GenServer.call(name, {:register, tool_spec})
  end

  @doc "Remove a tool by name."
  def unregister_tool(name \\ __MODULE__, tool_name) do
    GenServer.call(name, {:unregister, tool_name})
  end

  @doc "Clear all registered tools."
  def clear(name \\ __MODULE__) do
    GenServer.call(name, :clear)
  end

  @doc "Look up a tool by name. Reads directly from ETS."
  def get_tool(name \\ __MODULE__, tool_name) do
    table = table_name(name)

    case :ets.lookup(table, tool_name) do
      [{^tool_name, spec}] -> {:ok, spec}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all registered tools. Reads directly from ETS."
  def list_tools(name \\ __MODULE__) do
    table = table_name(name)

    :ets.tab2list(table)
    |> Enum.map(fn {_name, spec} -> spec end)
  end

  @doc "Return tool definitions in Anthropic API format."
  def tool_definitions(name \\ __MODULE__) do
    list_tools(name)
    |> Enum.map(fn spec ->
      %{
        "name" => spec.name,
        "description" => spec.description,
        "input_schema" => spec.input_schema
      }
    end)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = table_name(name)
    :ets.new(table, [:set, :public, :named_table])

    if Keyword.get(opts, :register_builtins, false) do
      # Insert directly into ETS to avoid GenServer.call deadlock during init
      for spec <- Kerf.Tools.Registrations.builtins() do
        :ets.insert(table, {spec.name, spec})
      end
    end

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, spec}, _from, state) do
    case validate_spec(spec) do
      :ok ->
        :ets.insert(state.table, {spec.name, spec})
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:unregister, tool_name}, _from, state) do
    case :ets.lookup(state.table, tool_name) do
      [{^tool_name, _}] ->
        :ets.delete(state.table, tool_name)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  # --- Private ---

  defp table_name(name) do
    :"#{name}_table"
  end

  defp validate_spec(spec) when is_map(spec) do
    missing =
      @required_fields
      |> Enum.reject(fn field -> Map.has_key?(spec, field) end)

    case missing do
      [] -> :ok
      fields -> {:error, "missing required fields: #{Enum.join(fields, ", ")}"}
    end
  end

  defp validate_spec(_), do: {:error, "spec must be a map"}
end
