defmodule Kerf.StructuredOutput.SchemaRegistryTest do
  use ExUnit.Case, async: true

  alias Kerf.StructuredOutput.SchemaRegistry

  defp start_registry(_context \\ %{}) do
    name = :"schema_reg_#{System.unique_integer([:positive])}"
    {:ok, pid} = SchemaRegistry.start_link(name: name)
    %{registry: name, pid: pid}
  end

  defp valid_schema do
    %{
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "decision" => %{"type" => "string", "enum" => ["yes", "no"]},
          "reason" => %{"type" => "string"}
        },
        "required" => ["decision", "reason"]
      },
      coercions: [],
      description: "A yes/no decision with reasoning",
      max_tokens: 256
    }
  end

  describe "register/3 and get/2" do
    test "registers a schema and retrieves it" do
      %{registry: reg} = start_registry()
      assert :ok = SchemaRegistry.register(reg, :yes_no, valid_schema())
      assert {:ok, schema} = SchemaRegistry.get(reg, :yes_no)
      assert schema.description == "A yes/no decision with reasoning"
      assert schema.json_schema["type"] == "object"
    end

    test "get/2 returns {:error, :not_found} for non-existent" do
      %{registry: reg} = start_registry()
      assert {:error, :not_found} = SchemaRegistry.get(reg, :nonexistent)
    end

    test "duplicate registration overwrites (upsert)" do
      %{registry: reg} = start_registry()
      :ok = SchemaRegistry.register(reg, :test, valid_schema())

      updated = %{valid_schema() | description: "Updated description"}
      :ok = SchemaRegistry.register(reg, :test, updated)

      {:ok, schema} = SchemaRegistry.get(reg, :test)
      assert schema.description == "Updated description"
    end

    test "rejects schema missing json_schema key" do
      %{registry: reg} = start_registry()
      bad_schema = Map.delete(valid_schema(), :json_schema)
      assert {:error, reason} = SchemaRegistry.register(reg, :bad, bad_schema)
      assert reason =~ "json_schema"
    end
  end

  describe "list/1" do
    test "returns all registered schemas" do
      %{registry: reg} = start_registry()
      :ok = SchemaRegistry.register(reg, :schema_a, valid_schema())

      :ok =
        SchemaRegistry.register(reg, :schema_b, %{
          valid_schema()
          | description: "Schema B"
        })

      schemas = SchemaRegistry.list(reg)
      assert length(schemas) == 2
      names = Enum.map(schemas, fn {name, _} -> name end)
      assert :schema_a in names
      assert :schema_b in names
    end

    test "returns empty list when no schemas registered" do
      %{registry: reg} = start_registry()
      assert SchemaRegistry.list(reg) == []
    end
  end

  describe "deregister/2" do
    test "removes a registered schema" do
      %{registry: reg} = start_registry()
      :ok = SchemaRegistry.register(reg, :temp, valid_schema())
      :ok = SchemaRegistry.deregister(reg, :temp)
      assert {:error, :not_found} = SchemaRegistry.get(reg, :temp)
    end

    test "deregistering non-existent is silent" do
      %{registry: reg} = start_registry()
      assert :ok = SchemaRegistry.deregister(reg, :nonexistent)
    end
  end

  describe "register_all/2" do
    test "registers multiple schemas at once" do
      %{registry: reg} = start_registry()

      schemas = [
        {:schema_x, valid_schema()},
        {:schema_y, %{valid_schema() | description: "Y"}}
      ]

      assert :ok = SchemaRegistry.register_all(reg, schemas)
      assert {:ok, _} = SchemaRegistry.get(reg, :schema_x)
      assert {:ok, _} = SchemaRegistry.get(reg, :schema_y)
    end
  end

  describe "concurrent reads" do
    test "multiple processes can read simultaneously" do
      %{registry: reg} = start_registry()
      :ok = SchemaRegistry.register(reg, :concurrent, valid_schema())

      tasks =
        for _ <- 1..10 do
          Task.async(fn -> SchemaRegistry.get(reg, :concurrent) end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end
  end
end
