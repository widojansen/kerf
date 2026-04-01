defmodule ExClaw.KnowledgeBase.InterestTest do
  use ExClaw.DataCase

  alias ExClaw.KnowledgeBase.Interest

  describe "changeset/2" do
    test "valid with topic" do
      cs = Interest.changeset(%Interest{}, %{topic: "AI/ML"})
      assert cs.valid?
    end

    test "requires topic" do
      cs = Interest.changeset(%Interest{}, %{})
      refute cs.valid?
      assert %{topic: ["can't be blank"]} = errors_on(cs)
    end

    test "accepts keywords, weight, enabled" do
      cs =
        Interest.changeset(%Interest{}, %{
          topic: "Elixir",
          keywords: ["elixir", "OTP", "phoenix"],
          weight: 1.5,
          enabled: true
        })

      assert cs.valid?
    end
  end

  describe "insert" do
    test "inserts with defaults" do
      {:ok, interest} = Repo.insert(Interest.changeset(%Interest{}, %{topic: "Rust"}))
      assert interest.weight == 1.0
      assert interest.enabled == true
      assert interest.keywords == []
    end

    test "enforces unique topic" do
      {:ok, _} = Repo.insert(Interest.changeset(%Interest{}, %{topic: "Security"}))

      assert {:error, cs} = Repo.insert(Interest.changeset(%Interest{}, %{topic: "Security"}))
      assert %{topic: ["has already been taken"]} = errors_on(cs)
    end

    test "stores embedding vector" do
      embedding = Pgvector.new(List.duplicate(0.5, 768))

      {:ok, interest} =
        Repo.insert(
          Interest.changeset(%Interest{}, %{topic: "AI/ML", embedding: embedding})
        )

      reloaded = Repo.get!(Interest, interest.id)
      assert Pgvector.to_list(reloaded.embedding) |> length() == 768
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
