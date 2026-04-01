defmodule ExClaw.KnowledgeBase.EmailSender do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "email_senders" do
    field :email, :string
    field :name, :string
    field :domain, :string
    field :priority_score, :float, default: 0.0
    field :is_priority, :boolean, default: false
    field :total_emails, :integer, default: 0
    field :total_interactions, :integer, default: 0
    field :last_email_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(sender, attrs) do
    sender
    |> cast(attrs, [
      :email, :name, :domain, :priority_score, :is_priority,
      :total_emails, :total_interactions, :last_email_at
    ])
    |> validate_required([:email])
    |> unique_constraint(:email)
  end
end
