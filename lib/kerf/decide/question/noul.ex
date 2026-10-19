defmodule Kerf.Decide.Question.Noul do
  @moduledoc "SPEC_H F01 — RED skeleton. Yes/no question; answered with p_yes."

  @enforce_keys [:name, :instructions]
  defstruct [:name, :instructions, criteria: nil, branch: nil]

  @type t :: %__MODULE__{
          name: atom(),
          instructions: String.t() | map(),
          criteria: %{optional(true) => String.t(), optional(false) => String.t()} | nil,
          branch: atom() | nil
        }
end
