defmodule Kerf.Decide.Gate.Approved do
  @moduledoc """
  SPEC_H F06.4 — RED skeleton. PLACEHOLDER for %Kerf.Gate.Approved{} (SPEC_G).

  An approval binds one action to one approver. Construct only through
  Kerf.Decide.Gate.approve/2; OptionSet.act/3 checks an approval, never builds one.
  """

  @enforce_keys [:action, :approver, :approved_at]
  defstruct [:action, :approver, :approved_at]

  @type t :: %__MODULE__{
          action: Kerf.Decide.OptionSet.action(),
          approver: atom(),
          approved_at: NaiveDateTime.t()
        }
end
