defmodule Kerf.Decide.Gate do
  @moduledoc """
  SPEC_H F06.4 — RED skeleton. PLACEHOLDER, private to the Decide subtree.

  The only constructor of %Kerf.Decide.Gate.Approved{}. Stands in for
  Kerf.Gate (SPEC_G G0.2), which does not exist yet.
  TODO(SPEC_G): replace with Kerf.Gate.approve/2 and %Kerf.Gate.Approved{}.
  """

  @spec approve(Kerf.Decide.OptionSet.action(), atom()) :: {:ok, Kerf.Decide.Gate.Approved.t()}
  def approve(_action, _approver),
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.Gate.approve/2")
end
