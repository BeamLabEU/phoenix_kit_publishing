defmodule PhoenixKit.Modules.Publishing.PublishingPostCategory do
  @moduledoc """
  Post↔category assignment row (core migration **V159**,
  `phoenix_kit_publishing_post_categories`). Post-level, WordPress
  semantics — a post's categories apply to every version. Composite
  primary key; both FKs cascade in the DB.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key false
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          post_uuid: Ecto.UUID.t() | nil,
          category_uuid: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_post_categories" do
    belongs_to :post, PhoenixKit.Modules.Publishing.PublishingPost,
      foreign_key: :post_uuid,
      references: :uuid,
      type: UUIDv7,
      primary_key: true

    belongs_to :category, PhoenixKit.Modules.Publishing.PublishingCategory,
      foreign_key: :category_uuid,
      references: :uuid,
      type: UUIDv7,
      primary_key: true

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
