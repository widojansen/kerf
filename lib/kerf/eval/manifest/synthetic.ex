defmodule Kerf.Eval.Manifest.Synthetic do
  @moduledoc """
  SPEC_H F08 / F09.9 — seeded synthetic manifest; the only manifest the tests
  and the harness self-test ever use (plan §2.1, ruling S-17).

  `n` real items (`doc_id` set) plus `pairs` appended synthetic b-items
  (`doc_id: nil`, `synthetic_of` set, same language as the a-item, one label
  flipped). Addresses are `user<n>@example.invalid`; clients are
  `"client-a".."client-c"`. Skips the freeze thresholds and calls
  `Kerf.Eval.Manifest.assign_split/3`; `frozen: false` returns it unfrozen.
  """

  @spec build(keyword()) :: Kerf.Eval.Manifest.t()
  def build(_opts \\ []), do: not_implemented("F08.5")

  # RED skeleton: apply/3 keeps Elixir 1.20's type inference from typing the
  # body as none(), which would turn every test call site into a type warning.
  defp not_implemented(check),
    do: apply(:erlang, :error, [RuntimeError.exception("not implemented (SPEC_H #{check})")])
end
