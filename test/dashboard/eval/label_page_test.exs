defmodule Kerf.Dashboard.Eval.LabelPageTest do
  @moduledoc """
  SPEC_H F08.1–F08.4, plan §2.8 and §6 D4 — the labelling page writes through
  the Manifest loader (put_* then save/2) and renders its violations verbatim.

  Fixtures come only from Kerf.Eval.Manifest.Synthetic (example.invalid data).
  Events are sent with `render_hook/3`, so the tests pin event names and
  parameter shapes; the page converts the form's strings to the loader's types.
  """
  use Kerf.ConnCase, async: false
  @moduletag :integration

  alias Kerf.Decide.OptionSet
  alias Kerf.Eval.Manifest
  alias Kerf.Eval.Manifest.{Item, Synthetic}

  @path "/dashboard/eval_label"

  # -- helpers ---------------------------------------------------------------

  defp categories, do: OptionSet.labels(OptionSet.triage_categories())

  # A 14-item manifest (12 real + 2 pair items) with every label removed.
  defp fixture(opts \\ []) do
    manifest = Synthetic.build(n: 12, pairs: 2, frozen: false)

    items =
      Enum.map(manifest.items, fn %Item{} = item ->
        %{item | labels: nil, label_sources: %{}, labelled_at: nil, labelled_by: nil}
      end)

    items =
      case Keyword.get(opts, :seed_category) do
        nil -> items
        category -> List.update_at(items, 0, &%{&1 | seed_category: category})
      end

    %{manifest | items: items}
  end

  defp use_manifest!(manifest) do
    dir =
      Path.join(System.tmp_dir!(), "kerf_label_page_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "manifest.json")
    :ok = Manifest.save(manifest, path)
    point_page_at!(path)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  defp point_page_at!(path) do
    previous = Application.get_env(:kerf, :eval_ui)
    Application.put_env(:kerf, :eval_ui, manifest_path: path)
    on_exit(fn -> Application.put_env(:kerf, :eval_ui, previous) end)
  end

  defp load!(path) do
    {:ok, manifest} = Manifest.load(path)
    manifest
  end

  defp item!(path, id), do: path |> load!() |> Map.fetch!(:items) |> Enum.find(&(&1.id == id))

  defp unpaired_ids(manifest) do
    for %Item{doc_id: doc_id, pair_id: nil, id: id} <- manifest.items, doc_id != nil, do: id
  end

  # The form posts every field as a string.
  defp form_labels(overrides \\ %{}) do
    Map.merge(
      %{
        "category" => hd(categories()),
        "needs_reply" => "true",
        "urgency" => "3",
        "deadline_present" => "false",
        "client" => "none"
      },
      overrides
    )
  end

  defp save_label(view, id, overrides \\ %{}),
    do: render_hook(view, "save_label", %{"item_id" => id, "labels" => form_labels(overrides)})

  # -- mount -----------------------------------------------------------------

  describe "mount" do
    test "lists every item of the manifest", %{conn: conn} do
      manifest = fixture()
      use_manifest!(manifest)

      {:ok, _view, html} = live(conn, @path)

      assert length(manifest.items) == 14
      for item <- manifest.items, do: assert(html =~ item.id)
    end

    test "shows the progress line from manifest.counts", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, html} = live(conn, @path)
      assert html =~ "0 of 14 labelled"

      html = save_label(view, hd(unpaired_ids(load!(path))))
      assert html =~ "1 of 14 labelled"
    end

    test "pre-fills the category control from seed_category", %{conn: conn} do
      seed = Enum.at(categories(), 2)
      use_manifest!(fixture(seed_category: seed))

      {:ok, _view, html} = live(conn, @path)

      selected =
        html
        |> Floki.parse_document!()
        |> Floki.find("#item-it-0001 select[name='labels[category]'] option[selected]")
        |> Floki.attribute("value")

      assert selected == [seed]
    end

    test "no manifest path renders a notice naming KERF_EVAL_MANIFEST", %{conn: conn} do
      point_page_at!(nil)

      {:ok, _view, html} = live(conn, @path)

      assert html =~ "KERF_EVAL_MANIFEST"
    end

    test "a missing manifest file renders its violation without crashing", %{conn: conn} do
      point_page_at!(
        Path.join(
          System.tmp_dir!(),
          "kerf_label_page_absent_#{System.unique_integer([:positive])}.json"
        )
      )

      {:ok, _view, html} = live(conn, @path)

      assert html =~ "file_unreadable"
    end

    test "an invalid manifest renders its violations without crashing", %{conn: conn} do
      path = use_manifest!(fixture())
      File.write!(path, "{ not json")

      {:ok, _view, html} = live(conn, @path)

      assert html =~ "invalid_json"
    end
  end

  # -- save_label (F08.2) ----------------------------------------------------

  describe "save_label" do
    test "a valid label updates the file, labelled_at and labelled_by", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, _html} = live(conn, @path)
      id = hd(unpaired_ids(load!(path)))

      save_label(view, id)

      item = item!(path, id)
      assert item.labels["category"] == hd(categories())
      assert item.labelled_by == "wido"
      assert {:ok, _, _} = DateTime.from_iso8601(item.labelled_at)
      assert load!(path).counts.labelled == 1
    end

    test "the form's strings land as the loader's types: urgency 3, booleans", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, _html} = live(conn, @path)
      id = hd(unpaired_ids(load!(path)))

      save_label(view, id, %{
        "urgency" => "3",
        "needs_reply" => "true",
        "deadline_present" => "false"
      })

      saved =
        path
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("items")
        |> Enum.find(&(&1["id"] == id))

      assert saved["labels"]["urgency"] === 3
      assert saved["labels"]["needs_reply"] === true
      assert saved["labels"]["deadline_present"] === false
    end

    test "an invalid label shows the violation and leaves the file byte-unchanged", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, _html} = live(conn, @path)
      id = hd(unpaired_ids(load!(path)))
      before = File.read!(path)

      for {overrides, code} <- [
            {%{"category" => "not-a-category"}, "label_not_in_options"},
            {%{"urgency" => "9"}, "urgency_out_of_range"},
            {%{"urgency" => "abc"}, "label_wrong_type"}
          ] do
        html = save_label(view, id, overrides)
        assert html =~ code
        assert File.read!(path) == before
      end
    end
  end

  # -- save_tier (F08.4) -----------------------------------------------------

  describe "save_tier" do
    test "stores tier, reason and tiered_at", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, _html} = live(conn, @path)
      id = hd(unpaired_ids(load!(path)))

      render_hook(view, "save_tier", %{
        "item_id" => id,
        "tier" => "hard",
        "tier_reason" => "two clients named"
      })

      item = item!(path, id)
      assert {item.tier, item.tier_reason} == {"hard", "two clients named"}
      assert {:ok, _, _} = DateTime.from_iso8601(item.tiered_at)
    end

    test "a tier without a reason is refused and the file is unchanged", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, _html} = live(conn, @path)
      id = hd(unpaired_ids(load!(path)))
      before = File.read!(path)

      html =
        render_hook(view, "save_tier", %{"item_id" => id, "tier" => "hard", "tier_reason" => "  "})

      assert html =~ "empty_tier_reason"
      assert File.read!(path) == before
    end
  end

  # -- save_language (F08.1) -------------------------------------------------

  describe "save_language" do
    test "stores the language with source \"human\"", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, _html} = live(conn, @path)
      id = hd(unpaired_ids(load!(path)))
      lang = if item!(path, id).language == "de", do: "en", else: "de"

      render_hook(view, "save_language", %{"item_id" => id, "language" => lang})

      item = item!(path, id)
      assert {item.language, item.language_source} == {lang, "human"}
    end

    test "an unknown language is refused and the file is unchanged", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, _html} = live(conn, @path)
      before = File.read!(path)

      html =
        render_hook(view, "save_language", %{
          "item_id" => hd(unpaired_ids(load!(path))),
          "language" => "fr"
        })

      assert html =~ "language_invalid"
      assert File.read!(path) == before
    end
  end

  # -- add_synthetic and mark_pair (F08.3) -----------------------------------

  describe "add_synthetic and mark_pair" do
    test "add_synthetic appends an item with doc_id nil and synthetic_of set", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, _html} = live(conn, @path)
      id = hd(unpaired_ids(load!(path)))

      render_hook(view, "add_synthetic", %{
        "of_item_id" => id,
        "state" => %{
          "from" => "synthetic@example.invalid",
          "from_name" => "Synthetic",
          "subject" => "Variant",
          "date" => "2026-10-01T08:00:00Z",
          "body" => "The same message, now with a deadline on Friday."
        }
      })

      manifest = load!(path)
      assert length(manifest.items) == 15
      added = List.last(manifest.items)
      assert {added.doc_id, added.synthetic_of} == {nil, id}
    end

    test "mark_pair on items with identical labels is refused", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, _html} = live(conn, @path)
      [a, b | _] = unpaired_ids(load!(path))
      save_label(view, a)
      save_label(view, b)
      before = File.read!(path)

      html =
        render_hook(view, "mark_pair", %{
          "pair_id" => "pair-x",
          "item_a" => a,
          "item_b" => b,
          "fact" => "nothing changed"
        })

      assert html =~ "pair_no_flip"
      assert File.read!(path) == before
    end

    test "mark_pair on items with differing labels links them", %{conn: conn} do
      path = use_manifest!(fixture())
      {:ok, view, _html} = live(conn, @path)
      [a, b | _] = unpaired_ids(load!(path))
      save_label(view, a)
      save_label(view, b, %{"needs_reply" => "false"})

      render_hook(view, "mark_pair", %{
        "pair_id" => "pair-x",
        "item_a" => a,
        "item_b" => b,
        "fact" => "reply no longer needed"
      })

      for id <- [a, b] do
        item = item!(path, id)
        assert {item.pair_id, item.pair_fact} == {"pair-x", "reply no longer needed"}
      end
    end
  end
end
