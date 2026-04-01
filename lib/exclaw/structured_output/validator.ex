defmodule ExClaw.StructuredOutput.Validator do
  @moduledoc """
  Validates parsed data against JSON Schema definitions and applies
  Elixir-side type coercions.
  """

  @type validation_error :: %{path: String.t(), message: String.t(), value: term()}

  # --- Public API ---

  @spec validate(map(), map()) :: :ok | {:error, [validation_error()]}
  def validate(data, schema) do
    errors = validate_value(data, schema, "")

    case errors do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  @spec coerce(map(), keyword()) :: {:ok, map()} | {:error, [validation_error()]}
  def coerce(data, []), do: {:ok, data}

  def coerce(data, coercions) when is_map(data) do
    {result, errors} =
      Enum.reduce(coercions, {data, []}, fn {field, type}, {acc, errs} ->
        key = Atom.to_string(field)

        case Map.fetch(acc, key) do
          {:ok, value} ->
            case coerce_value(value, type) do
              {:ok, coerced} -> {Map.put(acc, key, coerced), errs}
              {:error, msg} -> {acc, [%{path: key, message: msg, value: value} | errs]}
            end

          :error ->
            {acc, errs}
        end
      end)

    case errors do
      [] -> {:ok, result}
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  @spec validate_and_coerce(map(), map(), keyword()) ::
          {:ok, map()} | {:error, [validation_error()]}
  def validate_and_coerce(data, schema, coercions) do
    with :ok <- validate(data, schema) do
      coerce(data, coercions)
    end
  end

  # --- Validation internals ---

  defp validate_value(data, %{"type" => "object"} = schema, path) do
    type_errors = check_type(data, "object", path)

    if type_errors != [] do
      type_errors
    else
      props = Map.get(schema, "properties", %{})
      required = Map.get(schema, "required", [])
      additional = Map.get(schema, "additionalProperties", true)

      required_errors =
        Enum.flat_map(required, fn field ->
          if Map.has_key?(data, field) do
            []
          else
            field_path = join_path(path, field)
            [%{path: field_path, message: "required field missing", value: nil}]
          end
        end)

      property_errors =
        Enum.flat_map(props, fn {field, field_schema} ->
          case Map.fetch(data, field) do
            {:ok, value} ->
              validate_value(value, field_schema, join_path(path, field))

            :error ->
              []
          end
        end)

      additional_errors =
        if additional == false do
          allowed = Map.keys(props)

          data
          |> Map.keys()
          |> Enum.reject(&(&1 in allowed))
          |> Enum.map(fn key ->
            %{
              path: join_path(path, key),
              message: "additional property not allowed: #{key}",
              value: Map.get(data, key)
            }
          end)
        else
          []
        end

      required_errors ++ property_errors ++ additional_errors
    end
  end

  defp validate_value(data, %{"type" => "array"} = schema, path) do
    type_errors = check_type(data, "array", path)

    if type_errors != [] do
      type_errors
    else
      min_errors = check_min_items(data, schema, path)
      max_errors = check_max_items(data, schema, path)
      item_errors = validate_array_items(data, schema, path)

      min_errors ++ max_errors ++ item_errors
    end
  end

  defp validate_value(data, schema, path) when is_map(schema) do
    type = Map.get(schema, "type")
    errors = if type, do: check_type(data, type, path), else: []

    if errors != [] do
      errors
    else
      errors
      |> then(&(&1 ++ check_enum(data, schema, path)))
      |> then(&(&1 ++ check_minimum(data, schema, path)))
      |> then(&(&1 ++ check_maximum(data, schema, path)))
      |> then(&(&1 ++ check_min_length(data, schema, path)))
      |> then(&(&1 ++ check_max_length(data, schema, path)))
      |> then(&(&1 ++ check_pattern(data, schema, path)))
    end
  end

  # --- Type checks ---

  defp check_type(value, "string", path) when not is_binary(value),
    do: [%{path: path, message: "expected type string", value: value}]

  defp check_type(value, "integer", path) when not is_integer(value),
    do: [%{path: path, message: "expected type integer", value: value}]

  defp check_type(value, "number", path) when not is_number(value),
    do: [%{path: path, message: "expected type number", value: value}]

  defp check_type(value, "boolean", path) when not is_boolean(value),
    do: [%{path: path, message: "expected type boolean", value: value}]

  defp check_type(value, "array", path) when not is_list(value),
    do: [%{path: path, message: "expected type array", value: value}]

  defp check_type(value, "object", path) when not is_map(value),
    do: [%{path: path, message: "expected type object", value: value}]

  defp check_type(_value, _type, _path), do: []

  # --- Constraint checks ---

  defp check_enum(value, %{"enum" => allowed}, path) do
    if value in allowed,
      do: [],
      else: [%{path: path, message: "value not in enum: #{inspect(allowed)}", value: value}]
  end

  defp check_enum(_value, _schema, _path), do: []

  defp check_minimum(value, %{"minimum" => min}, path) when is_number(value) do
    if value >= min,
      do: [],
      else: [%{path: path, message: "value #{value} is below minimum #{min}", value: value}]
  end

  defp check_minimum(_value, _schema, _path), do: []

  defp check_maximum(value, %{"maximum" => max}, path) when is_number(value) do
    if value <= max,
      do: [],
      else: [%{path: path, message: "value #{value} exceeds maximum #{max}", value: value}]
  end

  defp check_maximum(_value, _schema, _path), do: []

  defp check_min_length(value, %{"minLength" => min}, path) when is_binary(value) do
    if String.length(value) >= min,
      do: [],
      else: [%{path: path, message: "string length below minLength #{min}", value: value}]
  end

  defp check_min_length(_value, _schema, _path), do: []

  defp check_max_length(value, %{"maxLength" => max}, path) when is_binary(value) do
    if String.length(value) <= max,
      do: [],
      else: [%{path: path, message: "string length exceeds maxLength #{max}", value: value}]
  end

  defp check_max_length(_value, _schema, _path), do: []

  defp check_pattern(value, %{"pattern" => pattern}, path) when is_binary(value) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        if Regex.match?(regex, value),
          do: [],
          else: [%{path: path, message: "string does not match pattern: #{pattern}", value: value}]

      _ ->
        []
    end
  end

  defp check_pattern(_value, _schema, _path), do: []

  # --- Array helpers ---

  defp check_min_items(data, %{"minItems" => min}, path) when is_list(data) do
    if length(data) >= min,
      do: [],
      else: [%{path: path, message: "array has fewer than minItems #{min}", value: data}]
  end

  defp check_min_items(_data, _schema, _path), do: []

  defp check_max_items(data, %{"maxItems" => max}, path) when is_list(data) do
    if length(data) <= max,
      do: [],
      else: [%{path: path, message: "array exceeds maxItems #{max}", value: data}]
  end

  defp check_max_items(_data, _schema, _path), do: []

  defp validate_array_items(data, %{"items" => item_schema}, path) when is_list(data) do
    data
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      validate_value(item, item_schema, "#{path}[#{idx}]")
    end)
  end

  defp validate_array_items(_data, _schema, _path), do: []

  # --- Path helpers ---

  defp join_path("", field), do: field
  defp join_path(path, field), do: "#{path}.#{field}"

  # --- Coercion ---

  defp coerce_value(value, :integer) when is_integer(value), do: {:ok, value}

  defp coerce_value(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "cannot coerce #{inspect(value)} to integer"}
    end
  end

  defp coerce_value(_, :integer), do: {:error, "cannot coerce to integer"}

  defp coerce_value(value, :float) when is_float(value), do: {:ok, value}
  defp coerce_value(value, :float) when is_integer(value), do: {:ok, value / 1}

  defp coerce_value(value, :float) when is_binary(value) do
    case Float.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "cannot coerce #{inspect(value)} to float"}
    end
  end

  defp coerce_value(_, :float), do: {:error, "cannot coerce to float"}

  defp coerce_value(true, :boolean), do: {:ok, true}
  defp coerce_value(false, :boolean), do: {:ok, false}
  defp coerce_value("true", :boolean), do: {:ok, true}
  defp coerce_value("false", :boolean), do: {:ok, false}
  defp coerce_value(v, :boolean), do: {:error, "cannot coerce #{inspect(v)} to boolean"}

  defp coerce_value(%Date{} = d, :date), do: {:ok, d}

  defp coerce_value(value, :date) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "cannot coerce #{inspect(value)} to Date"}
    end
  end

  defp coerce_value(_, :date), do: {:error, "cannot coerce to Date"}

  defp coerce_value(%DateTime{} = dt, :datetime), do: {:ok, dt}

  defp coerce_value(value, :datetime) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, "cannot coerce #{inspect(value)} to DateTime"}
    end
  end

  defp coerce_value(_, :datetime), do: {:error, "cannot coerce to DateTime"}

  defp coerce_value(value, {:enum, allowed}) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, "#{value} not in allowed enum"}
  end

  defp coerce_value(value, {:enum, allowed}) when is_binary(value) do
    atom = String.to_atom(value)

    if atom in allowed,
      do: {:ok, atom},
      else: {:error, "#{inspect(value)} not in allowed enum #{inspect(allowed)}"}
  end

  defp coerce_value(v, {:enum, _}), do: {:error, "cannot coerce #{inspect(v)} to enum atom"}
end
