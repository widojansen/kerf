defmodule Kerf.Eval.Manifest.SyntheticTest do
  @moduledoc """
  SPEC_H F08 / F09.9 — Kerf.Eval.Manifest.Synthetic, plan §2.1 size semantics
  (ruling S-17) and the commit-review pins on 891d0ee: real = doc_id non-nil,
  b-items copy their a-item's language, language mix over counts.total.
  """
  use ExUnit.Case, async: true

  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.Synthetic

  @email ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/

  defp tmp_path! do
    dir =
      Path.join(System.tmp_dir!(), "kerf_eval_synth_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "manifest.json")
  end

  defp json!(m) do
    path = tmp_path!()
    assert :ok = Manifest.save(m, path)
    File.read!(path)
  end

  defp real(m), do: Enum.filter(m.items, &(not is_nil(&1.doc_id)))
  defp synthetic(m), do: Enum.filter(m.items, &is_nil(&1.doc_id))
  defp calibration(m), do: Enum.filter(m.items, &(&1.split == "calibration"))
  defp split_map(m), do: Map.new(m.items, &{&1.id, &1.split})

  describe "build/0 defaults (n: 220, pairs: 24, seed: 1, frozen: true)" do
    test "has 244 items: 220 real and 24 synthetic; counts agree" do
      m = Synthetic.build()
      assert length(m.items) == 244
      assert length(real(m)) == 220
      assert length(synthetic(m)) == 24
      assert m.counts.total == 244
      assert m.counts.pairs == 24
    end

    test "is frozen, validates and is ready for a run" do
      m = Synthetic.build()
      assert is_binary(m.frozen_at)
      assert :ok = Manifest.validate(m)
      assert :ok = Manifest.ready_for_run?(m)
    end

    test "holds out exactly 50 calibration items, none of them in a pair" do
      m = Synthetic.build()
      assert length(calibration(m)) == 50
      refute Enum.any?(calibration(m), &(not is_nil(&1.pair_id)))
      assert m.counts.held_out == 50
    end

    test "labels and tiers every item, before frozen_at" do
      m = Synthetic.build()

      for item <- m.items do
        assert is_map(item.labels)
        assert item.labelled_by == "wido"
        assert item.label_sources["category"] in ["adjudicated", "new"]
        assert item.tier in ["easy", "standard", "hard"]
        assert is_binary(item.tier_reason) and String.trim(item.tier_reason) != ""
        assert item.tiered_at <= m.frozen_at
      end
    end

    test "meets the freeze language mix over counts.total (NL ≥ 0.40, DE ≥ 0.25, EN ≥ 0.20)" do
      m = Synthetic.build()
      share = fn lang -> Map.get(m.counts.by_language, lang, 0) / m.counts.total end
      assert share.("nl") >= 0.40
      assert share.("de") >= 0.25
      assert share.("en") >= 0.20
    end
  end

  describe "contrastive pairs" do
    test "every pair is one real a-item plus one synthetic b-item edited from it" do
      m = Synthetic.build()
      groups = m.items |> Enum.reject(&is_nil(&1.pair_id)) |> Enum.group_by(& &1.pair_id)
      assert map_size(groups) == 24

      for {_pair_id, members} <- groups do
        assert length(members) == 2
        [b] = Enum.filter(members, &is_nil(&1.doc_id))
        [a] = Enum.reject(members, &is_nil(&1.doc_id))
        assert b.synthetic_of == a.id
        assert String.trim(a.pair_fact) != ""
      end
    end

    test "each b-item copies its a-item's language and flips exactly one label" do
      m = Synthetic.build()
      by_id = Map.new(m.items, &{&1.id, &1})

      for b <- synthetic(m) do
        a = Map.fetch!(by_id, b.synthetic_of)
        assert b.language == a.language
        differing = Enum.count(a.labels, fn {q, v} -> b.labels[q] != v end)
        assert differing == 1, "pair #{b.pair_id}: #{differing} labels differ"
      end
    end
  end

  describe "no PII" do
    test "every from address is user<n>@example.invalid" do
      for item <- Synthetic.build().items do
        assert item.state.from =~ ~r/\Auser\d+@example\.invalid\z/
      end
    end

    test "no address outside example.invalid anywhere in the JSON" do
      json = json!(Synthetic.build())
      addresses = @email |> Regex.scan(json) |> List.flatten()
      assert addresses != []
      assert Enum.all?(addresses, &String.ends_with?(&1, "@example.invalid"))
    end

    test "clients are client-a..client-c plus none" do
      m = Synthetic.build()
      assert m.question_set["client"]["options"] == ["client-a", "client-b", "client-c", "none"]

      assert Enum.all?(
               m.items,
               &(&1.labels["client"] in ["client-a", "client-b", "client-c", "none"])
             )
    end
  end

  describe "determinism" do
    test "same seed → identical JSON" do
      assert json!(Synthetic.build(seed: 3)) == json!(Synthetic.build(seed: 3))
    end

    test "different seed → different JSON" do
      refute json!(Synthetic.build(seed: 3)) == json!(Synthetic.build(seed: 4))
    end
  end

  describe "frozen: false" do
    test "returns the manifest unfrozen with no split assigned" do
      m = Synthetic.build(frozen: false)
      assert is_nil(m.frozen_at)
      assert Enum.all?(m.items, &is_nil(&1.split))
    end

    test "freeze/4 on it succeeds and yields build()'s split (both call assign_split(t, 50, seed))" do
      assert {:ok, f} =
               Manifest.freeze(Synthetic.build(frozen: false), 1, "2026-10-21T09:00:00Z", [])

      assert split_map(f) == split_map(Synthetic.build())
      assert length(calibration(f)) == 50
    end
  end

  describe "small sizes (S-17: n_cal = max(1, round(0.2 * eligible)) below 200 real)" do
    test "n: 8, pairs: 2 → 10 items, frozen, valid, ready, exactly 1 calibration item, not paired" do
      m = Synthetic.build(n: 8, pairs: 2)
      assert length(m.items) == 10
      assert length(real(m)) == 8
      assert is_binary(m.frozen_at)
      assert :ok = Manifest.validate(m)
      assert :ok = Manifest.ready_for_run?(m)
      assert [cal] = calibration(m)
      assert is_nil(cal.pair_id)
    end

    test "n: 12, pairs: 2 → 14 items" do
      assert length(Synthetic.build(n: 12, pairs: 2).items) == 14
    end

    test "n: 60, pairs: 6 → 66 items, 11 calibration" do
      m = Synthetic.build(n: 60, pairs: 6)
      assert length(m.items) == 66
      assert length(calibration(m)) == 11
      assert :ok = Manifest.validate(m)
    end
  end

  describe "source_id (D2, owner addition 2026-10-21)" do
    test "real items carry src-<n> mirroring doc-<n>; synthetic pair items carry nil" do
      m = Synthetic.build(n: 12, pairs: 2)

      for item <- real(m) do
        assert %{source_id: source_id} = item
        assert source_id == "src-" <> String.replace_prefix(item.doc_id, "doc-", "")
      end

      for item <- synthetic(m) do
        assert %{source_id: nil} = item
      end
    end
  end
end
