defmodule PhoenixKit.Modules.Publishing.PublishingPost do
  @moduledoc """
  Schema for publishing posts within a group.

  Posts are a minimal routing shell — they hold the URL identity (slug or
  date/time) and point to the currently live version via `active_version_uuid`.

  Each post belongs to a group and has versions with per-language content.
  Supports both slug-mode and timestamp-mode URL structures.

  ## Publishing

  A post is published when `active_version_uuid` is set (points to a published
  version). It is unpublished when `active_version_uuid` is nil.

  ## Soft Delete

  Posts use `trashed_at` (timestamp) for soft delete instead of a status field.
  `trashed_at` being nil means the post is active.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Modules.Publishing

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          group_uuid: UUIDv7.t(),
          slug: String.t(),
          mode: String.t(),
          post_date: Date.t() | nil,
          post_time: Time.t() | nil,
          active_version_uuid: UUIDv7.t() | nil,
          trashed_at: DateTime.t() | nil,
          created_by_uuid: UUIDv7.t() | nil,
          updated_by_uuid: UUIDv7.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_posts" do
    field :slug, :string
    field :mode, :string, default: "timestamp"
    field :post_date, :date
    field :post_time, :time
    field :trashed_at, :utc_datetime

    belongs_to :group, PhoenixKit.Modules.Publishing.PublishingGroup,
      foreign_key: :group_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :active_version, PhoenixKit.Modules.Publishing.PublishingVersion,
      foreign_key: :active_version_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :created_by, PhoenixKit.Users.Auth.User,
      foreign_key: :created_by_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :updated_by, PhoenixKit.Users.Auth.User,
      foreign_key: :updated_by_uuid,
      references: :uuid,
      type: UUIDv7

    has_many :versions, PhoenixKit.Modules.Publishing.PublishingVersion, foreign_key: :post_uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a publishing post.
  """
  def changeset(post, attrs) do
    post
    |> cast(attrs, [
      :group_uuid,
      :slug,
      :mode,
      :post_date,
      :post_time,
      :active_version_uuid,
      :trashed_at,
      :created_by_uuid,
      :updated_by_uuid
    ])
    |> validate_required([:group_uuid, :mode])
    |> validate_inclusion(:mode, Publishing.Constants.valid_modes())
    |> maybe_require_slug()
    |> validate_length(:slug, max: Publishing.Constants.max_slug_length())
    |> maybe_require_timestamp_fields()
    |> unique_constraint([:group_uuid, :slug], name: :idx_publishing_posts_group_slug)
    |> unique_constraint([:group_uuid, :post_date, :post_time],
      name: :idx_publishing_posts_group_date_time_unique,
      message: "a post already exists at this date and time"
    )
    |> foreign_key_constraint(:group_uuid, name: :fk_publishing_posts_group)
    |> foreign_key_constraint(:active_version_uuid, name: :fk_publishing_posts_active_version)
    |> foreign_key_constraint(:created_by_uuid, name: :fk_publishing_posts_created_by)
    |> foreign_key_constraint(:updated_by_uuid, name: :fk_publishing_posts_updated_by)
  end

  @doc "Check if post is published (has an active version)."
  def published?(%__MODULE__{active_version_uuid: uuid}) when not is_nil(uuid), do: true
  def published?(_), do: false

  @doc "Check if post is trashed."
  def trashed?(%__MODULE__{trashed_at: t}) when not is_nil(t), do: true
  def trashed?(_), do: false

  @doc "Check if post is a draft (not published and not trashed)."
  def draft?(%__MODULE__{} = post), do: not published?(post) and not trashed?(post)

  defp maybe_require_slug(changeset) do
    if get_field(changeset, :mode) == "slug" do
      validate_required(changeset, [:slug])
    else
      changeset
    end
  end

  defp maybe_require_timestamp_fields(changeset) do
    if get_field(changeset, :mode) == "timestamp" do
      validate_required(changeset, [:post_date, :post_time])
    else
      changeset
    end
  end
end
