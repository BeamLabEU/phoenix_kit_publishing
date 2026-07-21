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
  - `newest_enabled` - Whether the most recent post is pulled out of the grid
    into its own "Latest" band under any featured posts and shown larger
    (default `false`).
  - `newest_layout` - How the latest post renders: `"hero"` (a band above the
    grid) or `"card"` (a larger card within the grid). Default `"hero"`.
  - `featured_style` - The paint of featured-band cards, orthogonal to the
    layout: `"classic"`, `"cover"`, `"cover_panel"`, `"minimal"`, or `"top"`.
    Default `"classic"`.
  - `newest_style` - Same vocabulary for the Latest band. Default `"classic"`.
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
  - `show_breadcrumbs` - Show the breadcrumb trail on this group's public listing
    and post pages (default `false`).
  - `post_date_position` - Where a post's date renders relative to the title on the
    post page: `"above"`, `"below"`, or `"hidden"`. Default `"below"`.
  - `post_width` - Post-page content column width: `"narrow"`, `"normal"`, or
    `"wide"`. Default `"normal"`.
  - `show_featured_image` - Show the post's featured image at the top of the post
    page (default `false`).
  - `show_reading_time` - Show an estimated reading time on the post page (default `false`).
  - `show_tags` - Show the post's tags on the post page (default `false`).
  - `show_post_count` - Show the total post count under the title on the group's
    public listing (default `false`).
  - `show_top_back_link` - Show the subtle "Back to <group>" link at the top of
    the post page, mirroring the footer button (default `true`).
  - `listing_image_links` - Make the post-card images on the public listing
    click through to the post, same as the title (default `true`).
  - `listing_animations` - Hover animations on listing cards (a subtle lift +
    shadow cue that the card is clickable; default `true`). Motion-reduce
    users never see the lift regardless.
  - `name_i18n` - Per-language overrides for the group's display name, keyed by
    language code (e.g. `%{"et" => "Blogi"}`). The primary-language name lives in
    the `name` column; secondary languages fall back to it when absent. The slug
    is intentionally NOT translated — it stays a single canonical URL segment.
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

  @doc "Returns whether the latest post is surfaced in its own listing band (default false)."
  def newest_enabled?(%__MODULE__{data: data}), do: Map.get(data, "newest_enabled", false)

  @doc ~S|Returns the latest-post layout for this group ("hero" or "card"; default "hero").|
  def newest_layout(%__MODULE__{data: data}),
    do: Map.get(data, "newest_layout", Publishing.Constants.default_newest_layout())

  @doc ~S|Returns the featured-band style ("classic"/"cover"/"cover_panel"/"minimal"/"top"; default "classic").|
  def featured_style(%__MODULE__{data: data}),
    do: Map.get(data, "featured_style", Publishing.Constants.default_band_style())

  @doc ~S|Returns the Latest-band style (same vocabulary as featured_style; default "classic").|
  def newest_style(%__MODULE__{data: data}),
    do: Map.get(data, "newest_style", Publishing.Constants.default_band_style())

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

  @doc "Returns whether the breadcrumb trail shows on this group's public pages (default false)."
  def show_breadcrumbs?(%__MODULE__{data: data}), do: Map.get(data, "show_breadcrumbs", false)

  @doc ~S|Returns where a post's date renders relative to the title ("above"/"below"/"hidden"; default "below").|
  def post_date_position(%__MODULE__{data: data}),
    do: Map.get(data, "post_date_position", Publishing.Constants.default_post_date_position())

  @doc ~S|Returns the post-page content width ("narrow"/"normal"/"wide"; default "normal").|
  def post_width(%__MODULE__{data: data}),
    do: Map.get(data, "post_width", Publishing.Constants.default_post_width())

  @doc "Returns whether a post's featured image shows at the top of the post page (default false)."
  def show_featured_image?(%__MODULE__{data: data}),
    do: Map.get(data, "show_featured_image", false)

  @doc "Returns whether an estimated reading time shows on the post page (default false)."
  def show_reading_time?(%__MODULE__{data: data}), do: Map.get(data, "show_reading_time", false)

  @doc "Returns whether a post's tags show on the post page (default false)."
  def show_tags?(%__MODULE__{data: data}), do: Map.get(data, "show_tags", false)

  @doc "Returns whether the post count shows on the group's public listing (default false)."
  def show_post_count?(%__MODULE__{data: data}), do: Map.get(data, "show_post_count", false)

  @doc "Returns whether the top back link shows on the post page (default true)."
  def show_top_back_link?(%__MODULE__{data: data}),
    do: Map.get(data, "show_top_back_link", true)

  @doc "Returns whether listing card images click through to the post (default true)."
  def listing_image_links?(%__MODULE__{data: data}),
    do: Map.get(data, "listing_image_links", true)

  @doc "Returns whether listing cards animate on hover (default true)."
  def listing_animations?(%__MODULE__{data: data}),
    do: Map.get(data, "listing_animations", true)

  @doc "Returns the per-language display-name overrides map (language code => name)."
  def name_translations(%__MODULE__{data: data}) do
    case Map.get(data, "name_i18n") do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc """
  Returns the group's display name in `lang`, falling back to the primary-language
  `name` column when there's no translation for that language.

  Matching is base-language tolerant: the admin form stores overrides under the
  full language code (e.g. `"fr-FR"`) while the public side resolves by the short
  code (`"fr"`), so a lookup succeeds when either side uses the full or short form
  (as long as the base is unambiguous).
  """
  def translated_name(%__MODULE__{name: name} = group, lang) do
    resolve_name_translation(name_translations(group), lang) || name
  end

  @doc false
  # Shared by the struct accessor above and the public map resolver in
  # `PhoenixKit.Modules.Publishing.Groups.translated_group_name/2`.
  def resolve_name_translation(translations, lang) when is_map(translations) do
    lang = to_string(lang)
    base = lang |> String.split("-") |> List.first()

    non_blank(translations[lang]) ||
      non_blank(translations[base]) ||
      Enum.find_value(translations, fn {code, value} ->
        if String.split(to_string(code), "-") |> List.first() == base, do: non_blank(value)
      end)
  end

  defp non_blank(value) when is_binary(value) and value != "", do: value
  defp non_blank(_), do: nil

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
