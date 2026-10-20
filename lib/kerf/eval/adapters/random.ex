defmodule Kerf.Eval.Adapters.Random do
  @moduledoc """
  SPEC_H F09.9 — the known-bad adapter: uniform random probabilities,
  deterministic from `opts[:harness_seed]`. Must fail F09.1, F09.7 and raw
  F09.2 (addendum 03, A3.2).
  """

  @behaviour Kerf.Decide.Adapter

  @impl true
  @spec ask(Kerf.Decide.State.t(), [Kerf.Decide.Question.t()], keyword()) ::
          {:ok, %{atom() => map()}} | {:error, term()}
  def ask(_state, _questions, _opts), do: raise("not implemented (SPEC_H F09.9)")

  @impl true
  @spec info() :: Kerf.Decide.Adapter.info()
  def info, do: raise("not implemented (SPEC_H F09.9)")
end
