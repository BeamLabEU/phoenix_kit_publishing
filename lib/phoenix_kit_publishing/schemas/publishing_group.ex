defmodule PhoenixKit.Modules.Publishing.PublishingGroup do
  @moduledoc """
  Schema for publishing groups (blog, faq, legal, etc.).

  Each group contains posts and defines the content mode (timestamp or slug).
  Extensible settings are stored in the `data` JSONB column.

  ## Data JSONB Keys

  - `type` - Group type: "blog", "faq", "legal", or "custom"
  - `item_singular` - Display name for single item (e.g., "Post", "Article")
  - `item_plural` - Display name for multiple items (e.g., "Posts", "Articles")
  - `description` - Group description
  - `icon` - Heroicon name for admin UI
  - `settings` - Group-specific settings map
  - `comments_enabled` - Whether comments are enabled for this group
  - `likes_enabled` - Whether likes are enabled for this group
  - `views_enabled` - Whether view tracking is enabled for this group
  - `featured_enabled` - Whether featured posts are surfaced on this group's
    public listing (default `true`). When `false`, posts flagged featured
    render inline like any other post — no hero band, no pinning.
  - `featured_layout` - How featured posts render: `"hero"` (a band above the
    grid) or `"card"` (a larger card within the grid). Default `"hero"`.
  - `scrollbar_style` - Native scrollbar styling for this group's public pages:
    `"default"` (untouched), `"branded"` (theme-colored), or `"thin"`. Never
    replaces native scroll — only recolors/resizes the real bar. Default `"default"`.
  - `scroll_progress_enabled` - Show a reading-progress bar on post pages (default `false`).
  - `scroll_headings_enabled` - Show a heading-anchor rail on post pages (default `false`).
  - `scroll_timeline_enabled` - Show a date-timeline rail on the listing (default `false`).
  - `scroll_timeline_granularity` - Timeline marker resolution: `"auto"` (fit to the
    posts' date span), `"year"`, `"month"`, or `"day"`. Default `"auto"`.
  - `listing_sort` - Public listing order: `"newest"` or `"oldest"` by effective
    publish date (post date for timestamp groups, published-at for slug groups).
    Default `"newest"`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Modules.Publishing

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t(),
          slug: String.t(),
          mode: String.t(),
          status: String.t(),
          position: integer(),
          data: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_groups" do
    field :name, :string
    field :slug, :string
    field :mode, :string, default: "timestamp"
    field :status, :string, default: "active"
    field :position, :integer, default: 0
    field :data, :map, default: %{}
    field :title_i18n, :map, default: %{}
    field :description_i18n, :map, default: %{}

    has_many :posts, PhoenixKit.Modules.Publishing.PublishingPost, foreign_key: :group_uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a publishing group.
  """
  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :slug, :mode, :status, :position, :data])
    |> validate_required([:name, :slug, :mode])
    |> validate_inclusion(:mode, Publishing.Constants.valid_modes())
    |> validate_inclusion(:status, Publishing.Constants.group_statuses())
    |> validate_length(:name, max: Publishing.Constants.max_group_name_length())
    |> validate_length(:slug, max: Publishing.Constants.max_group_slug_length())
    |> unique_constraint(:slug, name: :idx_publishing_groups_slug)
    |> maybe_generate_slug()
  end

  # Data JSONB accessors

  @doc "Returns the group type from data (blog/faq/legal/custom)."
  def get_type(%__MODULE__{data: data}), do: Map.get(data, "type", "blog")

  @doc "Returns the singular item name (e.g., 'Post')."
  def get_item_singular(%__MODULE__{data: data}), do: Map.get(data, "item_singular", "Post")

  @doc "Returns the plural item name (e.g., 'Posts')."
  def get_item_plural(%__MODULE__{data: data}), do: Map.get(data, "item_plural", "Posts")

  @doc "Returns the group description."
  def get_description(%__MODULE__{data: data}), do: Map.get(data, "description")

  @doc "Returns the group icon name."
  def get_icon(%__MODULE__{data: data}), do: Map.get(data, "icon")

  @doc "Returns whether comments are enabled for this group."
  def comments_enabled?(%__MODULE__{data: data}), do: Map.get(data, "comments_enabled", false)

  @doc "Returns whether likes are enabled for this group."
  def likes_enabled?(%__MODULE__{data: data}), do: Map.get(data, "likes_enabled", false)

  @doc "Returns whether view tracking is enabled for this group."
  def views_enabled?(%__MODULE__{data: data}), do: Map.get(data, "views_enabled", false)

  @doc "Returns whether featured posts are surfaced on this group's listing (default true)."
  def featured_enabled?(%__MODULE__{data: data}), do: Map.get(data, "featured_enabled", true)

  @doc ~S|Returns the featured-post layout for this group ("hero" or "card"; default "hero").|
  def featured_layout(%__MODULE__{data: data}),
    do: Map.get(data, "featured_layout", Publishing.Constants.default_featured_layout())

  @doc ~S|Returns the scrollbar style for this group's public pages ("default"/"branded"/"thin").|
  def scrollbar_style(%__MODULE__{data: data}),
    do: Map.get(data, "scrollbar_style", Publishing.Constants.default_scrollbar_style())

  @doc "Returns whether the reading-progress bar shows on this group's post pages (default false)."
  def scroll_progress_enabled?(%__MODULE__{data: data}),
    do: Map.get(data, "scroll_progress_enabled", false)

  @doc "Returns whether the heading-anchor rail shows on this group's post pages (default false)."
  def scroll_headings_enabled?(%__MODULE__{data: data}),
    do: Map.get(data, "scroll_headings_enabled", false)

  @doc "Returns whether the date-timeline rail shows on this group's listing page (default false)."
  def scroll_timeline_enabled?(%__MODULE__{data: data}),
    do: Map.get(data, "scroll_timeline_enabled", false)

  @doc ~S|Returns the date-timeline granularity ("auto"/"year"/"month"/"day"; default "auto").|
  def scroll_timeline_granularity(%__MODULE__{data: data}),
    do:
      Map.get(
        data,
        "scroll_timeline_granularity",
        Publishing.Constants.default_timeline_granularity()
      )

  @doc ~S|Returns the public-listing sort order for this group ("newest"/"oldest"; default "newest").|
  def listing_sort(%__MODULE__{data: data}),
    do: Map.get(data, "listing_sort", Publishing.Constants.default_listing_sort())

  defp maybe_generate_slug(changeset) do
    # Only auto-generate slug for new records (no existing slug).
    # On updates, Ecto won't register the slug as a "change" if it's the same,
    # and we must NOT regenerate from the (potentially changed) name.
    existing_slug = get_field(changeset, :slug)

    case get_change(changeset, :slug) do
      nil when is_nil(existing_slug) or existing_slug == "" ->
        name = get_field(changeset, :name)

        if name do
          slug =
            name
            |> String.downcase()
            |> String.replace(~r/[^\w\s-]/, "")
            |> String.replace(~r/\s+/, "-")
            |> String.trim("-")

          put_change(changeset, :slug, slug)
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
