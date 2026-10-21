defmodule Kerf.Eval.Manifest.PII do
  @moduledoc """
  SPEC_H F08.6 — the PII guard. Real addresses never enter a git tree; instead
  the export writes the SHA-256 of every sender address (outside the repo) and
  `scan/2` walks the tracked trees looking for any address whose hash is in
  that list. The hash list itself is never committed (A3.7).

  An address is normalised (trimmed, downcased) before hashing, so case and
  padding cannot slip a real address past the scan.
  """

  alias Kerf.Eval.Manifest

  @header "# sha256 of addresses in the decide set"

  @doc "The header written as the first line of a hash file."
  @spec header() :: String.t()
  def header, do: @header

  @doc """
  Lowercase hex SHA-256 of each downcased, trimmed `state.from` of every real
  item (`doc_id` non-nil), deduplicated and sorted.
  """
  @spec address_hashes(Manifest.t()) :: [String.t()]
  def address_hashes(%Manifest{} = _manifest), do: not_implemented("F08.6 address_hashes/1")

  @doc """
  Writes `hashes` sorted, one per line, under the header, atomically (tmp file
  next to the target, then rename).
  """
  @spec write_hashes([String.t()], Path.t()) :: :ok | {:error, term()}
  def write_hashes(hashes, path) when is_list(hashes) and is_binary(path),
    do: not_implemented("F08.6 write_hashes/2")

  @doc """
  Reads a hash file. `#` lines and blank lines are skipped; a line that is not
  64 lowercase hex characters is `{:error, {:line, n, _}}`. Never raises.
  """
  @spec read_hashes(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def read_hashes(path) when is_binary(path), do: not_implemented("F08.6 read_hashes/1")

  @doc """
  Walks every file under each of `paths` and returns the `{file, line_no}` of
  each line holding an address-shaped token whose normalised hash is in
  `hashes`. Pure: it prints nothing and never reports the address itself.
  """
  @spec scan([Path.t()], [String.t()]) :: [{Path.t(), pos_integer()}]
  def scan(paths, hashes) when is_list(paths) and is_list(hashes),
    do: not_implemented("F08.6 scan/2")

  # RED skeleton: apply/3 keeps Elixir 1.20's type inference from typing the
  # body as none(), which would turn every test call site into a type warning.
  defp not_implemented(check),
    do: apply(:erlang, :error, [RuntimeError.exception("not implemented (SPEC_H #{check})")])
end
