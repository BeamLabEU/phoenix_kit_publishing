defmodule PhoenixKitPublishing.Test.ApiChangesetSchema do
  @moduledoc false
  # A schema with a length rule and nested embeds, for the changeset-error tests of the API helpers.

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :name, :string

    embeds_one :child, Child, primary_key: false, on_replace: :update do
      field :label, :string
    end

    embeds_many :items, Item, primary_key: false, on_replace: :delete do
      field :label, :string
    end
  end

  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:name])
    |> validate_length(:name, max: 3)
    |> cast_embed(:child, with: &nested/2)
    |> cast_embed(:items, with: &nested/2)
  end

  defp nested(struct, params) do
    struct |> cast(params, [:label]) |> validate_required([:label])
  end
end
