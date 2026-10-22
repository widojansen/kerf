defmodule Kerf.Eval.Manifest do
  @moduledoc """
  SPEC_H F08 — the Decide labelled-set manifest: struct, loader, validator, freeze.

  Contract: plan §2.1 (docs/superpowers/plans/2026-10-20-decide-eval-step2-3.md)
  with addendum 03 (A3.5, A3.9) and the lead rulings S-16..S-21. Closes
  F08.1 (counts + language mix), F08.2 (label validation), F08.3 (pairs),
  F08.4 (`ready_for_run?/1`), F08.5 (held-out calibration split, training
  export refusal) and F08.7 (`label_sources`).

  Errors are `{:error, [violation]}` with
  `violation :: {code, item_id | nil, detail}`; nothing here raises.
  Question order lives only in `Kerf.Eval.Manifest.QuestionSet.order/0` (S-16).

  A real item has a non-nil `doc_id`; `counts.pairs` is the number of
  synthetic (`doc_id: nil`) items, so `counts.total − counts.pairs` is the
  number of real items (S-21). Once `frozen_at` is set, every mutating
  function refuses with `:frozen`.
  """

  alias Kerf.Eval.Manifest.{Item, QuestionSet}

  defstruct schema_version: 1,
            set_id: nil,
            created_at: nil,
            frozen_at: nil,
            export: nil,
            question_set: %{},
            counts: nil,
            items: []

  @type question_def :: %{String.t() => String.t() | [String.t()]}

  @type counts :: %{
          total: non_neg_integer(),
          labelled: non_neg_integer(),
          tiered: non_neg_integer(),
          held_out: non_neg_integer(),
          pairs: non_neg_integer(),
          by_language: %{String.t() => non_neg_integer()},
          by_tier: %{String.t() => non_neg_integer()}
        }

  @type export :: %{
          host: String.t(),
          exported_at: String.t(),
          query_sha256: String.t(),
          overrides_sha256: String.t() | nil,
          row_count: non_neg_integer(),
          mix_shortfall_acknowledged: boolean()
        }

  @type t :: %__MODULE__{
          schema_version: 1,
          set_id: String.t(),
          created_at: String.t(),
          frozen_at: String.t() | nil,
          export: export() | nil,
          question_set: %{String.t() => question_def()},
          counts: counts() | nil,
          items: [Item.t()]
        }

  @type violation :: {atom(), String.t() | nil, term()}

  @labelled_by "wido"
  @languages ["nl", "de", "en", "und"]
  @tiers ["easy", "standard", "hard"]
  @splits [nil, "eval", "calibration"]
  @label_sources ["adjudicated", "new"]

  @calibration_size 50
  @min_real_items 200
  @min_pairs 20
  @language_mix %{"nl" => 0.40, "de" => 0.25, "en" => 0.20}

  @counts_keys [:total, :labelled, :tiered, :held_out, :pairs, :by_language, :by_tier]
  @export_keys [
    :host,
    :exported_at,
    :query_sha256,
    :overrides_sha256,
    :row_count,
    :mix_shortfall_acknowledged
  ]
  @state_keys [:from, :from_name, :subject, :date, :body]
  @item_fields Item.__struct__() |> Map.from_struct() |> Map.keys()

  # -- load / save / sha256 ---------------------------------------------------

  @spec load(Path.t()) :: {:ok, t()} | {:error, [violation()]}
  def load(path) do
    with {:ok, json} <- read_file(path),
         {:ok, decoded} <- decode_json(json),
         {:ok, manifest} <- from_json(decoded),
         :ok <- validate(manifest) do
      {:ok, manifest}
    end
  end

  @spec save(t(), Path.t()) :: :ok | {:error, [violation()]}
  def save(%__MODULE__{} = manifest, path) do
    manifest = recount(manifest)

    with :ok <- validate(manifest),
         {:ok, json} <- encode_json(manifest) do
      write_atomically(path, json)
    end
  end

  @spec sha256(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def sha256(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, [{:file_unreadable, nil, {path, reason}}]}
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, [{:invalid_json, nil, Exception.message(error)}]}
    end
  end

  defp encode_json(manifest) do
    map =
      manifest
      |> Map.from_struct()
      |> Map.put(:items, Enum.map(manifest.items, &Map.from_struct/1))

    case Jason.encode(map, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, error} -> {:error, [{:encode_failed, nil, Exception.message(error)}]}
    end
  end

  # The tmp file sits next to the target so the rename stays on one
  # filesystem and is atomic; a reader never sees a half-written manifest.
  defp write_atomically(path, json) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with {:write, :ok} <- {:write, File.write(tmp, json)},
         {:rename, :ok} <- {:rename, File.rename(tmp, path)} do
      :ok
    else
      {step, {:error, reason}} ->
        _ = File.rm(tmp)
        {:error, [{:write_failed, nil, {step, path, reason}}]}
    end
  end

  # -- JSON → struct ----------------------------------------------------------

  defp from_json(%{"schema_version" => 1, "items" => items} = decoded) when is_list(items) do
    with {:ok, items} <- items_from_json(items) do
      {:ok,
       %__MODULE__{
         schema_version: 1,
         set_id: decoded["set_id"],
         created_at: decoded["created_at"],
         frozen_at: decoded["frozen_at"],
         export: atom_keyed(decoded["export"], @export_keys),
         question_set: Map.get(decoded, "question_set", %{}),
         counts: atom_keyed(decoded["counts"], @counts_keys),
         items: items
       }}
    end
  end

  defp from_json(%{"schema_version" => version}) when version != 1,
    do: {:error, [{:schema_version, nil, version}]}

  defp from_json(_decoded), do: {:error, [{:schema_invalid, nil, :not_a_manifest_object}]}

  defp items_from_json(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{"id" => id} = item, _index}, {:ok, acc} when is_binary(id) ->
        {:cont, {:ok, [item_from_json(item) | acc]}}

      {_item, index}, _acc ->
        {:halt, {:error, [{:schema_invalid, nil, {:item, index}}]}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp item_from_json(json) do
    fields =
      for field <- @item_fields, Map.has_key?(json, Atom.to_string(field)), into: %{} do
        {field, Map.fetch!(json, Atom.to_string(field))}
      end

    struct(Item, Map.update(fields, :state, nil, &atom_keyed(&1, @state_keys)))
  end

  # Only known keys become atoms; anything else in the file is dropped.
  defp atom_keyed(map, keys) when is_map(map) do
    for key <- keys, Map.has_key?(map, Atom.to_string(key)), into: %{} do
      {key, Map.fetch!(map, Atom.to_string(key))}
    end
  end

  defp atom_keyed(other, _keys), do: other

  # -- validate ---------------------------------------------------------------

  @spec validate(t()) :: :ok | {:error, [violation()]}
  def validate(%__MODULE__{} = manifest) do
    # A malformed question definition is reported once, up front (S-26); the
    # per-item label checks need well-formed definitions, so they are skipped.
    def_violations = question_def_violations(manifest.question_set)
    check_labels? = def_violations == []

    violations =
      def_violations ++
        question_set_violations(manifest) ++
        duplicate_violations(manifest.items) ++
        Enum.flat_map(manifest.items, &item_violations(&1, manifest, check_labels?)) ++
        pair_violations(manifest.items) ++
        counts_violations(manifest)

    if violations == [], do: :ok, else: {:error, violations}
  end

  def validate(other), do: {:error, [{:schema_invalid, nil, {:not_a_manifest, other}}]}

  # Shape of each question definition, checked once per manifest. JSON can
  # hand us a string where a list belongs; that must be a violation, not a raise.
  defp question_def_violations(qs) when is_map(qs) do
    for {key, qdef} <- Enum.sort(qs),
        reason = question_def_problem(qdef),
        reason != nil do
      {:question_def_invalid, nil, {key, reason}}
    end
  end

  defp question_def_violations(_qs), do: []

  defp question_def_problem(%{"type" => "choice", "options" => options}) when is_list(options),
    do: nil

  defp question_def_problem(%{"type" => "choice"}), do: :options_not_list
  defp question_def_problem(%{"type" => "noul"}), do: nil

  defp question_def_problem(%{"type" => "score", "levels" => levels}) when is_list(levels),
    do: nil

  defp question_def_problem(%{"type" => "score"}), do: :levels_not_list
  defp question_def_problem(%{"type" => _other}), do: :unknown_type
  defp question_def_problem(_qdef), do: :not_a_definition

  defp question_set_violations(%{question_set: qs}) when is_map(qs) do
    if MapSet.new(Map.keys(qs)) == MapSet.new(QuestionSet.order()),
      do: [],
      else: [{:question_set_keys, nil, %{expected: QuestionSet.order(), got: Map.keys(qs)}}]
  end

  defp question_set_violations(%{question_set: qs}),
    do: [{:question_set_keys, nil, %{expected: QuestionSet.order(), got: qs}}]

  defp duplicate_violations(items) do
    dup_ids = duplicates(Enum.map(items, & &1.id))
    dup_docs = items |> Enum.map(& &1.doc_id) |> Enum.reject(&is_nil/1) |> duplicates()

    Enum.map(dup_ids, &{:duplicate_item_id, &1, nil}) ++
      Enum.map(dup_docs, fn doc_id ->
        ids = for item <- items, item.doc_id == doc_id, do: item.id
        {:duplicate_doc_id, hd(ids), %{doc_id: doc_id, items: ids}}
      end)
  end

  defp duplicates(values) do
    values |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end) |> Enum.map(&elem(&1, 0))
  end

  defp item_violations(%Item{} = item, manifest, check_labels?) do
    id = item.id

    List.flatten([
      if(item.language in @languages, do: [], else: [{:language_invalid, id, item.language}]),
      body_violations(item),
      if(item.labels == nil or not check_labels?,
        do: [],
        else: label_violations(id, item.labels, manifest)
      ),
      label_source_violations(item),
      tier_violations(item),
      if(item.split in @splits, do: [], else: [{:split_invalid, id, item.split}]),
      if(manifest.frozen_at != nil and (item.labels == nil or item.tier == nil),
        do: [{:frozen_incomplete, id, %{labelled: item.labels != nil, tiered: item.tier != nil}}],
        else: []
      )
    ])
  end

  defp item_violations(other, _manifest, _check_labels?),
    do: [{:schema_invalid, nil, {:not_an_item, other}}]

  defp body_violations(%Item{id: id, state: state}) do
    case state do
      %{body: body} when is_binary(body) ->
        if String.trim(body) == "", do: [{:empty_body, id, nil}], else: []

      _ ->
        [{:empty_body, id, :no_state}]
    end
  end

  defp label_source_violations(%Item{id: id, label_sources: sources}) when is_map(sources) do
    for {key, value} <- sources, key != "category" or value not in @label_sources do
      {:unknown_label_source, id, {key, value}}
    end
  end

  defp label_source_violations(%Item{id: id, label_sources: sources}),
    do: [{:unknown_label_source, id, sources}]

  defp tier_violations(%Item{tier: nil}), do: []

  defp tier_violations(%Item{id: id, tier: tier, tier_reason: reason}) do
    if(tier in @tiers, do: [], else: [{:tier_invalid, id, tier}]) ++
      if blank?(reason), do: [{:empty_tier_reason, id, reason}], else: []
  end

  # Labels are checked against the manifest's own question_set; JSON
  # round-trip strings ("3", "true") are rejected, never coerced (F08.2).
  defp label_violations(id, labels, %{question_set: qs}) when is_map(labels) and is_map(qs) do
    case question_def_violations(qs) do
      [] -> label_violations_checked(id, labels, qs)
      def_violations -> def_violations
    end
  end

  defp label_violations(id, labels, _manifest), do: [{:label_wrong_type, id, {:labels, labels}}]

  defp label_violations_checked(id, labels, qs) do
    unknown =
      for key <- Map.keys(labels), not Map.has_key?(qs, key), do: {:unknown_question, id, key}

    per_question =
      for {question, qdef} <- qs do
        case Map.fetch(labels, question) do
          {:ok, value} -> check_label(id, question, qdef, value)
          :error -> [{:missing_question_label, id, question}]
        end
      end

    unknown ++ List.flatten(per_question)
  end

  defp check_label(id, question, %{"type" => "choice", "options" => options}, value)
       when is_list(options) do
    cond do
      not is_binary(value) -> [{:label_wrong_type, id, {question, value}}]
      value not in options -> [{:label_not_in_options, id, {question, value}}]
      true -> []
    end
  end

  defp check_label(id, question, %{"type" => "noul"}, value) do
    if is_boolean(value), do: [], else: [{:label_wrong_type, id, {question, value}}]
  end

  defp check_label(id, question, %{"type" => "score", "levels" => levels}, value)
       when is_list(levels) do
    cond do
      not is_integer(value) -> [{:label_wrong_type, id, {question, value}}]
      value < 1 or value > length(levels) -> [{:urgency_out_of_range, id, {question, value}}]
      true -> []
    end
  end

  defp check_label(id, question, qdef, _value),
    do: [{:unknown_question_type, id, {question, qdef}}]

  defp pair_violations(items) do
    items
    |> Enum.reject(&is_nil(&1.pair_id))
    |> Enum.group_by(& &1.pair_id)
    |> Enum.sort()
    |> Enum.flat_map(fn
      {_pair_id, [a, b]} ->
        flip =
          if a.labels != nil and b.labels != nil and a.labels == b.labels,
            do: [{:pair_no_flip, a.id, %{pair_id: a.pair_id, items: [a.id, b.id]}}],
            else: []

        fact =
          for item <- [a, b], blank?(item.pair_fact) do
            {:pair_fact_blank, item.id, %{pair_id: item.pair_id}}
          end

        flip ++ fact

      {pair_id, members} ->
        ids = Enum.map(members, & &1.id)
        [{:pair_incomplete, hd(ids), %{pair_id: pair_id, items: ids}}]
    end)
  end

  defp counts_violations(%{counts: counts} = manifest) do
    expected = compute_counts(manifest.items)
    real = Enum.count(manifest.items, &real?/1)

    cond do
      counts != expected ->
        [{:counts_mismatch, nil, %{expected: expected, got: counts}}]

      counts.total - counts.pairs != real ->
        [
          {:counts_mismatch, nil,
           %{real_items: real, total_minus_pairs: counts.total - counts.pairs}}
        ]

      true ->
        []
    end
  end

  # -- counts -----------------------------------------------------------------

  defp recount(%__MODULE__{} = manifest), do: %{manifest | counts: compute_counts(manifest.items)}

  defp compute_counts(items) do
    %{
      total: length(items),
      labelled: Enum.count(items, &(&1.labels != nil)),
      tiered: Enum.count(items, &(&1.tier != nil)),
      held_out: Enum.count(items, &(&1.split == "calibration")),
      pairs: Enum.count(items, &(not real?(&1))),
      by_language: Enum.frequencies_by(items, & &1.language),
      by_tier: items |> Enum.reject(&is_nil(&1.tier)) |> Enum.frequencies_by(& &1.tier)
    }
  end

  defp real?(%Item{doc_id: doc_id}), do: doc_id != nil

  # -- mutation (refused once frozen) ----------------------------------------

  @spec put_label(t(), String.t(), map(), String.t()) :: {:ok, t()} | {:error, [violation()]}
  def put_label(manifest, item_id, labels, now) do
    with :ok <- not_frozen(manifest, item_id),
         {:ok, item} <- fetch_item(manifest, item_id),
         :ok <- no_violations(label_violations(item_id, labels, manifest)) do
      # S-29: "adjudicated" only while the owner's category is still the
      # override the item was seeded with.
      source =
        if item.seed_category != nil and labels["category"] == item.seed_category,
          do: "adjudicated",
          else: "new"

      updated = %{
        item
        | labels: labels,
          labelled_at: now,
          labelled_by: @labelled_by,
          label_sources: Map.put(item.label_sources, "category", source)
      }

      {:ok, replace_item(manifest, updated)}
    end
  end

  @spec put_tier(t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, [violation()]}
  def put_tier(manifest, item_id, tier, reason, now) do
    with :ok <- not_frozen(manifest, item_id),
         {:ok, item} <- fetch_item(manifest, item_id),
         :ok <-
           no_violations(
             if(tier in @tiers, do: [], else: [{:tier_invalid, item_id, tier}]) ++
               if(blank?(reason), do: [{:empty_tier_reason, item_id, reason}], else: [])
           ) do
      {:ok, replace_item(manifest, %{item | tier: tier, tier_reason: reason, tiered_at: now})}
    end
  end

  @spec put_language(t(), String.t(), String.t()) :: {:ok, t()} | {:error, [violation()]}
  def put_language(manifest, item_id, lang) do
    with :ok <- not_frozen(manifest, item_id),
         {:ok, item} <- fetch_item(manifest, item_id),
         :ok <-
           no_violations(
             if lang in @languages, do: [], else: [{:language_invalid, item_id, lang}]
           ) do
      {:ok, replace_item(manifest, %{item | language: lang, language_source: "human"})}
    end
  end

  @spec add_synthetic_item(t(), String.t(), Item.state(), String.t()) ::
          {:ok, {t(), String.t()}} | {:error, [violation()]}
  def add_synthetic_item(manifest, of_item_id, state, _now) do
    with :ok <- not_frozen(manifest, of_item_id),
         {:ok, source} <- fetch_item(manifest, of_item_id),
         new_id = next_item_id(manifest.items),
         item = %Item{
           id: new_id,
           synthetic_of: source.id,
           language: source.language,
           language_source: source.language_source,
           state: state
         },
         :ok <- no_violations(body_violations(item)) do
      {:ok, {recount(%{manifest | items: manifest.items ++ [item]}), new_id}}
    end
  end

  @spec mark_pair(t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, [violation()]}
  def mark_pair(manifest, pair_id, item_a, item_b, fact) do
    with :ok <- not_frozen(manifest, nil),
         {:ok, a} <- fetch_item(manifest, item_a),
         {:ok, b} <- fetch_item(manifest, item_b),
         :ok <- no_violations(pair_mark_violations(manifest, pair_id, a, b, fact)) do
      manifest
      |> replace_item(%{a | pair_id: pair_id, pair_fact: fact})
      |> replace_item(%{b | pair_id: pair_id, pair_fact: fact})
      |> then(&{:ok, &1})
    end
  end

  defp pair_mark_violations(manifest, pair_id, a, b, fact) do
    taken =
      for item <- manifest.items,
          item.pair_id == pair_id,
          item.id not in [a.id, b.id],
          do: item.id

    List.flatten([
      if(a.id == b.id,
        do: [{:pair_incomplete, a.id, %{pair_id: pair_id, items: [a.id]}}],
        else: []
      ),
      if(taken == [],
        do: [],
        else: [{:pair_incomplete, hd(taken), %{pair_id: pair_id, items: taken}}]
      ),
      for item <- [a, b], item.pair_id not in [nil, pair_id] do
        {:pair_incomplete, item.id, %{already_in: item.pair_id}}
      end,
      if(a.labels == nil or b.labels == nil or a.labels == b.labels,
        do: [{:pair_no_flip, a.id, %{pair_id: pair_id, items: [a.id, b.id]}}],
        else: []
      ),
      if(blank?(fact), do: [{:pair_fact_blank, a.id, %{pair_id: pair_id}}], else: [])
    ])
  end

  # The single frozen guard shared by every mutating function (F08.4/F08.5).
  defp not_frozen(%__MODULE__{frozen_at: nil}, _item_id), do: :ok

  defp not_frozen(%__MODULE__{frozen_at: frozen_at}, item_id),
    do: {:error, [{:frozen, item_id, %{frozen_at: frozen_at}}]}

  defp fetch_item(manifest, item_id) do
    case Enum.find(manifest.items, &(&1.id == item_id)) do
      nil -> {:error, [{:unknown_item, item_id, nil}]}
      item -> {:ok, item}
    end
  end

  defp replace_item(manifest, %Item{id: id} = updated) do
    items = Enum.map(manifest.items, fn item -> if item.id == id, do: updated, else: item end)
    recount(%{manifest | items: items})
  end

  defp next_item_id(items) do
    max =
      items
      |> Enum.map(fn item ->
        case Regex.run(~r/\Ait-(\d+)\z/, item.id) do
          [_, digits] -> String.to_integer(digits)
          nil -> 0
        end
      end)
      |> Enum.max(fn -> 0 end)

    "it-" <> String.pad_leading(Integer.to_string(max + 1), 4, "0")
  end

  defp no_violations([]), do: :ok
  defp no_violations(violations), do: {:error, violations}

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  # -- freeze / split ---------------------------------------------------------

  @spec freeze(t(), integer(), String.t(), keyword()) :: {:ok, t()} | {:error, [violation()]}
  def freeze(manifest, seed, now, opts) do
    with :ok <- not_frozen(manifest, nil),
         :ok <- validate(manifest),
         shortfall = mix_shortfall(manifest.counts),
         allow? = Keyword.get(opts, :allow_mix_shortfall, false),
         :ok <- no_violations(freeze_violations(manifest, shortfall, allow?)) do
      split = assign_split(manifest, @calibration_size, seed)
      export = Map.put(split.export || %{}, :mix_shortfall_acknowledged, shortfall != %{})
      {:ok, %{split | frozen_at: now, export: export}}
    end
  end

  defp freeze_violations(manifest, shortfall, allow?) do
    items = manifest.items
    real = Enum.count(items, &real?/1)

    flipped_pairs =
      items
      |> Enum.reject(&is_nil(&1.pair_id))
      |> Enum.group_by(& &1.pair_id)
      |> Enum.count(fn {_, members} ->
        match?([_, _], members) and Enum.uniq_by(members, & &1.labels) |> length() == 2
      end)

    List.flatten([
      for(item <- items, item.labels == nil, do: {:unlabelled, item.id, nil}),
      for(item <- items, item.tier == nil, do: {:untiered, item.id, nil}),
      if(real < @min_real_items,
        do: [{:too_few_real_items, nil, %{real: real, min: @min_real_items}}],
        else: []
      ),
      if(flipped_pairs < @min_pairs,
        do: [{:too_few_pairs, nil, %{pairs: flipped_pairs, min: @min_pairs}}],
        else: []
      ),
      if(shortfall != %{} and not allow?,
        do: [{:language_mix_shortfall, nil, shortfall}],
        else: []
      )
    ])
  end

  # Shares are over counts.total, synthetic items included (S-21).
  defp mix_shortfall(%{total: total, by_language: by_language}) when total > 0 do
    for {lang, min} <- @language_mix,
        share = Map.get(by_language, lang, 0) / total,
        share < min,
        into: %{},
        do: {lang, %{share: share, min: min}}
  end

  defp mix_shortfall(_counts),
    do: Map.new(@language_mix, fn {lang, min} -> {lang, %{share: 0, min: min}} end)

  @doc """
  Marks exactly `n` eligible (non-pair) items `"calibration"` and every other
  item `"eval"`. Strata are `(language, tier)` over the eligible pool, with
  quota `n · n_s / N` and largest-remainder rounding; within a stratum the
  items with the lowest seeded draw are taken. Pure: the `:rand` state is
  threaded explicitly and the process state is never touched (S-17, S-18).
  """
  @spec assign_split(t(), pos_integer(), integer()) :: t()
  def assign_split(%__MODULE__{} = manifest, n, seed) do
    eligible = manifest.items |> Enum.filter(&is_nil(&1.pair_id)) |> Enum.sort_by(& &1.id)
    n = min(n, length(eligible))

    {draws, _state} =
      Enum.map_reduce(eligible, :rand.seed_s(:exsss, {seed, 0, 0}), fn item, state ->
        {draw, state} = :rand.uniform_s(state)
        {{item, draw}, state}
      end)

    strata = Enum.group_by(draws, fn {item, _} -> {item.language, item.tier} end)
    quotas = largest_remainder(strata, n, length(eligible))

    calibration =
      for {key, members} <- strata,
          {item, _draw} <-
            members
            |> Enum.sort_by(fn {item, draw} -> {draw, item.id} end)
            |> Enum.take(quotas[key]),
          into: MapSet.new(),
          do: item.id

    items =
      Enum.map(manifest.items, fn item ->
        %{item | split: if(MapSet.member?(calibration, item.id), do: "calibration", else: "eval")}
      end)

    recount(%{manifest | items: items})
  end

  # Integer arithmetic throughout: base = ⌊n·n_s/N⌋, and the remaining seats go
  # to the strata with the largest remainders (ties broken by stratum key).
  defp largest_remainder(_strata, _n, 0), do: %{}

  defp largest_remainder(strata, n, total) do
    base = Map.new(strata, fn {key, members} -> {key, div(n * length(members), total)} end)
    left = n - Enum.sum(Map.values(base))

    strata
    |> Enum.map(fn {key, members} -> {key, rem(n * length(members), total)} end)
    |> Enum.sort_by(fn {key, remainder} -> {-remainder, key} end)
    |> Enum.take(left)
    |> Enum.reduce(base, fn {key, _}, acc -> Map.update!(acc, key, &(&1 + 1)) end)
  end

  # -- read side --------------------------------------------------------------

  @spec items(t(), :eval | :calibration) :: {:ok, [Item.t()]} | {:error, :not_frozen}
  def items(%__MODULE__{frozen_at: nil}, _split), do: {:error, :not_frozen}

  def items(%__MODULE__{items: items}, split) when split in [:eval, :calibration] do
    wanted = Atom.to_string(split)
    {:ok, Enum.filter(items, &(&1.split == wanted))}
  end

  @spec training_export(t()) :: {:ok, [Item.t()]} | {:error, :not_frozen}
  def training_export(%__MODULE__{frozen_at: nil}), do: {:error, :not_frozen}

  def training_export(%__MODULE__{items: items}),
    do: {:ok, Enum.reject(items, &(&1.split == "calibration"))}

  @spec ready_for_run?(t()) :: :ok | {:error, violation()}
  def ready_for_run?(%__MODULE__{frozen_at: nil}), do: {:error, {:not_frozen, nil, nil}}

  def ready_for_run?(%__MODULE__{} = manifest) do
    with :ok <- first_violation(validate(manifest)),
         :ok <- first_violation(late_violations(manifest)) do
      :ok
    end
  end

  defp first_violation(:ok), do: :ok
  defp first_violation({:error, [violation | _]}), do: {:error, violation}

  # Labels and tiers must predate the freeze; a label or tier stamped after
  # frozen_at means the set was touched after the split was drawn (F08.4).
  defp late_violations(%{frozen_at: frozen_at, items: items}) do
    violations =
      for item <- items,
          {field, code} <- [labelled_at: :labelled_after_freeze, tiered_at: :tiered_after_freeze],
          stamp = Map.fetch!(item, field),
          not before_or_at?(stamp, frozen_at) do
        {code, item.id, %{field => stamp, frozen_at: frozen_at}}
      end

    no_violations(violations)
  end

  defp before_or_at?(stamp, frozen_at) do
    with {:ok, stamp, _} <- parse_time(stamp),
         {:ok, frozen, _} <- parse_time(frozen_at) do
      DateTime.compare(stamp, frozen) != :gt
    else
      _ -> false
    end
  end

  defp parse_time(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_time(_value), do: :error
end
