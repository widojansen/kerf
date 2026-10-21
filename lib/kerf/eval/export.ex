defmodule Kerf.Eval.Export do
  @moduledoc """
  SPEC_H F08.1 / F08.7 — read-only export of the Decide labelled-set candidates
  from the Spark over ssh + psql, selection toward the language mix, and the
  seeded `Kerf.Eval.Manifest` (plan §6 D2).

  RED skeleton: every function raises until GREEN.
  """

  alias Kerf.Eval.Manifest

  @type row :: %{
          doc_id: String.t(),
          source_id: String.t() | nil,
          from: String.t() | nil,
          from_name: String.t() | nil,
          subject: String.t() | nil,
          date: String.t() | nil,
          body: String.t(),
          inserted_at: String.t() | nil
        }

  @type config :: %{
          out: Path.t(),
          overrides: Path.t(),
          clients: Path.t(),
          since: String.t(),
          limit: pos_integer(),
          target: pos_integer(),
          host: String.t(),
          db: String.t(),
          raw: Path.t() | nil,
          hashes_out: Path.t() | nil
        }

  @spec query(keyword()) :: String.t()
  def query(_opts), do: not_implemented("F08.1 query")

  @spec ssh_command(String.t(), String.t(), String.t()) :: [String.t()] | {:error, term()}
  def ssh_command(_host, _db, _sql), do: not_implemented("F08.1 ssh_command")

  @spec fetch_rows(keyword()) :: {:ok, [row()]} | {:error, term()}
  def fetch_rows(_opts), do: not_implemented("F08.1 fetch_rows")

  @spec parse_rows(String.t()) :: {:ok, [row()]} | {:error, term()}
  def parse_rows(_jsonl), do: not_implemented("F08.1 parse_rows")

  @spec select([row()], %{String.t() => String.t()}, keyword()) :: [row()]
  def select(_rows, _overrides, _opts), do: not_implemented("F08.1 select")

  @spec build_manifest([row()], %{String.t() => String.t()}, keyword()) :: Manifest.t()
  def build_manifest(_rows, _overrides, _opts), do: not_implemented("F08.7 build_manifest")

  @spec run([String.t()], keyword()) ::
          {:ok, %{manifest_path: Path.t(), rows: non_neg_integer()}}
          | {:error, String.t() | term()}
  def run(_argv, _opts), do: not_implemented("F08.1 run")

  @spec parse_args([String.t()]) :: {:ok, config()} | {:error, String.t()}
  def parse_args(_argv), do: not_implemented("F08.1 parse_args")

  # RED skeleton: apply/3 keeps Elixir 1.20's type inference from typing the
  # body as none(), which would turn every test call site into a type warning.
  defp not_implemented(check),
    do: apply(:erlang, :error, [RuntimeError.exception("not implemented (SPEC_H #{check})")])
end
