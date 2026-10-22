defmodule Kerf.Eval.PIIGuardTest do
  @moduledoc """
  SPEC_H F08.6 — the PII guard. Every address here is `example.invalid`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.{Item, PII, Synthetic}

  @moduletag :pii_guard
  @header "# sha256 of addresses in the decide set"
  @scan_roots ["docs/superpowers/specs", "docs/superpowers/plans", "test", "lib"]

  defp hex(address), do: :crypto.hash(:sha256, address) |> Base.encode16(case: :lower)

  defp tmp_dir! do
    dir =
      Path.join(System.tmp_dir!(), "kerf_pii_guard_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp with_from(%Manifest{} = manifest, index, from) do
    items =
      List.update_at(manifest.items, index, fn %Item{} = item ->
        %{item | state: %{item.state | from: from}}
      end)

    %{manifest | items: items}
  end

  defp real_items(manifest), do: Enum.filter(manifest.items, & &1.doc_id)

  describe "address_hashes/1" do
    test "hashes the 8 real items' addresses, leaving the pair items out" do
      manifest = Synthetic.build(n: 8, pairs: 2)
      hashes = PII.address_hashes(manifest)

      assert length(manifest.items) > 8
      assert length(hashes) == 8
      assert Enum.all?(hashes, &(&1 =~ ~r/\A[0-9a-f]{64}\z/))
      assert hashes == Enum.sort(hashes)
      assert hex("user1@example.invalid") in hashes
    end

    test "an upper-cased, space-padded from hashes like its clean form" do
      manifest = Synthetic.build(n: 8, pairs: 2)
      [first | _] = real_items(manifest)
      index = Enum.find_index(manifest.items, &(&1.id == first.id))
      messy = with_from(manifest, index, "  USER1@Example.INVALID \t")

      assert PII.address_hashes(messy) == PII.address_hashes(manifest)
    end

    test "duplicate addresses collapse to one hash" do
      manifest = Synthetic.build(n: 8, pairs: 2)
      [a, b | _] = real_items(manifest)
      index_b = Enum.find_index(manifest.items, &(&1.id == b.id))
      same = with_from(manifest, index_b, a.state.from)

      assert length(PII.address_hashes(same)) == 7
    end
  end

  describe "write_hashes/2 and read_hashes/1" do
    test "round-trip, sorted, under the header line" do
      path = Path.join(tmp_dir!(), "hashes.txt")
      hashes = Enum.map(["b@example.invalid", "a@example.invalid", "c@example.invalid"], &hex/1)

      assert :ok = PII.write_hashes(hashes, path)
      assert path |> File.read!() |> String.split("\n") |> hd() == @header
      assert {:ok, read} = PII.read_hashes(path)
      assert read == Enum.sort(hashes)
    end

    test "the hash file is mode 0o600 (S-35)" do
      path = Path.join(tmp_dir!(), "hashes.txt")

      assert :ok = PII.write_hashes([hex("a@example.invalid")], path)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "leaves no tmp file next to the target" do
      dir = tmp_dir!()
      assert :ok = PII.write_hashes([hex("a@example.invalid")], Path.join(dir, "hashes.txt"))
      assert File.ls!(dir) == ["hashes.txt"]
    end

    test "read_hashes skips # lines and blank lines" do
      path = Path.join(tmp_dir!(), "hashes.txt")
      h = hex("a@example.invalid")
      File.write!(path, "#{@header}\n\n# note\n#{h}\n\n")

      assert {:ok, [^h]} = PII.read_hashes(path)
    end

    test "a missing file is an error, not a raise" do
      assert {:error, _} = PII.read_hashes(Path.join(tmp_dir!(), "absent.txt"))
    end

    test "a line that is not 64 lowercase hex is {:line, n, _}" do
      dir = tmp_dir!()
      h = hex("a@example.invalid")

      for {name, bad} <- [
            short: "abc123",
            upper: String.upcase(h),
            junk: String.duplicate("z", 64)
          ] do
        path = Path.join(dir, "#{name}.txt")
        File.write!(path, "#{@header}\n#{h}\n#{bad}\n")
        assert {:error, {:line, 3, _}} = PII.read_hashes(path)
      end
    end
  end

  describe "scan/2" do
    test "reports the file and line of a listed address" do
      dir = tmp_dir!()
      file = Path.join(dir, "notes.md")
      File.write!(file, "first line\nwrite to person@example.invalid today\nlast\n")

      assert PII.scan([dir], [hex("person@example.invalid")]) == [{file, 2}]
    end

    test "the same address in another case is still reported" do
      dir = tmp_dir!()
      file = Path.join(dir, "notes.md")
      File.write!(file, "ok\nPerson@Example.INVALID\n")

      assert PII.scan([dir], [hex("person@example.invalid")]) == [{file, 2}]
    end

    test "an address that is not listed is not reported" do
      dir = tmp_dir!()
      File.write!(Path.join(dir, "notes.md"), "other@example.invalid\n")

      assert PII.scan([dir], [hex("person@example.invalid")]) == []
    end

    test "walks nested directories and finds several lines" do
      dir = tmp_dir!()
      File.mkdir_p!(Path.join(dir, "a/b"))
      deep = Path.join(dir, "a/b/deep.ex")
      top = Path.join(dir, "top.ex")
      File.write!(deep, "x\ny\n# person@example.invalid\n")
      File.write!(top, "person@example.invalid and person@example.invalid\n")

      assert Enum.sort(PII.scan([dir], [hex("person@example.invalid")])) ==
               Enum.sort([{deep, 3}, {top, 1}])
    end

    test "skips an unreadable file without raising" do
      dir = tmp_dir!()
      hit = Path.join(dir, "readable.md")
      locked = Path.join(dir, "locked.md")
      File.write!(hit, "person@example.invalid\n")
      File.write!(locked, "nothing to see\n")
      File.chmod!(locked, 0o000)
      on_exit(fn -> File.chmod(locked, 0o644) end)

      assert PII.scan([dir], [hex("person@example.invalid")]) == [{hit, 1}]
    end

    test "the result carries no address" do
      dir = tmp_dir!()
      File.write!(Path.join(dir, "notes.md"), "person@example.invalid\n")

      result = PII.scan([dir], [hex("person@example.invalid")])

      assert result != []

      refute Enum.any?(
               result,
               &(inspect(&1) =~ ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/)
             )
    end

    test "prints nothing" do
      dir = tmp_dir!()
      File.write!(Path.join(dir, "notes.md"), "person@example.invalid\n")

      assert capture_io(fn -> PII.scan([dir], [hex("person@example.invalid")]) end) == ""
    end
  end

  describe "the real guard (KERF_EVAL_HASHES)" do
    @tag :pii_real
    test "no committed file mentions an address in the decide set" do
      case System.get_env("KERF_EVAL_HASHES") do
        nil ->
          IO.puts("PII guard SKIPPED: KERF_EVAL_HASHES is not set")

        path ->
          assert {:ok, hashes} = PII.read_hashes(path)
          assert PII.scan(@scan_roots, hashes) == []
      end
    end

    test "with KERF_EVAL_HASHES unset the guard says so by name" do
      saved = System.get_env("KERF_EVAL_HASHES")
      on_exit(fn -> if saved, do: System.put_env("KERF_EVAL_HASHES", saved) end)
      System.delete_env("KERF_EVAL_HASHES")

      output = capture_io(fn -> run_real_guard() end)
      assert output =~ "KERF_EVAL_HASHES"
    end

    # The same body as the real test, so the notice path is exercised even
    # when the variable is set in the environment running the suite.
    defp run_real_guard do
      case System.get_env("KERF_EVAL_HASHES") do
        nil ->
          IO.puts("PII guard SKIPPED: KERF_EVAL_HASHES is not set")

        path ->
          {:ok, hashes} = PII.read_hashes(path)
          PII.scan(@scan_roots, hashes)
      end
    end
  end
end
