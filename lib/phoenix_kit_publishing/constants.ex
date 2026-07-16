defmodule PhoenixKit.Modules.Publishing.Constants do
  @moduledoc """
  Centralized constants for the Publishing module.

  Provides canonical lists for statuses, modes, and types used across
  schemas, business logic, and templates. Import or alias this module
  instead of hardcoding these values inline.

  For guard clauses and pattern matches, use the module attributes:

      @timestamp_modes Publishing.Constants.timestamp_modes()
      @slug_modes Publishing.Constants.slug_modes()

      def my_func(mode) when mode in @timestamp_modes do ...
  """

  # ---------------------------------------------------------------------------
  # Modes (post and group)
  # ---------------------------------------------------------------------------

  @timestamp_modes [:timestamp, "timestamp"]
  @slug_modes [:slug, "slug"]
  @valid_modes ["timestamp", "slug"]

  @doc "Atom and string variants for timestamp mode — use in guards/pattern matches."
  def timestamp_modes, do: @timestamp_modes

  @doc "Atom and string variants for slug mode — use in guards/pattern matches."
  def slug_modes, do: @slug_modes

  @doc "Valid mode strings for schema validation."
  def valid_modes, do: @valid_modes

  @doc "Returns true if mode is a timestamp mode (atom or string)."
  def timestamp_mode?(mode), do: mode in @timestamp_modes

  @doc "Returns true if mode is a slug mode (atom or string)."
  def slug_mode?(mode), do: mode in @slug_modes

  # ---------------------------------------------------------------------------
  # Statuses
  # ---------------------------------------------------------------------------

  @post_statuses ["draft", "published", "archived", "trashed"]
  @content_statuses ["draft", "published", "archived"]
  @group_statuses ["active", "trashed"]

  @doc "Valid post statuses: draft, published, archived, trashed."
  def post_statuses, do: @post_statuses

  @doc "Valid version and content statuses: draft, published, archived."
  def content_statuses, do: @content_statuses

  @doc "Valid group statuses: active, trashed."
  def group_statuses, do: @group_statuses

  # ---------------------------------------------------------------------------
  # Group types
  # ---------------------------------------------------------------------------

  @preset_types ["blog", "faq", "legal"]
  @valid_types ["blog", "faq", "legal", "custom"]

  @doc "Preset group types (shown as radio buttons in UI)."
  def preset_types, do: @preset_types

  @doc "All valid group types including custom."
  def valid_types, do: @valid_types

  # ---------------------------------------------------------------------------
  # Featured posts (per-group public-listing config)
  # ---------------------------------------------------------------------------

  @featured_layouts ["hero", "card"]
  @default_featured_layout "hero"

  @doc ~S|Valid featured-post layouts: "hero" (band above the grid) or "card" (larger card in the grid).|
  def featured_layouts, do: @featured_layouts

  @doc ~S|Default featured-post layout ("hero").|
  def default_featured_layout, do: @default_featured_layout

  # ---------------------------------------------------------------------------
  # Scroll navigation (per-group public-side config)
  # ---------------------------------------------------------------------------

  @scrollbar_styles ["default", "branded", "thin"]
  @default_scrollbar_style "default"

  @doc ~S|Valid scrollbar styles: "default" (native, unstyled), "branded" (theme-colored), "thin" (theme-colored + thin).|
  def scrollbar_styles, do: @scrollbar_styles

  @doc ~S|Default scrollbar style ("default" — the browser's native bar, untouched).|
  def default_scrollbar_style, do: @default_scrollbar_style

  @timeline_granularities ["auto", "year", "month", "day"]
  @default_timeline_granularity "auto"

  @doc ~S|Valid date-timeline granularities: "auto" (fit to the posts' date span), "year", "month", or "day".|
  def timeline_granularities, do: @timeline_granularities

  @doc ~S|Default date-timeline granularity ("auto").|
  def default_timeline_granularity, do: @default_timeline_granularity

  # ---------------------------------------------------------------------------
  # Listing sort order (per-group public-listing config)
  # ---------------------------------------------------------------------------

  @listing_sorts ["newest", "oldest"]
  @default_listing_sort "newest"

  @doc ~S|Valid public-listing sort orders: "newest" or "oldest", by effective publish date.|
  def listing_sorts, do: @listing_sorts

  @doc ~S|Default public-listing sort order ("newest" first).|
  def default_listing_sort, do: @default_listing_sort

  # ---------------------------------------------------------------------------
  # Defaults
  # ---------------------------------------------------------------------------

  @default_mode "timestamp"
  @default_type "blog"
  @default_title "Untitled"

  @doc "Default group mode."
  def default_mode, do: @default_mode

  @doc "Default group type."
  def default_type, do: @default_type

  @doc "Default title for posts without a title."
  def default_title, do: @default_title

  # ---------------------------------------------------------------------------
  # Schema limits
  # ---------------------------------------------------------------------------

  @max_slug_length 500
  @max_title_length 500
  @max_language_code_length 10
  @max_group_name_length 255
  @max_group_slug_length 255

  @doc "Max length for post/content slugs."
  def max_slug_length, do: @max_slug_length

  @doc "Max length for content titles."
  def max_title_length, do: @max_title_length

  @doc "Max length for language codes."
  def max_language_code_length, do: @max_language_code_length

  @doc "Max length for group names."
  def max_group_name_length, do: @max_group_name_length

  @doc "Max length for group slugs."
  def max_group_slug_length, do: @max_group_slug_length
end
