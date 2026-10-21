defmodule Kerf.Eval.Harness do
  @moduledoc """
  SPEC_H F09.3 / F09.4 / F09.6 / F09.8 / F08.4 — run a frozen manifest through
  `Kerf.Decide.ask/3` and produce the run JSONL lines (plan §2.3, §2.6, §7 H3).

  Per item, in manifest order: one packed main request per order index, one
  separate request per question, and — for the isolation items — a sibling
  request and a state request carrying the secret token. Lines follow the
  §2.3 order; every request goes through `Kerf.Decide.ask/3` and nothing else.
  An adapter failure becomes error lines and the run continues; `run/2` never
  raises.
  """

  alias Kerf.Decide.{OptionSet, State}
  alias Kerf.Decide.Question.{Choice, Noul, Score}
  alias Kerf.Eval.Adapters.{Oracle, Random}
  alias Kerf.Eval.Harness.{Questions, Run}
  alias Kerf.Eval.Manifest

  @type run_result :: %{header: map(), lines: [map()], end: map()}

  # Fixed Phase B key list, same as Questions; never String.to_atom/1.
  @names %{
    "category" => :category,
    "needs_reply" => :needs_reply,
    "urgency" => :urgency,
    "deadline_present" => :deadline_present,
    "client" => :client
  }

  # harness_seed question slots beyond the five question indices (S-28 (6)).
  @isolation_slot 5
  @packed_slot 6

  @spec run(Manifest.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(manifest, opts) do
    sink = Keyword.get(opts, :sink, fn _line -> :ok end)

    with {:ok, adapter} <- required_option(opts, :adapter),
         {:ok, seed} <- required_option(opts, :seed),
         :ok <- Manifest.ready_for_run?(manifest),
         {:ok, sha256} <- manifest_sha256(opts[:manifest_path]),
         {:ok, info} <- adapter_info(adapter),
         {:ok, questions} <- Questions.from_question_set(manifest.question_set) do
      ctx = context(manifest, adapter, seed, questions, opts)
      header = header(manifest, ctx, sha256, info, opts)
      sink.(header)

      lines =
        Enum.flat_map(ctx.scope, fn {item, item_index} ->
          item_lines = item_lines(ctx, item, item_index)
          Enum.each(item_lines, sink)
          item_lines
        end)

      run_end =
        Run.end_line(%{
          "finished_at" => now(),
          "answers" => length(lines),
          "errors" => Enum.count(lines, &(&1["error"] != nil))
        })

      sink.(run_end)
      {:ok, %{header: header, lines: lines, end: run_end}}
    end
  end

  # ---------- set-up ----------

  defp required_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  # Manifest.sha256/1 calls File.read/1, which raises on nil.
  defp manifest_sha256(nil), do: {:error, {:manifest_sha256, :no_manifest_path}}

  defp manifest_sha256(path) do
    case Manifest.sha256(path) do
      {:ok, hex} -> {:ok, hex}
      {:error, reason} -> {:error, {:manifest_sha256, reason}}
    end
  end

  defp adapter_info(adapter) do
    case adapter.info() do
      %{} = info when not is_struct(info) -> {:ok, info}
      other -> {:error, {:invalid_header, other}}
    end
  end

  defp context(manifest, adapter, seed, questions, opts) do
    limit = opts[:limit]
    isolation_items = Keyword.get(opts, :isolation_items, 30)
    indexed = Enum.with_index(manifest.items)
    scope = if limit, do: Enum.take(indexed, limit), else: indexed

    %{
      adapter: adapter,
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      seed: seed,
      permutations: Keyword.get(opts, :permutations, 6),
      isolation_items: isolation_items,
      limit: limit,
      questions: questions,
      token: token(seed),
      scope: scope,
      isolation_ids: isolation_ids(scope, isolation_items)
    }
  end

  # The first `n` eval-split items by id among the in-scope items (S-28 (2), (3)).
  defp isolation_ids(scope, n) do
    scope
    |> Enum.map(fn {item, _index} -> item end)
    |> Enum.filter(&(&1.split == "eval"))
    |> Enum.map(& &1.id)
    |> Enum.sort()
    |> Enum.take(n)
    |> MapSet.new()
  end

  defp token(seed) do
    "KERF-" <>
      (Base.encode16(:crypto.hash(:sha256, Integer.to_string(seed)), case: :lower)
       |> binary_part(0, 12))
  end

  defp header(manifest, ctx, sha256, info, opts) do
    started_at = now()

    Run.header(%{
      "run_id" => run_id(manifest.set_id, ctx.adapter, ctx.seed, started_at),
      "set_id" => manifest.set_id,
      "manifest_path" => opts[:manifest_path],
      "manifest_sha256" => sha256,
      "manifest_frozen_at" => manifest.frozen_at,
      "adapter" => inspect(ctx.adapter),
      "adapter_opts" => Map.new(ctx.adapter_opts),
      "info" => info,
      "seed" => ctx.seed,
      "permutations" => ctx.permutations,
      "isolation_items" => ctx.isolation_items,
      "limit" => ctx.limit,
      "latency_skipped" => ctx.adapter in [Oracle, Random] or opts[:skip_latency] == true,
      "host" => host(),
      "kerf_git_sha" => git_sha(),
      "started_at" => started_at
    })
  end

  # "<set_id>-<adapter-short>-s<seed>-<started_at>" (plan §2.3).
  defp run_id(set_id, adapter, seed, started_at) do
    short = adapter |> Module.split() |> List.last() |> String.downcase()
    "#{set_id}-#{short}-s#{seed}-#{started_at}"
  end

  defp host do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  # A release has no git checkout; the header then records "unknown".
  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # ---------- requests per item ----------

  defp item_lines(ctx, item, item_index) do
    main_lines(ctx, item, item_index) ++
      separate_lines(ctx, item, item_index) ++
      isolation_lines(ctx, item, item_index)
  end

  defp main_lines(ctx, item, item_index) do
    orders =
      ctx.questions
      |> Enum.with_index()
      |> Enum.map(fn {question, question_index} ->
        {question.name,
         Questions.orders_for(question, ctx.seed, item_index, question_index, ctx.permutations)}
      end)

    Enum.flat_map(0..(ctx.permutations - 1)//1, fn order_index ->
      order =
        for {name, per_index} <- orders,
            o = Enum.at(per_index, order_index),
            into: %{},
            do: {name, o}

      {:ok, permuted} = Questions.permute(ctx.questions, order)

      request = %{
        state: state(item),
        questions: permuted,
        gold: gold(item),
        seed: {ctx.seed, item_index * 64 + @packed_slot, order_index}
      }

      lines(ctx, item, request, probe: "main", packed: true, order_index: order_index)
    end)
  end

  defp separate_lines(ctx, item, item_index) do
    ctx.questions
    |> Enum.with_index()
    |> Enum.flat_map(fn {question, question_index} ->
      request = %{
        state: state(item),
        questions: [question],
        gold: gold(item),
        seed: {ctx.seed, item_index * 64 + question_index, 0}
      }

      lines(ctx, item, request, probe: "separate", packed: false, order_index: 0)
    end)
  end

  # Sibling: the token sits in a sibling question's instructions, the content is
  # unchanged. State: the token sits in the content only (S-31 (c)). Only the
  # probe's line is written (S-31 (b)).
  defp isolation_lines(ctx, item, item_index) do
    if MapSet.member?(ctx.isolation_ids, item.id) do
      probe = Questions.secret_probe(ctx.token)
      [sibling | _] = ctx.questions
      tokened = %{sibling | instructions: sibling.instructions <> " " <> ctx.token}
      state = state(item)

      sibling_request = %{
        state: state,
        questions: [tokened, probe],
        gold: Map.put(gold(item), :secret_present, false),
        seed: {ctx.seed, item_index * 64 + @isolation_slot, 0}
      }

      state_request = %{
        state: %{state | content: state.content <> "\n" <> ctx.token},
        questions: [sibling, probe],
        gold: Map.put(gold(item), :secret_present, true),
        seed: {ctx.seed, item_index * 64 + @isolation_slot, 1}
      }

      line_opts = [packed: false, order_index: 0, only: :secret_present]

      lines(ctx, item, sibling_request, [probe: "isolation_sibling"] ++ line_opts) ++
        lines(ctx, item, state_request, [probe: "isolation_state"] ++ line_opts)
    else
      []
    end
  end

  # ---------- asking and lines ----------

  defp lines(ctx, item, request, line_opts) do
    response = ask(ctx, request)

    request.questions
    |> Enum.filter(&(line_opts[:only] in [nil, &1.name]))
    |> Enum.map(&answer_line(item, &1, request.gold, response, line_opts))
  end

  # The only way out to an adapter (§2.6). Oracle alone receives harness_gold,
  # Random alone harness_seed; every other adapter gets neither.
  defp ask(ctx, request) do
    extras =
      case ctx.adapter do
        Oracle -> [harness_gold: request.gold]
        Random -> [harness_seed: request.seed]
        _real -> []
      end

    try do
      Kerf.Decide.ask(
        request.state,
        request.questions,
        [adapter: ctx.adapter] ++ ctx.adapter_opts ++ extras
      )
    rescue
      exception -> {:error, exception}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp answer_line(item, question, gold, response, line_opts) do
    key = Atom.to_string(question.name)

    {result, latency_ms, error} =
      case response do
        {:ok, results} -> {results[question.name], results[question.name].latency_ms, nil}
        {:error, reason} -> {nil, nil, inspect(reason)}
      end

    Run.answer_line(%{
      "item_id" => item.id,
      "doc_id" => item.doc_id,
      "language" => item.language,
      "tier" => item.tier,
      "split" => item.split,
      "pair_id" => item.pair_id,
      "question" => key,
      "qtype" => qtype(question),
      "probe" => line_opts[:probe],
      "packed" => line_opts[:packed],
      "order_index" => line_opts[:order_index],
      "order" => order(question),
      "gold" => Map.get(gold, question.name),
      "result" => result,
      "latency_ms" => latency_ms,
      "error" => error
    })
  end

  defp qtype(%Noul{}), do: "noul"
  defp qtype(%Choice{}), do: "choice"
  defp qtype(%Score{}), do: "score"

  defp order(%Choice{options: options}), do: OptionSet.labels(options)
  defp order(_question), do: nil

  defp gold(item), do: Map.new(@names, fn {key, name} -> {name, item.labels[key]} end)

  defp state(item) do
    s = item.state

    %State{
      content:
        "From: #{s.from_name} <#{s.from}>\nSubject: #{s.subject}\nDate: #{s.date}\n\n#{s.body}",
      provenance: %{taint: :tainted, origin: :ingress, sources: [item.id]}
    }
  end
end
