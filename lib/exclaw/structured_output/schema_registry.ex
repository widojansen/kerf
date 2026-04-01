defmodule ExClaw.StructuredOutput.SchemaRegistry do
  @moduledoc """
  GenServer + ETS registry for named JSON schemas.

  Writes go through the GenServer (serialized). Reads bypass it via
  the public ETS table for concurrent access.
  """

  use GenServer

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec register(GenServer.server(), atom(), map()) :: :ok | {:error, String.t()}
  def register(registry, schema_name, schema_def) do
    GenServer.call(registry, {:register, schema_name, schema_def})
  end

  @spec get(GenServer.server(), atom()) :: {:ok, map()} | {:error, :not_found}
  def get(registry, schema_name) do
    table = table_name(registry)

    case :ets.lookup(table, schema_name) do
      [{^schema_name, schema_def}] -> {:ok, schema_def}
      [] -> {:error, :not_found}
    end
  end

  @spec list(GenServer.server()) :: [{atom(), map()}]
  def list(registry) do
    table = table_name(registry)
    :ets.tab2list(table)
  end

  @spec deregister(GenServer.server(), atom()) :: :ok
  def deregister(registry, schema_name) do
    GenServer.call(registry, {:deregister, schema_name})
  end

  @spec register_all(GenServer.server(), [{atom(), map()}]) :: :ok
  def register_all(registry, schemas) do
    GenServer.call(registry, {:register_all, schemas})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = :"#{name}_table"
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])

    if Keyword.get(opts, :register_builtins, false) do
      Enum.each(ExClaw.StructuredOutput.Builtins.schemas(), fn {schema_name, schema_def} ->
        :ets.insert(table, {schema_name, schema_def})
      end)
    end

    {:ok, %{table: table, name: name}}
  end

  @impl true
  def handle_call({:register, schema_name, schema_def}, _from, state) do
    case validate_schema_def(schema_def) do
      :ok ->
        :ets.insert(state.table, {schema_name, schema_def})
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:deregister, schema_name}, _from, state) do
    :ets.delete(state.table, schema_name)
    {:reply, :ok, state}
  end

  def handle_call({:register_all, schemas}, _from, state) do
    Enum.each(schemas, fn {name, schema_def} ->
      :ets.insert(state.table, {name, schema_def})
    end)

    {:reply, :ok, state}
  end

  # --- Internals ---

  defp table_name(registry) when is_atom(registry), do: :"#{registry}_table"
  defp table_name(registry), do: :"#{inspect(registry)}_table"

  defp validate_schema_def(%{json_schema: _}), do: :ok
  defp validate_schema_def(_), do: {:error, "schema definition must contain :json_schema key"}
end
