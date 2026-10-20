defmodule Kerf.Eval.Harness.Run do
  @moduledoc """
  SPEC_H F09.8 / F09.6 — the harness run JSONL (plan §2.3).

  Line 1 is the `run_manifest` header, then one `answer` line per
  (item, question, order-permutation), and a final `run_end` line. Lines are
  plain string-keyed maps; `encode/1` writes them with the keys in the §2.3
  order so two runs are byte-comparable once `normalize/1` has dropped
  `latency_ms`, `started_at`, `finished_at` and `run_id`.
  """

  @type line :: %{String.t() => term()}

  @spec header(map()) :: line()
  def header(_fields), do: raise("not implemented (SPEC_H F09.8)")

  @spec answer_line(map()) :: line()
  def answer_line(_fields), do: raise("not implemented (SPEC_H F09.6)")

  @spec end_line(map()) :: line()
  def end_line(_fields), do: raise("not implemented (SPEC_H F09.8)")

  @spec encode(line()) :: String.t()
  def encode(_line), do: raise("not implemented (SPEC_H F09.8)")

  @spec write(Path.t(), line(), [line()]) :: :ok | {:error, term()}
  def write(_path, _header, _lines), do: raise("not implemented (SPEC_H F09.8)")

  @spec read(Path.t()) :: {:ok, {line(), [line()], line()}} | {:error, term()}
  def read(_path), do: raise("not implemented (SPEC_H F09.8)")

  @spec normalize(binary()) :: {:ok, binary()} | {:error, term()}
  def normalize(_jsonl), do: raise("not implemented (SPEC_H F09.8)")
end
