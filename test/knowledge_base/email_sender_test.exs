defmodule Kerf.KnowledgeBase.EmailSenderTest do
  use Kerf.DataCase

  alias Kerf.KnowledgeBase.EmailSender

  describe "changeset/2" do
    test "valid with email" do
      cs = EmailSender.changeset(%EmailSender{}, %{email: "alice@example.com"})
      assert cs.valid?
    end

    test "requires email" do
      cs = EmailSender.changeset(%EmailSender{}, %{})
      refute cs.valid?
      assert %{email: ["can't be blank"]} = errors_on(cs)
    end

    test "accepts all optional fields" do
      cs =
        EmailSender.changeset(%EmailSender{}, %{
          email: "bob@acme.com",
          name: "Bob",
          domain: "acme.com",
          priority_score: 0.8,
          is_priority: true,
          total_emails: 5,
          total_interactions: 2,
          last_email_at: DateTime.utc_now()
        })

      assert cs.valid?
    end
  end

  describe "insert" do
    test "inserts with defaults" do
      {:ok, sender} =
        Repo.insert(EmailSender.changeset(%EmailSender{}, %{email: "test@example.com"}))

      assert sender.priority_score == 0.0
      assert sender.is_priority == false
      assert sender.total_emails == 0
      assert sender.total_interactions == 0
    end

    test "enforces unique email" do
      {:ok, _} =
        Repo.insert(EmailSender.changeset(%EmailSender{}, %{email: "dup@example.com"}))

      assert {:error, cs} =
               Repo.insert(EmailSender.changeset(%EmailSender{}, %{email: "dup@example.com"}))

      assert %{email: ["has already been taken"]} = errors_on(cs)
    end

    test "upserts on email conflict" do
      {:ok, _} =
        Repo.insert(
          EmailSender.changeset(%EmailSender{}, %{
            email: "upsert@example.com",
            name: "Old Name",
            total_emails: 1
          })
        )

      {:ok, updated} =
        %EmailSender{}
        |> EmailSender.changeset(%{
          email: "upsert@example.com",
          name: "New Name",
          total_emails: 2
        })
        |> Repo.insert(
          on_conflict: {:replace, [:name, :total_emails, :updated_at]},
          conflict_target: [:email]
        )

      assert updated.name == "New Name"
      assert updated.total_emails == 2
    end
  end

  describe "classification fields" do
    test "accepts classification_override, priority_override, match_pattern" do
      cs =
        EmailSender.changeset(%EmailSender{}, %{
          email: "rule@example.com",
          classification_override: "newsletter",
          priority_override: 1,
          match_pattern: "example.com"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :classification_override) == "newsletter"
      assert Ecto.Changeset.get_change(cs, :priority_override) == 1
      assert Ecto.Changeset.get_change(cs, :match_pattern) == "example.com"
    end

    test "persists classification fields to database" do
      {:ok, sender} =
        %EmailSender{}
        |> EmailSender.changeset(%{
          email: "persist-cls@example.com",
          classification_override: "business",
          priority_override: 5,
          match_pattern: "fource"
        })
        |> Repo.insert()

      reloaded = Repo.get!(EmailSender, sender.id)
      assert reloaded.classification_override == "business"
      assert reloaded.priority_override == 5
      assert reloaded.match_pattern == "fource"
    end

    test "classification fields default to nil" do
      {:ok, sender} =
        Repo.insert(EmailSender.changeset(%EmailSender{}, %{email: "noclass@example.com"}))

      assert sender.classification_override == nil
      assert sender.priority_override == nil
      assert sender.match_pattern == nil
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
