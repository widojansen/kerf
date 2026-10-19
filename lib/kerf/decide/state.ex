defmodule Kerf.Decide.State do
  @moduledoc """
  SPEC_H F01.6 — the state a request is asked against.

  `provenance` is shaped per SPEC_G §4 (`taint`, `origin`, `sources`); until
  Kerf.Provenance lands it is a plain map, and Kerf.Decide never accepts one
  from opts or from `content` (I1).
  """

  @enforce_keys [:content, :provenance]
  defstruct [:content, :provenance]

  @type provenance :: %{
          taint: :clean | :tainted,
          origin: :human | :ingress | :derived,
          sources: [String.t()]
        }

  @type t :: %__MODULE__{content: String.t() | map(), provenance: provenance() | nil}
end
