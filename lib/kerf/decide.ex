defmodule Kerf.Decide do
  @moduledoc """
  SPEC_H F01 — ask typed questions of a state; get probabilities back.

  `ask(state, questions, opts)` validates the request in Elixir, then
  dispatches to `opts[:adapter]` or `Application.get_env(:kerf,
  Kerf.Decide)[:adapter]`, passing the remaining opts through unchanged.
  Returns `{:ok, %{name => Kerf.Decide.Result.t()}}` or `{:error, reason}`:
  `{:invalid_request, {name, reason}}`, `{:invalid_request, atom}` for
  state-level defects, `{:schema_violation, detail}` when the adapter's
  answers do not fit the request, or the adapter's own error.

  Results are re-derived here, never trusted from the adapter: Choice probs
  are reordered to the OptionSet's order and confidence is recomputed as
  `(p_max − 1/K)/(1 − 1/K)` (F01.3, F01.4). Each result's provenance copies
  the state's taint and sources with origin `:derived` (F01.6, A1.10).

  Telemetry (A1.5): `[:kerf, :decide, :answer]` per question without
  `branch:`; branch questions are emitted only by `commit_branch/2` (or by
  Kerf.Decide.Server when handle_answer commits a branch).
  """

  alias Kerf.Decide.{OptionSet, State}
  alias Kerf.Decide.Question.{Choice, Noul, Score}

  @max_options 255
  @min_levels 2
  @max_levels 10

  @type results :: %{atom() => Kerf.Decide.Result.t()}

  @spec ask(State.t(), [Kerf.Decide.Question.t()], keyword()) ::
          {:ok, results()} | {:error, term()}
  def ask(state, questions, opts \\ []) do
    with :ok <- reject_opts_provenance(opts),
         :ok <- validate(state, questions),
         {:ok, adapter} <- adapter(opts) do
      run(adapter, state, questions, Keyword.delete(opts, :adapter))
    end
  end

  @doc """
  Pure request validation (F01.2). Question-level defects name the question:
  `{:invalid_request, {name, reason}}`; state-level defects are a bare atom.
  Provenance is checked for presence and shape only (A1.10).
  """
  @spec validate(term(), term()) :: :ok | {:error, {:invalid_request, term()}}
  def validate(state, questions) do
    with :ok <- validate_state(state),
         :ok <- validate_questions(questions) do
      :ok
    end
  end

  @doc """
  Emits `[:kerf, :decide, :answer]` for the questions marked `branch: branch_id`,
  for a caller that asked a speculative request directly and has chosen a branch.
  Answers of every other branch are discarded unlogged (F02.4).
  """
  @spec commit_branch({State.t(), [Kerf.Decide.Question.t()], results()}, atom()) :: :ok
  def commit_branch({%State{} = state, questions, results}, branch_id) do
    questions
    |> Enum.filter(&(&1.branch == branch_id and not is_nil(branch_id)))
    |> emit_answers(results, state_hash(state))
  end

  # ---------- validation ----------

  defp reject_opts_provenance(opts) do
    if Keyword.has_key?(opts, :provenance),
      do: invalid(:provenance_not_accepted),
      else: :ok
  end

  defp validate_state(%State{content: content, provenance: provenance}) do
    cond do
      not valid_provenance?(provenance) -> invalid(:missing_provenance)
      not (is_binary(content) or is_map(content)) -> invalid(:invalid_state)
      true -> :ok
    end
  end

  defp validate_state(_state), do: invalid(:invalid_state)

  defp valid_provenance?(%{taint: taint, sources: sources})
       when taint in [:clean, :tainted] and is_list(sources),
       do: true

  defp valid_provenance?(_provenance), do: false

  defp validate_questions(questions) when is_list(questions) do
    questions
    |> Enum.reduce_while(MapSet.new(), fn question, seen ->
      case validate_question(question, seen) do
        :ok -> {:cont, MapSet.put(seen, question.name)}
        error -> {:halt, error}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp validate_questions(_questions), do: invalid(:invalid_questions)

  defp validate_question(%type{name: name} = question, seen)
       when type in [Noul, Choice, Score] and is_atom(name) do
    cond do
      MapSet.member?(seen, name) -> invalid({name, :duplicate_name})
      blank?(question.instructions) -> invalid({name, :empty_instructions})
      true -> validate_shape(question)
    end
  end

  defp validate_question(_question, _seen), do: invalid(:invalid_question)

  defp validate_shape(%Noul{}), do: :ok

  defp validate_shape(%Choice{name: name, options: %OptionSet{labels: labels}})
       when is_list(labels) do
    k = length(labels)

    cond do
      k < 2 -> invalid({name, :too_few_options})
      k > @max_options -> invalid({name, :too_many_options})
      not distinct_binaries?(labels) -> invalid({name, :invalid_options})
      true -> :ok
    end
  end

  defp validate_shape(%Choice{name: name}), do: invalid({name, :invalid_options})

  defp validate_shape(%Score{name: name, levels: levels}) do
    n = length(levels)

    cond do
      n < @min_levels -> invalid({name, :too_few_levels})
      n > @max_levels -> invalid({name, :too_many_levels})
      not distinct_binaries?(levels) -> invalid({name, :invalid_levels})
      true -> :ok
    end
  end

  defp blank?(instructions) when is_binary(instructions), do: String.trim(instructions) == ""
  defp blank?(instructions) when is_map(instructions), do: map_size(instructions) == 0
  defp blank?(_instructions), do: true

  defp distinct_binaries?(list),
    do: Enum.all?(list, &is_binary/1) and length(Enum.uniq(list)) == length(list)

  defp invalid(detail), do: {:error, {:invalid_request, detail}}

  defp adapter(opts) do
    case opts[:adapter] || Application.get_env(:kerf, __MODULE__, [])[:adapter] do
      nil -> invalid(:no_adapter)
      adapter -> {:ok, adapter}
    end
  end

  # ---------- dispatch and result derivation ----------

  defp run(adapter, state, questions, opts) do
    started = System.monotonic_time()
    response = adapter.ask(state, questions, opts)

    latency_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    with {:ok, answers} <- adapter_answers(response),
         {:ok, results} <- build_results(questions, answers, adapter, latency_ms, state) do
      questions
      |> Enum.filter(&is_nil(&1.branch))
      |> emit_answers(results, state_hash(state))

      {:ok, results}
    end
  end

  defp adapter_answers({:ok, answers}) when is_map(answers), do: {:ok, answers}
  defp adapter_answers({:error, _reason} = error), do: error
  defp adapter_answers(_other), do: {:error, {:schema_violation, :invalid_adapter_response}}

  defp build_results(questions, answers, adapter, latency_ms, state) do
    asked = MapSet.new(questions, & &1.name)
    unexpected = answers |> Map.keys() |> Enum.reject(&MapSet.member?(asked, &1))

    common = %{backend: adapter, latency_ms: latency_ms, provenance: derive(state.provenance)}

    if unexpected == [] do
      Enum.reduce_while(questions, {:ok, %{}}, fn question, {:ok, acc} ->
        case result(question, Map.fetch(answers, question.name)) do
          {:ok, result} -> {:cont, {:ok, Map.put(acc, question.name, Map.merge(result, common))}}
          {:error, reason} -> {:halt, {:error, {:schema_violation, {question.name, reason}}}}
        end
      end)
    else
      {:error, {:schema_violation, {:unexpected_answers, unexpected}}}
    end
  end

  defp result(_question, :error), do: {:error, :missing_answer}

  defp result(%Noul{}, {:ok, %{p_yes: p}}) when is_number(p) and p >= 0 and p <= 1,
    do: {:ok, %{p_yes: p}}

  defp result(%Choice{options: %OptionSet{labels: labels}}, {:ok, %{probs: probs}}) do
    with {:ok, ordered} <- reorder(probs, labels) do
      {label, p_max} = Enum.max_by(ordered, &elem(&1, 1))
      k = length(labels)
      {:ok, %{label: label, probs: ordered, confidence: (p_max - 1 / k) / (1 - 1 / k)}}
    end
  end

  defp result(%Score{levels: levels}, {:ok, %{expected: expected, probs: probs, confidence: c}})
       when is_number(expected) and is_number(c) do
    with {:ok, ordered} <- reorder(probs, levels) do
      {:ok, %{expected: expected, probs: ordered, confidence: c}}
    end
  end

  defp result(_question, {:ok, _answer}), do: {:error, :invalid_answer}

  # The adapter's order is never visible: probs come back in the caller's
  # label order, and exactly the caller's labels — none missing, none added.
  defp reorder(probs, labels) when is_list(probs) do
    keys = Enum.map(probs, &prob_key/1)

    cond do
      not Enum.all?(probs, &valid_prob?/1) -> {:error, :invalid_probs}
      length(Enum.uniq(keys)) != length(keys) -> {:error, :duplicate_label}
      MapSet.new(keys) != MapSet.new(labels) -> {:error, {:labels_mismatch, keys -- labels}}
      true -> {:ok, Enum.map(labels, &{&1, :proplists.get_value(&1, probs)})}
    end
  end

  defp reorder(_probs, _labels), do: {:error, :invalid_probs}

  defp prob_key({key, _p}), do: key
  defp prob_key(_other), do: nil

  defp valid_prob?({key, p}) when is_binary(key) and is_number(p), do: p >= 0 and p <= 1
  defp valid_prob?(_other), do: false

  defp derive(provenance),
    do: %{taint: provenance.taint, origin: :derived, sources: provenance.sources}

  # ---------- telemetry ----------

  defp emit_answers(questions, results, state_hash) do
    Enum.each(questions, fn question ->
      case Map.fetch(results, question.name) do
        {:ok, result} -> emit_answer(question, result, state_hash)
        :error -> :ok
      end
    end)
  end

  # No state text and no option labels in the event (F07.1).
  defp emit_answer(question, result, state_hash) do
    :telemetry.execute(
      [:kerf, :decide, :answer],
      %{confidence: Map.get(result, :confidence), latency_ms: result.latency_ms},
      %{
        question_name: question.name,
        type: type(question),
        backend: result.backend,
        model_id: model_id(result.backend),
        state_hash: state_hash
      }
    )
  end

  defp type(%Noul{}), do: :noul
  defp type(%Choice{}), do: :choice
  defp type(%Score{}), do: :score

  defp model_id(backend) do
    if function_exported?(backend, :info, 0), do: backend.info()[:model_id]
  end

  defp state_hash(%State{content: content}),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(content)) |> Base.encode16(case: :lower)
end
