defmodule Kerf.Eval.Adapters.Oracle do
  @moduledoc """
  SPEC_H F09.9 — the known-good adapter: answers `opts[:harness_gold]`
  (question name => manifest gold label) with 0.97 on the gold answer.
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
