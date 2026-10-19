defmodule Kerf.Decide.Question.Score do
  @moduledoc "SPEC_H F01 — Position on an ordered rubric of 2..10 levels."

  @enforce_keys [:name, :instructions, :levels]
  defstruct [:name, :instructions, :levels, criteria: nil, branch: nil]

  @type t :: %__MODULE__{
          name: atom(),
          instructions: String.t() | map(),
          levels: [String.t()],
          criteria: map() | nil,
          branch: atom() | nil
        }
end
