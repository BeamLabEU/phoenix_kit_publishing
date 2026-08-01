defmodule PhoenixKit.Modules.Publishing.PublishingVersion do
  @moduledoc """
  Schema for publishing post versions.

  Versions are the source of truth for published state and metadata.
  Each post can have multiple versions (v1, v2, etc.). Each version contains
  per-language content rows in `PublishingContent`.

  ## Status Flow

  - `draft` - Version is being edited
  - `published` - Version is live (post.active_version_uuid points here)
  - `archived` - Version replaced by newer one

  ## Data JSONB Keys

  ### Version metadata (defaults for all languages)
  - `featured_image_uuid` - Featured image reference (media UUID)
  - `tags` - List of tag strings
  - `description` - SEO meta description
  - `allow_version_access` - Whether older versions are publicly accessible
  - `featured` - Whether this post is featured (pinned to the top of the group
    listing and rendered larger). Per-group display is gated by the group's
    own `featured_enabled`/`featured_layout` config.

  ### Version history
  - `created_from` - Source version number this was created from
  - `notes` - Version notes/changelog
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Modules.Publishing

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          post_uuid: UUIDv7.t(),
          version_number: integer(),
          status: String.t(),
          published_at: DateTime.t() | nil,
          created_by_uuid: UUIDv7.t() | nil,
          data: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_versions" do
    field :version_number, :integer
    field :status, :string, default: "draft"
    field :published_at, :utc_datetime
    field :data, :map, default: %{}

    belongs_to :post, PhoenixKit.Modules.Publishing.PublishingPost,
      foreign_key: :post_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :created_by, PhoenixKit.Users.Auth.User,
      foreign_key: :created_by_uuid,
      references: :uuid,
      type: UUIDv7

    has_many :contents, PhoenixKit.Modules.Publishing.PublishingContent,
      foreign_key: :version_uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a publishing version.
  """
  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :post_uuid,
      :version_number,
      :status,
      :published_at,
      :created_by_uuid,
      :data
    ])
    |> validate_required([:post_uuid, :version_number, :status])
    |> validate_inclusion(:status, Publishing.Constants.content_statuses())
    |> validate_number(:version_number, greater_than: 0)
    |> unique_constraint([:post_uuid, :version_number],
      name: :idx_publishing_versions_post_number
    )
    |> foreign_key_constraint(:post_uuid, name: :fk_publishing_versions_post)
    |> foreign_key_constraint(:created_by_uuid, name: :fk_publishing_versions_created_by)
  end

  # ── Data JSONB accessors (version-level defaults) ──────────────

  @doc "Returns the featured image UUID."
  def get_featured_image_uuid(%__MODULE__{data: data}),
    do: Map.get(data, "featured_image_uuid")

  @doc """
  Returns the post's audio-version file uuid (nil when none).

  A cleared audio picker submits `""`, and older rows still carry that
  blank. Blank normalizes to `nil` HERE so every reader agrees: an empty
  string is truthy in Elixir, so a template gating on the raw value
  rendered a player whose src had an empty uuid segment
  (`/file//original/<token>` — a dead request).
  """
  def get_audio_uuid(%__MODULE__{data: data}) do
    case Map.get(data, "audio_uuid") do
      uuid when is_binary(uuid) -> if String.trim(uuid) == "", do: nil, else: uuid
      _ -> nil
    end
  end

  @doc "Returns the post tags."
  def get_tags(%__MODULE__{data: data}), do: Map.get(data, "tags", [])

  @doc """
  Returns the categories filed against this version.

  Version-level, like everything else here. A post's subject can genuinely
  change between versions — a release note that grows into a guide — and the
  old version keeps the filing it was published under, which is what someone
  reading `?v=2` should see. A new version inherits the whole `data` map from
  the one it was created from, so this carries forward by default and only
  differs where somebody changed it.
  """
  def get_category_uuids(%__MODULE__{data: data}) do
    case Map.get(data, "category_uuids") do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  @doc "Returns the SEO description."
  def get_description(%__MODULE__{data: data}), do: Map.get(data, "description")

  @doc "Returns whether older versions are publicly accessible."
  def get_allow_version_access(%__MODULE__{data: data}),
    do: Map.get(data, "allow_version_access", false)

  @doc "Returns whether this post is featured (pinned + shown larger on the group listing)."
  def get_featured(%__MODULE__{data: data}), do: Map.get(data, "featured", false)

  # ── Version history accessors ──────────────────────────────────

  @doc "Returns the source version number this was created from."
  def get_created_from(%__MODULE__{data: data}), do: Map.get(data, "created_from")

  @doc "Returns version notes."
  def get_notes(%__MODULE__{data: data}), do: Map.get(data, "notes")
end
