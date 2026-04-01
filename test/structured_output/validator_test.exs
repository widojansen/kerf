defmodule ExClaw.StructuredOutput.ValidatorTest do
  use ExUnit.Case, async: true

  alias ExClaw.StructuredOutput.Validator

  # -- Helpers --

  defp email_schema do
    %{
      "type" => "object",
      "properties" => %{
        "category" => %{
          "type" => "string",
          "enum" => ["business", "personal", "spam"]
        },
        "priority" => %{"type" => "integer", "minimum" => 1, "maximum" => 5},
        "summary" => %{"type" => "string", "maxLength" => 100},
        "confidence" => %{"type" => "number", "minimum" => 0.0, "maximum" => 1.0}
      },
      "required" => ["category", "priority", "summary", "confidence"],
      "additionalProperties" => false
    }
  end

  # -- validate/2 --

  describe "validate/2 — required fields" do
    test "valid data passes" do
      data = %{
        "category" => "business",
        "priority" => 3,
        "summary" => "Invoice",
        "confidence" => 0.9
      }

      assert :ok = Validator.validate(data, email_schema())
    end

    test "missing required field returns error with path" do
      data = %{"category" => "business", "priority" => 3, "summary" => "x"}

      assert {:error, errors} = Validator.validate(data, email_schema())
      assert Enum.any?(errors, &(&1.path == "confidence"))
    end

    test "multiple missing required fields" do
      assert {:error, errors} = Validator.validate(%{}, email_schema())
      paths = Enum.map(errors, & &1.path)
      assert "category" in paths
      assert "priority" in paths
    end
  end

  describe "validate/2 — type checking" do
    test "string type" do
      schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
      assert :ok = Validator.validate(%{"name" => "Alice"}, schema)
      assert {:error, _} = Validator.validate(%{"name" => 42}, schema)
    end

    test "integer type" do
      schema = %{"type" => "object", "properties" => %{"count" => %{"type" => "integer"}}}
      assert :ok = Validator.validate(%{"count" => 5}, schema)
      assert {:error, _} = Validator.validate(%{"count" => 5.5}, schema)
      assert {:error, _} = Validator.validate(%{"count" => "five"}, schema)
    end

    test "number type accepts integers and floats" do
      schema = %{"type" => "object", "properties" => %{"val" => %{"type" => "number"}}}
      assert :ok = Validator.validate(%{"val" => 3}, schema)
      assert :ok = Validator.validate(%{"val" => 3.14}, schema)
      assert {:error, _} = Validator.validate(%{"val" => "three"}, schema)
    end

    test "boolean type" do
      schema = %{"type" => "object", "properties" => %{"flag" => %{"type" => "boolean"}}}
      assert :ok = Validator.validate(%{"flag" => true}, schema)
      assert :ok = Validator.validate(%{"flag" => false}, schema)
      assert {:error, _} = Validator.validate(%{"flag" => "true"}, schema)
    end

    test "array type" do
      schema = %{"type" => "object", "properties" => %{"tags" => %{"type" => "array"}}}
      assert :ok = Validator.validate(%{"tags" => [1, 2]}, schema)
      assert {:error, _} = Validator.validate(%{"tags" => "not_array"}, schema)
    end

    test "object type" do
      schema = %{"type" => "object", "properties" => %{"meta" => %{"type" => "object"}}}
      assert :ok = Validator.validate(%{"meta" => %{"a" => 1}}, schema)
      assert {:error, _} = Validator.validate(%{"meta" => "not_object"}, schema)
    end
  end

  describe "validate/2 — enum constraints" do
    test "valid enum value passes" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "color" => %{"type" => "string", "enum" => ["red", "green", "blue"]}
        }
      }

      assert :ok = Validator.validate(%{"color" => "red"}, schema)
    end

    test "invalid enum value fails" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "color" => %{"type" => "string", "enum" => ["red", "green", "blue"]}
        }
      }

      assert {:error, errors} = Validator.validate(%{"color" => "yellow"}, schema)
      assert Enum.any?(errors, &String.contains?(&1.message, "enum"))
    end
  end

  describe "validate/2 — numeric constraints" do
    test "minimum violation" do
      schema = %{
        "type" => "object",
        "properties" => %{"score" => %{"type" => "integer", "minimum" => 1}}
      }

      assert {:error, errors} = Validator.validate(%{"score" => 0}, schema)
      assert Enum.any?(errors, &String.contains?(&1.message, "minimum"))
    end

    test "maximum violation" do
      schema = %{
        "type" => "object",
        "properties" => %{"score" => %{"type" => "integer", "maximum" => 10}}
      }

      assert {:error, errors} = Validator.validate(%{"score" => 11}, schema)
      assert Enum.any?(errors, &String.contains?(&1.message, "maximum"))
    end

    test "within range passes" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "score" => %{"type" => "integer", "minimum" => 1, "maximum" => 10}
        }
      }

      assert :ok = Validator.validate(%{"score" => 5}, schema)
    end
  end

  describe "validate/2 — string constraints" do
    test "minLength violation" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string", "minLength" => 3}}
      }

      assert {:error, _} = Validator.validate(%{"name" => "ab"}, schema)
    end

    test "maxLength violation" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string", "maxLength" => 5}}
      }

      assert {:error, _} = Validator.validate(%{"name" => "toolong"}, schema)
    end

    test "pattern match" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "email" => %{"type" => "string", "pattern" => "^[^@]+@[^@]+$"}
        }
      }

      assert :ok = Validator.validate(%{"email" => "a@b.com"}, schema)
      assert {:error, _} = Validator.validate(%{"email" => "no-at-sign"}, schema)
    end
  end

  describe "validate/2 — array constraints" do
    test "minItems violation" do
      schema = %{
        "type" => "object",
        "properties" => %{"tags" => %{"type" => "array", "minItems" => 2}}
      }

      assert {:error, _} = Validator.validate(%{"tags" => [1]}, schema)
    end

    test "maxItems violation" do
      schema = %{
        "type" => "object",
        "properties" => %{"tags" => %{"type" => "array", "maxItems" => 2}}
      }

      assert {:error, _} = Validator.validate(%{"tags" => [1, 2, 3]}, schema)
    end

    test "array items validation" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "scores" => %{
            "type" => "array",
            "items" => %{"type" => "integer"}
          }
        }
      }

      assert :ok = Validator.validate(%{"scores" => [1, 2, 3]}, schema)
      assert {:error, _} = Validator.validate(%{"scores" => [1, "two", 3]}, schema)
    end
  end

  describe "validate/2 — nested objects" do
    test "validates nested object properties" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "address" => %{
            "type" => "object",
            "properties" => %{
              "city" => %{"type" => "string"},
              "zip" => %{"type" => "string"}
            },
            "required" => ["city"]
          }
        }
      }

      assert :ok = Validator.validate(%{"address" => %{"city" => "Amsterdam"}}, schema)
      assert {:error, errors} = Validator.validate(%{"address" => %{"zip" => "1234"}}, schema)
      assert Enum.any?(errors, &(&1.path == "address.city"))
    end
  end

  describe "validate/2 — additionalProperties" do
    test "rejects extra fields when false" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "additionalProperties" => false
      }

      assert {:error, errors} =
               Validator.validate(%{"name" => "Alice", "extra" => "bad"}, schema)

      assert Enum.any?(errors, &String.contains?(&1.message, "additional"))
    end

    test "allows extra fields when not set" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}}
      }

      assert :ok = Validator.validate(%{"name" => "Alice", "extra" => "ok"}, schema)
    end
  end

  describe "validate/2 — nested array of objects" do
    test "validates items inside array" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "entities" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string"},
                "type" => %{"type" => "string", "enum" => ["person", "org"]}
              },
              "required" => ["name", "type"]
            }
          }
        }
      }

      valid = %{"entities" => [%{"name" => "Alice", "type" => "person"}]}
      assert :ok = Validator.validate(valid, schema)

      invalid = %{"entities" => [%{"name" => "Alice", "type" => "unknown"}]}
      assert {:error, _} = Validator.validate(invalid, schema)
    end
  end

  # -- coerce/2 --

  describe "coerce/2" do
    test "coerces string to integer" do
      assert {:ok, %{"priority" => 3}} =
               Validator.coerce(%{"priority" => "3"}, priority: :integer)
    end

    test "coerces string to float" do
      assert {:ok, %{"score" => 0.95}} =
               Validator.coerce(%{"score" => "0.95"}, score: :float)
    end

    test "coerces string to boolean" do
      assert {:ok, %{"flag" => true}} = Validator.coerce(%{"flag" => "true"}, flag: :boolean)
      assert {:ok, %{"flag" => false}} = Validator.coerce(%{"flag" => "false"}, flag: :boolean)
    end

    test "coerces ISO date string to Date" do
      assert {:ok, %{"date" => ~D[2026-03-31]}} =
               Validator.coerce(%{"date" => "2026-03-31"}, date: :date)
    end

    test "coerces ISO datetime string to DateTime" do
      assert {:ok, %{"ts" => %DateTime{year: 2026}}} =
               Validator.coerce(%{"ts" => "2026-03-31T12:00:00Z"}, ts: :datetime)
    end

    test "coerces string to atom via {:enum, atoms}" do
      assert {:ok, %{"action" => :archive}} =
               Validator.coerce(%{"action" => "archive"}, action: {:enum, [:archive, :flag]})
    end

    test "leaves already-correct types untouched" do
      assert {:ok, %{"priority" => 3}} =
               Validator.coerce(%{"priority" => 3}, priority: :integer)
    end

    test "leaves unmentioned fields untouched" do
      assert {:ok, %{"name" => "Alice", "age" => "30"}} =
               Validator.coerce(%{"name" => "Alice", "age" => "30"}, [])
    end

    test "returns error on failed coercion" do
      assert {:error, errors} = Validator.coerce(%{"priority" => "abc"}, priority: :integer)
      assert length(errors) > 0
    end

    test "returns error for invalid enum atom" do
      assert {:error, _} =
               Validator.coerce(%{"action" => "invalid"}, action: {:enum, [:archive, :flag]})
    end
  end

  # -- validate_and_coerce/3 --

  describe "validate_and_coerce/3" do
    test "validates then coerces in one call" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "priority" => %{"type" => "integer", "minimum" => 1, "maximum" => 5},
          "category" => %{"type" => "string"}
        },
        "required" => ["priority", "category"]
      }

      data = %{"priority" => 3, "category" => "business"}
      coercions = [priority: :integer]

      assert {:ok, %{"priority" => 3, "category" => "business"}} =
               Validator.validate_and_coerce(data, schema, coercions)
    end

    test "returns validation errors before coercion" do
      schema = %{
        "type" => "object",
        "properties" => %{"priority" => %{"type" => "integer"}},
        "required" => ["priority"]
      }

      assert {:error, errors} =
               Validator.validate_and_coerce(%{}, schema, priority: :integer)

      assert Enum.any?(errors, &(&1.path == "priority"))
    end
  end
end
