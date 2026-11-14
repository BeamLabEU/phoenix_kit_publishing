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
  - `custom_fields` - A host's own per-post fields, a map of string keys
    (`[a-z0-9_]`, at most #{40} characters) to string values (at most 2 000
    characters), at most 30 of them: "package" and "version" on a release
    post, say. Written through `normalize_custom_fields/1`; read with
    `get_custom_fields/1` and on the post map as `metadata.custom_fields`.
  - `sitemap_exclude` - Leave this post out of the site's sitemap (core's
    Sitemap source reads it as `metadata.sitemap_exclude` on the post map)
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

  # `phoenix_kit_publishing_versions` `character varying` column widths,
  # interpolated into `PhoenixKitPublishing.Migrations`' V1 DDL — the single
  # source of truth so the migration chain and core's `ExpectedSchema`
  # manifest can never independently disagree on a number.
  @column_widths %{status: 20}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          post_uuid: UUIDv7.t() | nil,
          version_number: pos_integer() | nil,
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
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
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

  @doc """
  `character varying` column widths for `phoenix_kit_publishing_versions`,
  keyed by field name.

  The single source of truth `PhoenixKitPublishing.Migrations`' V1 DDL
  interpolates, so the migration chain and core's `ExpectedSchema` manifest
  can never independently disagree on a number.
  """
  @spec column_widths() :: %{atom() => pos_integer()}
  def column_widths, do: @column_widths

  # ── Data JSONB accessors (version-level defaults) ──────────────

  @doc "Returns the featured image UUID."
  @spec get_featured_image_uuid(t()) :: String.t() | nil
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
  @spec get_audio_uuid(t()) :: String.t() | nil
  def get_audio_uuid(%__MODULE__{data: data}) do
    case Map.get(data, "audio_uuid") do
      uuid when is_binary(uuid) -> if String.trim(uuid) == "", do: nil, else: uuid
      _ -> nil
    end
  end

  @doc "Returns the post tags."
  @spec get_tags(t()) :: [String.t()]
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
  @spec get_category_uuids(t()) :: [String.t()]
  def get_category_uuids(%__MODULE__{data: data}) do
    case Map.get(data, "category_uuids") do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  @doc "Returns the SEO description."
  @spec get_description(t()) :: String.t() | nil
  def get_description(%__MODULE__{data: data}), do: Map.get(data, "description")

  @doc "Returns whether older versions are publicly accessible."
  @spec get_allow_version_access(t()) :: boolean()
  def get_allow_version_access(%__MODULE__{data: data}),
    do: Map.get(data, "allow_version_access", false)

  @max_custom_fields 30
  @max_custom_key 40
  @max_custom_value 2_000

  @doc "The post's custom fields (a map, `%{}` when it has none)."
  @spec get_custom_fields(t()) :: %{optional(String.t()) => String.t()}
  def get_custom_fields(%__MODULE__{data: data}),
    do: normalize_custom_fields(Map.get(data, "custom_fields"))

  @doc """
  Custom fields as stored: from a map, or from a list of `%{"key", "value"}`
  rows (the editor's shape) where a later row wins. Keys are trimmed,
  lowercased and reduced to `[a-z0-9_]` (other characters become `_`); a
  blank key or value is dropped; a value is cut at #{@max_custom_value}
  characters; at most #{@max_custom_fields} fields are kept, by key order.
  Anything else is `%{}`.
  """
  @spec normalize_custom_fields(term()) :: %{optional(String.t()) => String.t()}
  def normalize_custom_fields(fields) when is_map(fields) and not is_struct(fields),
    do: fields |> Enum.to_list() |> pairs_to_fields()

  def normalize_custom_fields(rows) when is_list(rows) do
    rows
    |> Enum.flat_map(fn
      %{"key" => key, "value" => value} -> [{key, value}]
      %{key: key, value: value} -> [{key, value}]
      {key, value} -> [{key, value}]
      _ -> []
    end)
    |> pairs_to_fields()
  end

  def normalize_custom_fields(_fields), do: %{}

  @doc "A custom field key as stored, or nil when nothing of it is left."
  @spec custom_field_key(term()) :: String.t() | nil
  def custom_field_key(key) when is_binary(key) or is_atom(key) do
    key =
      key
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")
      |> String.slice(0, @max_custom_key)

    if key == "", do: nil, else: key
  end

  def custom_field_key(_key), do: nil

  defp pairs_to_fields(pairs) do
    pairs
    |> Enum.flat_map(fn {key, value} ->
      with key when is_binary(key) <- custom_field_key(key),
           value when is_binary(value) <- custom_field_value(value) do
        [{key, value}]
      else
        _ -> []
      end
    end)
    |> Map.new()
    |> Enum.sort()
    |> Enum.take(@max_custom_fields)
    |> Map.new()
  end

  # A NUL byte or invalid UTF-8 would make Postgres refuse the JSONB.
  defp custom_field_value(value) when is_binary(value) do
    value = if String.valid?(value), do: String.replace(value, <<0>>, ""), else: ""

    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_custom_value)
    end
  end

  defp custom_field_value(value) when is_number(value) or is_boolean(value),
    do: custom_field_value(to_string(value))

  defp custom_field_value(_value), do: nil

  @doc "Returns whether this post is left out of the sitemap."
  @spec get_sitemap_exclude(t()) :: boolean()
  def get_sitemap_exclude(%__MODULE__{data: data}),
    do: Map.get(data, "sitemap_exclude", false)

  @doc "Returns whether this post is featured (pinned + shown larger on the group listing)."
  @spec get_featured(t()) :: boolean()
  def get_featured(%__MODULE__{data: data}), do: Map.get(data, "featured", false)

  # ── Version history accessors ──────────────────────────────────

  @doc "Returns the source version number this was created from."
  @spec get_created_from(t()) :: pos_integer() | nil
  def get_created_from(%__MODULE__{data: data}), do: Map.get(data, "created_from")

  @doc "Returns version notes."
  @spec get_notes(t()) :: String.t() | nil
  def get_notes(%__MODULE__{data: data}), do: Map.get(data, "notes")
end
