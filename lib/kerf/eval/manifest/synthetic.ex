defmodule Kerf.Eval.Manifest.Synthetic do
  @moduledoc """
  SPEC_H F08 / F09.9 — seeded synthetic manifest; the only manifest the tests
  and the harness self-test ever use (plan §2.1, ruling S-17).

  `n` real items (`doc_id` set) plus `pairs` appended synthetic b-items
  (`doc_id: nil`, `synthetic_of` set, same language as the a-item, one label
  flipped). Addresses are `user<n>@example.invalid`; clients are
  `"client-a".."client-c"`. Skips the freeze thresholds and calls
  `Kerf.Eval.Manifest.assign_split/3`; `frozen: false` returns it unfrozen.

  Languages follow a fixed 9:6:5 NL/DE/EN cycle over the real items, so the
  freeze language mix holds for every seed; the seed drives labels, tiers and
  the choice of a-items. Every `labelled_at`/`tiered_at` precedes `frozen_at`.
  """

  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.{Item, QuestionSet}

  @clients ["client-a", "client-b", "client-c"]
  @tiers ["easy", "standard", "hard"]
  @labelled_by "wido"

  @created_at "2026-10-20T08:00:00Z"
  @labelled_at "2026-10-20T10:00:00Z"
  @frozen_at "2026-10-20T12:00:00Z"

  @language_cycle List.duplicate("nl", 9) ++ List.duplicate("de", 6) ++ List.duplicate("en", 5)

  @phrases %{
    "nl" => %{
      subject: "Vraag over het project",
      body:
        "Hallo, ik heb een vraag over de planning van het project. Kun je me laten weten wat de stand is?",
      deadline: "Graag een reactie voor vrijdag."
    },
    "de" => %{
      subject: "Frage zum Projekt",
      body:
        "Hallo, ich habe eine Frage zur Planung des Projekts. Kannst du mir den Stand mitteilen?",
      deadline: "Bitte antworte bis Freitag."
    },
    "en" => %{
      subject: "Question about the project",
      body:
        "Hello, I have a question about the planning of the project. Could you let me know the status?",
      deadline: "Please reply by Friday."
    }
  }

  @spec build(keyword()) :: Manifest.t()
  def build(opts \\ []) do
    n = Keyword.get(opts, :n, 220)
    pairs = Keyword.get(opts, :pairs, 24)
    seed = Keyword.get(opts, :seed, 1)
    frozen? = Keyword.get(opts, :frozen, true)

    question_set = QuestionSet.phase_b(@clients)
    state = :rand.seed_s(:exsss, {seed, 0, 0})

    {real, state} = Enum.map_reduce(1..n//1, state, &real_item(&1, &2, question_set))
    {a_ids, _state} = pick_a_items(real, pairs, state)
    {real, b_items} = pair_up(real, a_ids, n, question_set)

    manifest = %Manifest{
      set_id: "synthetic-s#{seed}",
      created_at: @created_at,
      export: %{
        host: "synthetic",
        exported_at: @created_at,
        query_sha256: :crypto.hash(:sha256, "synthetic") |> Base.encode16(case: :lower),
        overrides_sha256: nil,
        row_count: n,
        mix_shortfall_acknowledged: false
      },
      question_set: question_set,
      items: real ++ b_items
    }

    # assign_split/3 also fills counts; an unfrozen build gets them the same way.
    split = Manifest.assign_split(manifest, calibration_size(n, pairs), seed)

    if frozen?,
      do: %{split | frozen_at: @frozen_at},
      else: unsplit(split)
  end

  # The split only feeds counts.held_out, so clearing it leaves the rest of
  # the counts assign_split/3 computed intact.
  defp unsplit(manifest) do
    %{
      manifest
      | items: Enum.map(manifest.items, &%{&1 | split: nil}),
        counts: %{manifest.counts | held_out: 0}
    }
  end

  # S-17: 50 once there are ≥ 200 real items, else a fifth of the eligible pool.
  defp calibration_size(n, _pairs) when n >= 200, do: 50
  defp calibration_size(n, pairs), do: max(1, round(0.2 * (n - pairs)))

  defp real_item(i, state, question_set) do
    language = Enum.at(@language_cycle, rem(i - 1, length(@language_cycle)))
    {category, state} = pick(question_set["category"]["options"], state)
    {client, state} = pick(question_set["client"]["options"], state)
    {needs_reply, state} = pick([true, false], state)
    {deadline?, state} = pick([true, false], state)
    {urgency, state} = pick(1..5, state)
    {tier, state} = pick(@tiers, state)
    {source, state} = pick(["adjudicated", "new", "new"], state)

    phrases = @phrases[language]
    body = if deadline?, do: "#{phrases.body} #{phrases.deadline}", else: phrases.body

    item = %Item{
      id: item_id(i),
      doc_id: "doc-" <> pad(i),
      source_id: "src-" <> pad(i),
      language: language,
      state: %{
        from: "user#{i}@example.invalid",
        from_name: "User #{i}",
        subject: "#{phrases.subject} #{i}",
        date: @created_at,
        body: body
      },
      labels: %{
        "category" => category,
        "needs_reply" => needs_reply,
        "urgency" => urgency,
        "deadline_present" => deadline?,
        "client" => client
      },
      label_sources: %{"category" => source},
      labelled_at: @labelled_at,
      labelled_by: @labelled_by,
      tier: tier,
      tier_reason: "synthetic #{tier} item",
      tiered_at: @labelled_at
    }

    {item, state}
  end

  defp pick_a_items(real, pairs, state) do
    {keyed, state} =
      Enum.map_reduce(real, state, fn item, state ->
        {draw, state} = :rand.uniform_s(state)
        {{draw, item.id}, state}
      end)

    ids = keyed |> Enum.sort() |> Enum.take(pairs) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    {ids, state}
  end

  # The k-th a-item gets b-item it-(n+k); the flipped question cycles through
  # order/0 so every question is the contrast in some pair.
  defp pair_up(real, a_ids, n, question_set) do
    by_id = Map.new(real, &{&1.id, &1})

    {pairs, b_items} =
      a_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {a_id, k} ->
        a = Map.fetch!(by_id, a_id)
        pair_id = "pair-" <> pad(k)
        question = Enum.at(QuestionSet.order(), rem(k - 1, length(QuestionSet.order())))
        {labels, fact} = flip(a.labels, question, question_set)

        b = %{
          a
          | id: item_id(n + k),
            doc_id: nil,
            source_id: nil,
            synthetic_of: a.id,
            state: %{a.state | body: "#{a.state.body} (#{fact})"},
            labels: labels,
            label_sources: %{"category" => "new"},
            pair_id: pair_id,
            pair_fact: fact
        }

        {{a_id, {pair_id, fact}}, b}
      end)
      |> Enum.unzip()

    pairs = Map.new(pairs)

    real =
      Enum.map(real, fn item ->
        case Map.fetch(pairs, item.id) do
          {:ok, {pair_id, fact}} -> %{item | pair_id: pair_id, pair_fact: fact}
          :error -> item
        end
      end)

    {real, b_items}
  end

  defp flip(labels, "category", qs), do: next_option(labels, "category", qs)
  defp flip(labels, "client", qs), do: next_option(labels, "client", qs)

  defp flip(labels, "urgency", _qs) do
    value = rem(labels["urgency"], 5) + 1
    {%{labels | "urgency" => value}, "urgency changed to #{value}"}
  end

  defp flip(labels, noul, _qs) do
    value = not labels[noul]
    {%{labels | noul => value}, "#{noul} changed to #{value}"}
  end

  defp next_option(labels, question, qs) do
    options = qs[question]["options"]
    index = Enum.find_index(options, &(&1 == labels[question]))
    value = Enum.at(options, rem(index + 1, length(options)))
    {%{labels | question => value}, "#{question} changed to #{value}"}
  end

  defp pick(choices, state) do
    choices = Enum.to_list(choices)
    {index, state} = :rand.uniform_s(length(choices), state)
    {Enum.at(choices, index - 1), state}
  end

  defp item_id(i), do: "it-" <> pad(i)
  defp pad(i), do: String.pad_leading(Integer.to_string(i), 4, "0")
end
