defmodule Kerf.Decide.NotImplemented do
  @moduledoc "SPEC_H step 1 — RED skeleton marker. Raised by every unimplemented Kerf.Decide function."

  defexception [:function]

  @impl true
  def message(%__MODULE__{function: function}),
    do: "#{function} is not implemented (SPEC_H RED skeleton)"
end
