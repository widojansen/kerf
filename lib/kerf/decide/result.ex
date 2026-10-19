defmodule Kerf.Decide.Result do
  @moduledoc """
  SPEC_H F01.1 — Result shapes, as types only.

  Results are plain maps, not a struct: F01.1 requires each result to have
  EXACTLY the keys below, and a struct would add `:__struct__`. `probs` is
  an ordered list keyed by the caller's labels in the caller's order (F01.4).
  """

  @type probs :: [{String.t(), float()}]

  @type noul :: %{
          p_yes: float(),
          backend: module(),
          latency_ms: non_neg_integer(),
          provenance: Kerf.Decide.State.provenance()
        }

  @type choice :: %{
          label: String.t(),
          probs: probs(),
          confidence: float(),
          backend: module(),
          latency_ms: non_neg_integer(),
          provenance: Kerf.Decide.State.provenance()
        }

  @type score :: %{
          expected: float(),
          probs: probs(),
          confidence: float(),
          backend: module(),
          latency_ms: non_neg_integer(),
          provenance: Kerf.Decide.State.provenance()
        }

  @type t :: noul() | choice() | score()
end
