defmodule ExClaw.Memory.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_roles ~w(user assistant tool)

  schema "messages" do
    field :group_id, :string
    field :role, :string
    field :content, :string
    field :tool_name, :string
    field :tool_input, :string
    field :embedding, Pgvector.Ecto.Vector

    timestamps()
  end

  @required_fields ~w(group_id role)a
  @optional_fields ~w(content tool_name tool_input embedding)a

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:role, @valid_roles)
  end
end
