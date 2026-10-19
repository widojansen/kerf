defmodule Kerf.Decide.Gate do
  @moduledoc """
  Stand-in until SPEC_G Kerf.Gate lands. Delete this module then; do not upgrade it.

  SPEC_H F06.4 / addendum A1.1. `approve/2` always returns
  `{:error, :gate_not_available}`: it writes nothing, checks nothing, and never
  returns a Kerf.Decide.Gate.Approved struct. Until Kerf.Gate exists, no :effect
  action is reachable through OptionSet.act/3 outside tests.
  """

  @spec approve(Kerf.Decide.OptionSet.action(), atom()) :: {:error, :gate_not_available}
  def approve(_action, _approver), do: {:error, :gate_not_available}
end
