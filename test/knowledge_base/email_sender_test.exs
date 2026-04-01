defmodule ExClaw.KnowledgeBase.EmailSenderTest do
  use ExClaw.DataCase

  alias ExClaw.KnowledgeBase.EmailSender

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

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
