defmodule ExClaw.KnowledgeBase.DocumentTest do
  use ExClaw.DataCase

  alias ExClaw.KnowledgeBase.Document

  describe "changeset/2" do
    test "valid with required fields" do
      cs = Document.changeset(%Document{}, %{source_type: "email", source_id: "msg_123"})
      assert cs.valid?
    end

    test "requires source_type" do
      cs = Document.changeset(%Document{}, %{source_id: "msg_123"})
      refute cs.valid?
      assert %{source_type: ["can't be blank"]} = errors_on(cs)
    end

    test "validates source_type inclusion" do
      cs = Document.changeset(%Document{}, %{source_type: "invalid", source_id: "x"})
      refute cs.valid?
      assert %{source_type: [_]} = errors_on(cs)
    end

    test "accepts all valid source types" do
      for type <- ~w(email pdf youtube rss book podcast) do
        cs = Document.changeset(%Document{}, %{source_type: type, source_id: "x_#{type}"})
        assert cs.valid?, "expected #{type} to be valid"
      end
    end
  end

  describe "insert" do
    test "inserts a document with metadata" do
      attrs = %{
        source_type: "email",
        source_id: "msg_abc",
        source_metadata: %{"sender" => "test@example.com", "subject" => "Hello"},
        title: "Hello",
        raw_text: "Hello world",
        content_hash: :crypto.hash(:sha256, "Hello world") |> Base.encode16(case: :lower)
      }

      assert {:ok, doc} = Repo.insert(Document.changeset(%Document{}, attrs))
      assert doc.id != nil
      assert doc.source_metadata["sender"] == "test@example.com"
    end

    test "enforces unique source_type + source_id" do
      attrs = %{source_type: "email", source_id: "msg_dup"}
      {:ok, _} = Repo.insert(Document.changeset(%Document{}, attrs))

      assert {:error, cs} = Repo.insert(Document.changeset(%Document{}, attrs))
      assert %{source_type: ["has already been taken"]} = errors_on(cs)
    end

    test "allows nil source_id (e.g., uploaded files)" do
      attrs1 = %{source_type: "pdf", title: "doc1.pdf"}
      attrs2 = %{source_type: "pdf", title: "doc2.pdf"}
      assert {:ok, _} = Repo.insert(Document.changeset(%Document{}, attrs1))
      assert {:ok, _} = Repo.insert(Document.changeset(%Document{}, attrs2))
    end
  end

  describe "query by metadata" do
    test "queries JSONB source_metadata" do
      attrs = %{
        source_type: "email",
        source_id: "msg_q1",
        source_metadata: %{"sender" => "alice@example.com", "labels" => ["INBOX", "IMPORTANT"]}
      }

      {:ok, _} = Repo.insert(Document.changeset(%Document{}, attrs))

      import Ecto.Query

      results =
        from(d in Document,
          where: fragment("? ->> 'sender' = ?", d.source_metadata, "alice@example.com")
        )
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).source_id == "msg_q1"
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
