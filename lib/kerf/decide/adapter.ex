defmodule Kerf.Decide.Adapter do
  @moduledoc """
  SPEC_H F01.5 — The behaviour every decision backend implements.

  `ask/3` receives the validated state, the questions, and the caller's opts
  (passed through, e.g. `base_url:`). Raw answers per type:

    * Noul   — `%{p_yes: float}`
    * Choice — `%{probs: [{label, p}]}` in any order; any `:confidence` or
      `:label` the adapter adds is ignored (F01.3, F01.4)
    * Score  — `%{expected: float, probs: [{level, p}], confidence: float}`
  """

  @type info :: %{
          model_id: String.t(),
          types: [:noul | :choice | :score],
          max_state_tokens: pos_integer(),
          languages: [String.t()]
        }

  @callback ask(Kerf.Decide.State.t(), [Kerf.Decide.Question.t()], keyword()) ::
              {:ok, %{atom() => map()}} | {:error, term()}

  @callback info() :: info()
end
