defmodule Kerf.Decide do
  @moduledoc """
  SPEC_H F01 — RED skeleton.

  `ask(state, questions, opts)` validates the request in Elixir, then
  dispatches to `opts[:adapter]` or `Application.get_env(:kerf,
  Kerf.Decide)[:adapter]`, passing opts through. Returns
  `{:ok, %{name => Kerf.Decide.Result.t()}}` or `{:error, reason}`:
  `{:invalid_request, {name, reason}}`, `{:invalid_request, :missing_provenance}`,
  `{:invalid_request, :provenance_not_accepted}`, `{:schema_violation, detail}`,
  or the adapter's own error.
  """

  @spec ask(Kerf.Decide.State.t(), [Kerf.Decide.Question.t()], keyword()) ::
          {:ok, %{atom() => Kerf.Decide.Result.t()}} | {:error, term()}
  def ask(_state, _questions, _opts \\ []),
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.ask/3")
end
