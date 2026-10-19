defmodule Kerf.Decide.Gate.Approved do
  @moduledoc """
  SPEC_H F06.4 — PLACEHOLDER for %Kerf.Gate.Approved{} (SPEC_G).

  An approval binds one action to one approver. There is NO constructor in
  lib/: the stand-in Kerf.Decide.Gate refuses every request, and a grep guard
  (option_set_test.exs) fails if any lib/ file builds this struct.
  OptionSet.act/3 checks an approval, never builds one.
  TODO(SPEC_G): replace with %Kerf.Gate.Approved{}, built only by Kerf.Gate.
  """

  @enforce_keys [:action, :approver, :approved_at]
  defstruct [:action, :approver, :approved_at]

  @type t :: %__MODULE__{
          action: Kerf.Decide.OptionSet.action(),
          approver: atom(),
          approved_at: NaiveDateTime.t()
        }
end
