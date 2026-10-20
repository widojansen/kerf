defmodule Kerf.Eval.Manifest do
  @moduledoc """
  SPEC_H F08 — the Decide labelled-set manifest: struct, loader, validator, freeze.

  Contract: plan §2.1 (docs/superpowers/plans/2026-10-20-decide-eval-step2-3.md)
  with addendum 03 (A3.5, A3.9) and the lead rulings S-16..S-19. Closes
  F08.1 (counts + language mix), F08.2 (label validation), F08.3 (pairs),
  F08.4 (`ready_for_run?/1`), F08.5 (held-out calibration split, training
  export refusal) and F08.7 (`label_sources`).

  Errors are `{:error, [violation]}` with
  `violation :: {code, item_id | nil, detail}`; nothing here raises.
  Question order lives only in `Kerf.Eval.Manifest.QuestionSet.order/0` (S-16).
  """

  alias Kerf.Eval.Manifest.Item

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
          export: export(),
          question_set: %{String.t() => question_def()},
          counts: counts(),
          items: [Item.t()]
        }

  @type violation :: {atom(), String.t() | nil, term()}

  @spec load(Path.t()) :: {:ok, t()} | {:error, [violation()]}
  def load(_path), do: not_implemented("F08.1")

  @spec validate(t()) :: :ok | {:error, [violation()]}
  def validate(_manifest), do: not_implemented("F08.2")

  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(_manifest, _path), do: not_implemented("F08.1")

  @spec put_label(t(), String.t(), map(), String.t()) :: {:ok, t()} | {:error, [violation()]}
  def put_label(_manifest, _item_id, _labels, _now), do: not_implemented("F08.2")

  @spec put_tier(t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, [violation()]}
  def put_tier(_manifest, _item_id, _tier, _reason, _now),
    do: not_implemented("F08.4")

  @spec put_language(t(), String.t(), String.t()) :: {:ok, t()} | {:error, [violation()]}
  def put_language(_manifest, _item_id, _lang), do: not_implemented("F08.1")

  @spec add_synthetic_item(t(), String.t(), Item.state(), String.t()) ::
          {:ok, {t(), String.t()}} | {:error, [violation()]}
  def add_synthetic_item(_manifest, _of_item_id, _state, _now),
    do: not_implemented("F08.3")

  @spec mark_pair(t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, [violation()]}
  def mark_pair(_manifest, _pair_id, _item_a, _item_b, _fact),
    do: not_implemented("F08.3")

  @spec freeze(t(), integer(), String.t(), keyword()) :: {:ok, t()} | {:error, [violation()]}
  def freeze(_manifest, _seed, _now, _opts), do: not_implemented("F08.5")

  @spec assign_split(t(), pos_integer(), integer()) :: t()
  def assign_split(_manifest, _n, _seed), do: not_implemented("F08.5")

  @spec items(t(), :eval | :calibration) :: {:ok, [Item.t()]} | {:error, :not_frozen}
  def items(_manifest, _split), do: not_implemented("F08.5")

  @spec training_export(t()) :: {:ok, [Item.t()]} | {:error, :not_frozen}
  def training_export(_manifest), do: not_implemented("F08.5")

  @spec ready_for_run?(t()) :: :ok | {:error, violation()}
  def ready_for_run?(_manifest), do: not_implemented("F08.4")

  @spec sha256(Path.t()) :: String.t()
  def sha256(_path), do: not_implemented("F08.1")

  # RED skeleton: apply/3 keeps Elixir 1.20's type inference from typing the
  # body as none(), which would turn every test call site into a type warning.
  defp not_implemented(check),
    do: apply(:erlang, :error, [RuntimeError.exception("not implemented (SPEC_H #{check})")])
end
