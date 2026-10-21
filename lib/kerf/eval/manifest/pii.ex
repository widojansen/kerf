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
  @address ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
  @hash ~r/\A[0-9a-f]{64}\z/
  # A NUL byte in the first chunk marks a file as binary and not worth scanning.
  @binary_probe 8192

  @doc "The header written as the first line of a hash file."
  @spec header() :: String.t()
  def header, do: @header

  @doc """
  Lowercase hex SHA-256 of each downcased, trimmed `state.from` of every real
  item (`doc_id` non-nil), deduplicated and sorted.
  """
  @spec address_hashes(Manifest.t()) :: [String.t()]
  def address_hashes(%Manifest{items: items}) do
    items
    |> Enum.filter(& &1.doc_id)
    |> Enum.map(&(&1.state && &1.state.from))
    |> hash_addresses()
  end

  @doc """
  The sorted, deduplicated hashes of `addresses`; entries that are not binaries
  are dropped.
  """
  @spec hash_addresses([String.t() | nil]) :: [String.t()]
  def hash_addresses(addresses) do
    addresses
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&hash/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Writes `hashes` sorted, one per line, under the header, atomically (tmp file
  next to the target, then rename).
  """
  @spec write_hashes([String.t()], Path.t()) :: :ok | {:error, term()}
  def write_hashes(hashes, path) when is_list(hashes) and is_binary(path) do
    lines = hashes |> Enum.sort() |> Enum.map(&(&1 <> "\n"))
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with {:write, :ok} <- {:write, File.write(tmp, [@header, "\n" | lines])},
         {:rename, :ok} <- {:rename, File.rename(tmp, path)} do
      :ok
    else
      {step, {:error, reason}} ->
        _ = File.rm(tmp)
        {:error, {:write_failed, step, reason}}
    end
  end

  @doc """
  Reads a hash file. `#` lines and blank lines are skipped; a line that is not
  64 lowercase hex characters is `{:error, {:line, n, _}}`. Never raises.
  """
  @spec read_hashes(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def read_hashes(path) when is_binary(path) do
    with {:ok, text} <- File.read(path) do
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {raw, n}, {:ok, acc} ->
        line = String.trim(raw)

        cond do
          line == "" or String.starts_with?(line, "#") -> {:cont, {:ok, acc}}
          Regex.match?(@hash, line) -> {:cont, {:ok, [line | acc]}}
          true -> {:halt, {:error, {:line, n, :not_a_sha256_hex}}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, acc |> Enum.uniq() |> Enum.sort()}
        error -> error
      end
    end
  end

  @doc """
  Walks every regular file under each of `paths` (symlinks are not followed;
  unreadable files and files with a NUL byte in their first #{@binary_probe}
  bytes are skipped) and returns the `{file, line_no}` of each line holding an
  address-shaped token whose normalised hash is in `hashes`. Pure: it prints
  nothing and never reports the address itself.
  """
  @spec scan([Path.t()], [String.t()]) :: [{Path.t(), pos_integer()}]
  def scan(paths, hashes) when is_list(paths) and is_list(hashes) do
    listed = MapSet.new(hashes)

    paths
    |> Enum.flat_map(&files/1)
    |> Enum.flat_map(&scan_file(&1, listed))
  end

  defp files(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> [path]
      {:ok, %File.Stat{type: :directory}} -> list_dir(path)
      _ -> []
    end
  end

  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.sort() |> Enum.flat_map(&files(Path.join(dir, &1)))
      {:error, _} -> []
    end
  end

  defp scan_file(file, listed) do
    case File.read(file) do
      {:ok, bytes} ->
        if binary?(bytes), do: [], else: hits(file, bytes, listed)

      {:error, _} ->
        []
    end
  end

  defp binary?(bytes) do
    probe = binary_part(bytes, 0, min(byte_size(bytes), @binary_probe))
    :binary.match(probe, <<0>>) != :nomatch
  end

  defp hits(file, bytes, listed) do
    bytes
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} ->
      @address
      |> Regex.scan(line)
      |> Enum.any?(fn [token] -> MapSet.member?(listed, hash(token)) end)
    end)
    |> Enum.map(fn {_, n} -> {file, n} end)
  end

  defp hash(address) do
    address
    |> String.trim()
    |> String.downcase()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
