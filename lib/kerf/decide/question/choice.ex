defmodule Kerf.Decide.Question.Choice do
  @moduledoc "SPEC_H F01 / F06.1 — RED skeleton. Pick one of K options (2..255) from an OptionSet."

  @enforce_keys [:name, :instructions, :options]
  defstruct [:name, :instructions, :options, criteria: nil, branch: nil]

  @type t :: %__MODULE__{
          name: atom(),
          instructions: String.t() | map(),
          options: Kerf.Decide.OptionSet.t(),
          criteria: %{String.t() => String.t() | map()} | nil,
          branch: atom() | nil
        }
end
