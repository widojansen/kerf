defmodule Kerf.Decide.Adapter.HTTP do
  @moduledoc """
  SPEC_H F03 — adapter for `POST /v1/systemone` (kev, Strands Decider
  server, laya-serve).

  Options: `base_url:` (or `config :kerf, Kerf.Decide.Adapter.HTTP,
  base_url:`), `allow_remote:` and `req_options:` (merged into the Req
  request). The host must be loopback or tailnet (100.64.0.0/10) unless
  `allow_remote: true` — the Strands server has no auth — and is checked
  before any request is made.

  The request body is exactly `{state, questions: {name: {type,
  instructions, criteria}}}` in caller order (addendum A1.8). Responses are
  decoded preserving key order so a duplicated answer is a schema violation,
  not a silent last-wins overwrite. Usage and cost are ignored (F02.5).
  Transport errors are `{:http_status, n}`, `:timeout`, `:econnrefused`, or
  `{:transport, reason}`, each emitting `[:kerf, :decide, :error]`.
  """

  @behaviour Kerf.Decide.Adapter

  alias Jason.OrderedObject
  alias Kerf.Decide.{OptionSet, State}
  alias Kerf.Decide.Question.{Choice, Noul, Score}

  @path "/v1/systemone"
  @default_receive_timeout 2_000

  @impl true
  def ask(%State{content: content}, questions, opts) do
    with {:ok, base_url} <- base_url(opts),
         :ok <- check_host(base_url, Keyword.get(opts, :allow_remote, false)),
         {:ok, body} <- encode(content, questions),
         {:ok, raw} <- post(base_url, body, opts),
         {:ok, answers} <- decode(raw) do
      map_answers(questions, answers)
    end
  end

  @impl true
  def info do
    %{
      model_id: "http:" <> (config()[:base_url] || "unconfigured"),
      types: [:noul, :choice, :score],
      max_state_tokens: 8_192,
      languages: ~w(nl de en)
    }
  end

  # ---------- host policy ----------

  defp base_url(opts) do
    case opts[:base_url] || config()[:base_url] do
      url when is_binary(url) -> {:ok, url}
      _missing -> {:error, {:invalid_request, :no_base_url}}
    end
  end

  defp config, do: Application.get_env(:kerf, __MODULE__, [])

  defp check_host(_base_url, true), do: :ok

  defp check_host(base_url, _allow_remote) do
    host = URI.parse(base_url).host

    if local_host?(host), do: :ok, else: {:error, {:remote_refused, host}}
  end

  defp local_host?("localhost"), do: true

  defp local_host?(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {100, b, _, _}} when b in 64..127 -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> false
    end
  end

  defp local_host?(_host), do: false

  # ---------- request ----------

  defp encode(content, questions) do
    body =
      OrderedObject.new([
        {"state", content},
        {"questions",
         OrderedObject.new(Enum.map(questions, &{Atom.to_string(&1.name), wire(&1)}))}
      ])

    case Jason.encode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, {:invalid_request, :state_not_json}}
    end
  end

  defp wire(question) do
    OrderedObject.new([
      {"type", type(question)},
      {"instructions", question.instructions},
      {"criteria", criteria(question)}
    ])
  end

  defp type(%Noul{}), do: "noul"
  defp type(%Choice{}), do: "choice"
  defp type(%Score{}), do: "score"

  # The Choice criteria object carries the option order, so it is never
  # omitted: a label without a description describes itself.
  defp criteria(%Choice{options: options, criteria: descriptions}) do
    descriptions = descriptions || %{}

    options
    |> OptionSet.labels()
    |> Enum.map(&{&1, Map.get(descriptions, &1) || &1})
    |> OrderedObject.new()
  end

  defp criteria(%Score{levels: levels}), do: levels
  defp criteria(%Noul{criteria: criteria}), do: criteria

  defp post(base_url, body, opts) do
    request =
      Req.new(
        base_url: base_url,
        url: @path,
        method: :post,
        body: body,
        headers: [{"content-type", "application/json"}],
        decode_body: false,
        receive_timeout: Keyword.get(opts, :timeout, @default_receive_timeout)
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: raw}} when status in 200..299 -> {:ok, raw}
      {:ok, %Req.Response{status: status}} -> transport_error({:http_status, status})
      {:error, %Req.TransportError{reason: :timeout}} -> transport_error(:timeout)
      {:error, %Req.TransportError{reason: :econnrefused}} -> transport_error(:econnrefused)
      {:error, exception} -> transport_error({:transport, Exception.message(exception)})
    end
  end

  defp transport_error(reason) do
    :telemetry.execute([:kerf, :decide, :error], %{count: 1}, %{
      backend: __MODULE__,
      reason: reason
    })

    {:error, reason}
  end

  # ---------- response ----------

  defp decode(raw) do
    with {:ok, %OrderedObject{} = root} <- Jason.decode(raw, objects: :ordered_objects),
         %OrderedObject{} = answers <- root["answers"],
         :ok <- unique_keys(answers, :duplicate_answer) do
      {:ok, answers}
    else
      {:error, {:schema_violation, _detail}} = error -> error
      _malformed -> violation(:malformed_response)
    end
  end

  defp unique_keys(%OrderedObject{values: values}, kind) do
    keys = Enum.map(values, &elem(&1, 0))

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [duplicate | _] -> violation({kind, duplicate})
    end
  end

  defp map_answers(questions, answers) do
    asked = Enum.map(questions, &Atom.to_string(&1.name))

    case Enum.map(answers.values, &elem(&1, 0)) -- asked do
      [] -> collect(questions, answers)
      unexpected -> violation({:unexpected_answers, unexpected})
    end
  end

  defp collect(questions, answers) do
    Enum.reduce_while(questions, {:ok, %{}}, fn question, {:ok, acc} ->
      with {:ok, fields} <- fields(question, answers[Atom.to_string(question.name)]),
           {:ok, answer} <- answer(question, fields) do
        {:cont, {:ok, Map.put(acc, question.name, answer)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fields(%{name: name}, nil), do: violation({name, :missing_answer})

  defp fields(%{name: name}, %OrderedObject{values: values} = answer) do
    with :ok <- unique_keys(answer, {name, :duplicate_field}) do
      {:ok, Map.new(values)}
    end
  end

  defp fields(%{name: name}, _answer), do: violation({name, :invalid_answer})

  defp answer(%Noul{}, %{"noul" => p_yes}) when is_number(p_yes), do: {:ok, %{p_yes: p_yes}}

  defp answer(%Choice{name: name}, %{"probabilities" => probs}) do
    with {:ok, probs} <- probabilities(name, probs) do
      {:ok, %{probs: probs}}
    end
  end

  defp answer(
         %Score{name: name, levels: levels},
         %{"score" => expected, "confidence" => confidence, "probabilities" => probs}
       )
       when is_number(expected) and is_number(confidence) do
    with {:ok, by_index} <- probabilities(name, probs),
         {:ok, probs} <- level_probs(name, by_index, levels) do
      {:ok, %{expected: expected, probs: probs, confidence: confidence}}
    end
  end

  defp answer(%{name: name}, _fields), do: violation({name, :invalid_answer})

  defp probabilities(name, %OrderedObject{values: values} = probs) do
    with :ok <- unique_keys(probs, {name, :duplicate_label}) do
      {:ok, values}
    end
  end

  defp probabilities(name, _probs), do: violation({name, :missing_probabilities})

  # Score probabilities are keyed by level index ("0".."n-1") on the wire.
  defp level_probs(name, by_index, levels) do
    Enum.reduce_while(by_index, {:ok, []}, fn {index, p}, {:ok, acc} ->
      case Integer.parse(index) do
        {i, ""} when i >= 0 and i < length(levels) ->
          {:cont, {:ok, [{Enum.at(levels, i), p} | acc]}}

        _out_of_range ->
          {:halt, violation({name, {:unknown_level, index}})}
      end
    end)
    |> case do
      {:ok, probs} -> {:ok, Enum.reverse(probs)}
      error -> error
    end
  end

  defp violation(detail), do: {:error, {:schema_violation, detail}}
end
