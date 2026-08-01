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

  @doc """
  True when a timestamp-mode post is scheduled for later and must not be
  public yet.

  A timestamp post is identified by a date AND a time, and the schedule was
  read as a date alone — so anything set for later today went public at
  midnight. Nine in the morning is a normal time to line up an announcement
  for six in the evening, and the listing carried its title, excerpt and
  image from the moment the day started.

  Three copies of the date-only test had drifted into the listing, the post
  page and the fallback resolver. One predicate, so a scheduled post becomes
  public at one moment on every path that asks.

  Both sides of the comparison are the SITE's wall clock, not UTC.
  `post_date`/`post_time` are stamped and edited in the configured
  `time_zone` offset (`Posts.maybe_add_initial_timestamp/3`) and shown
  as-is with no display conversion, so comparing them to `utc_now/0`
  released an embargoed post `offset` hours early on a site west of UTC —
  and held it back that long on a site east of it.

  Pass `now` (from `site_now/0`) when testing many posts in one pass: the
  offset comes from a settings read, and `filter_published/1` runs this
  over the whole listing cache.
  """
  @spec scheduled_ahead?(map()) :: boolean()
  def scheduled_ahead?(post), do: scheduled_ahead?(post, site_now())

  @spec scheduled_ahead?(map(), DateTime.t()) :: boolean()
  def scheduled_ahead?(post, now) do
    timestamp_mode?(post[:mode]) and post[:date] != nil and
      DateTime.compare(scheduled_at(post[:date], post[:time]), now) == :gt
  end

  defp scheduled_at(date, time) do
    # No time means the whole day is fair game from its first minute — the
    # old behaviour, kept for rows that predate a required post_time.
    #
    # "Etc/UTC" is a carrier for a naive wall clock here, not a claim about
    # the zone: `now` is built the same way, so the two are comparable.
    DateTime.new!(date, time || ~T[00:00:00], "Etc/UTC")
  end

  @doc """
  Now, on the site's wall clock — `DateTime.utc_now/0` shifted by the
  configured `time_zone` offset, which is the clock timestamp-mode posts
  are written and displayed on.

  Hoist this out of a loop; every call is a settings read.
  """
  @spec site_now() :: DateTime.t()
  def site_now, do: DateTime.add(DateTime.utc_now(), site_offset_seconds(), :second)

  @doc """
  The site's `time_zone` setting as a whole-hour offset in seconds (0 when
  unset or unparseable). The one place that reading lives, so post
  stamping, schedule release and feed dates can't drift apart.
  """
  @spec site_offset_seconds() :: integer()
  def site_offset_seconds do
    case Integer.parse(PhoenixKit.Settings.get_setting("time_zone", "0")) do
      {offset_hours, ""} -> offset_hours * 3600
      _ -> 0
    end
  rescue
    # Settings unreachable (no DB yet, sandbox without an owner): UTC is the
    # documented default and a scheduling check must not crash a page.
    _ -> 0
  end

  # ---------------------------------------------------------------------------
  # Statuses
  # ---------------------------------------------------------------------------

  @status_draft "draft"
  @status_published "published"
  @status_archived "archived"
  @status_trashed "trashed"

  @post_statuses [@status_draft, @status_published, @status_archived, @status_trashed]
  @content_statuses [@status_draft, @status_published, @status_archived]
  @group_statuses ["active", @status_trashed]

  @doc ~S|The `"draft"` status.|
  def status_draft, do: @status_draft

  @doc ~S|The `"published"` status.|
  def status_published, do: @status_published

  @doc ~S|The `"archived"` status.|
  def status_archived, do: @status_archived

  @doc ~S|The `"trashed"` status.|
  def status_trashed, do: @status_trashed

  @doc """
  True for the published status.

  Note this is the *publishing* vocabulary. The comments module has its own
  `"published"` status on a different table, and the two are unrelated — a
  comment being published says nothing about the post it hangs off. Don't
  reach for this when checking a comment.
  """
  @spec published?(String.t() | nil) :: boolean()
  def published?(status), do: status == @status_published

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
  # Latest post (per-group public-listing config)
  # ---------------------------------------------------------------------------

  @newest_layouts ["hero", "card"]
  @default_newest_layout "hero"

  @doc ~S|Valid latest-post layouts: "hero" (band above the grid) or "card" (larger card in the grid).|
  def newest_layouts, do: @newest_layouts

  @doc ~S|Default latest-post layout ("hero").|
  def default_newest_layout, do: @default_newest_layout

  # ---------------------------------------------------------------------------
  # Band styles (shared vocabulary for the Featured and Latest bands)
  # ---------------------------------------------------------------------------

  @band_styles ["classic", "cover", "cover_panel", "minimal", "top"]
  @default_band_style "classic"

  @doc ~S"""
  Valid band styles for the Featured/Latest bands — the PAINT of a band card,
  orthogonal to its layout (which stays size/placement: hero band vs card in
  grid): "classic" (image beside/above the text — the original variants),
  "cover" (the featured image is the card's background, text overlaid on a
  gradient scrim), "cover_panel" (background image with an opaque text panel),
  "minimal" (text-only editorial band, image ignored), "top" (16:9 image
  banner stacked above the text).
  """
  def band_styles, do: @band_styles

  @doc ~S|Default band style ("classic" — the pre-styles rendering, unchanged).|
  def default_band_style, do: @default_band_style

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

  @listing_layouts ["grid", "list", "minimal"]
  @default_listing_layout "grid"

  @doc ~S|Valid public-listing layouts: "grid" (card grid), "list" (thumbnail rows), or "minimal" (date — title lines, no images).|
  def listing_layouts, do: @listing_layouts

  @doc ~S|Default public-listing layout ("grid").|
  def default_listing_layout, do: @default_listing_layout

  @notes_styles ["footnotes", "panel"]
  @default_notes_style "footnotes"

  @doc ~S|Valid author-note display styles: "footnotes" (numbered refs + a collected bottom section + hover popovers) or "panel" (clicking the phrase slides a right-side panel out with the note and its comments).|
  def notes_styles, do: @notes_styles

  @doc ~S|Default author-note display style ("footnotes" — the original layout).|
  def default_notes_style, do: @default_notes_style

  @post_date_positions ["above", "below", "hidden"]
  @default_post_date_position "below"

  @doc ~S|Valid post-date positions relative to the title: "above", "below", or "hidden".|
  def post_date_positions, do: @post_date_positions

  @doc ~S|Default post-date position ("below" the title).|
  def default_post_date_position, do: @default_post_date_position

  @post_widths ["narrow", "normal", "wide"]
  @default_post_width "normal"

  @doc ~S|Valid post-page content widths: "narrow", "normal", or "wide".|
  def post_widths, do: @post_widths

  @doc ~S|Default post-page content width ("normal").|
  def default_post_width, do: @default_post_width

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
