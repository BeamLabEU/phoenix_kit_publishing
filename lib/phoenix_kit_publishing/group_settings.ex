defmodule PhoenixKit.Modules.Publishing.GroupSettings do
  @moduledoc """
  Machine-readable specification of a publishing group's per-group display
  settings — the settings stored in the group's `data` JSONB and edited on the
  admin "Edit Group" page.

  This is the single source of truth an AI, agent, MCP tool, or script can read
  to discover **what it may configure and to what**, then apply via
  `PhoenixKit.Modules.Publishing.update_group/3`. The admin form and the schema
  accessors describe the same settings; this module exposes them as data.

  Allowed values and enum defaults are pulled from
  `PhoenixKit.Modules.Publishing.Constants`, so the spec can never drift from the
  values `update_group/3` actually accepts.

  ## Entry shape

  Each `schema/0` entry is a map:

      %{
        key: "scrollbar_style",        # the params key update_group/3 expects
        type: :enum,                   # :enum | :boolean
        allowed: ["default", ...],     # valid values (enums: strings; booleans: [true, false])
        default: "default",            # value when unset
        scope: :appearance,            # :listing | :post | :appearance (where it shows)
        label: "Scrollbar style",      # short human label
        description: "…",              # one-line explanation
        depends_on: "…" | nil          # key whose truthiness makes this relevant, if any
      }

  ## Example — autonomous configuration

      params = %{"post_width" => "wide", "show_featured_image" => true, "scroll_timeline_enabled" => true}

      case GroupSettings.validate_params(params) do
        {:ok, params} -> Publishing.update_group("blog", params, actor_uuid: uuid)
        {:error, errors} -> # each %{key:, reason:} tells the AI what to fix
      end

  `validate_params/1` only inspects keys it owns; unknown keys (e.g. `name`,
  `slug`) pass through untouched so the result can go straight to
  `update_group/3`.
  """

  alias PhoenixKit.Modules.Publishing.Constants

  @boolean_allowed [true, false]

  @doc """
  Returns the full list of per-group display settings as structured maps.

  See the moduledoc for the entry shape. Order groups related settings by
  `scope` (listing, then post, then appearance) to read top-to-bottom like the
  admin form.
  """
  @spec schema() :: [map()]
  def schema do
    [
      # --- Listing page -----------------------------------------------------
      %{
        key: "listing_sort",
        type: :enum,
        allowed: Constants.listing_sorts(),
        default: Constants.default_listing_sort(),
        scope: :listing,
        label: "Post order",
        description:
          "Order of posts on the public listing, by effective publish date: \"newest\" or \"oldest\" first.",
        depends_on: nil
      },
      %{
        key: "show_post_count",
        type: :boolean,
        allowed: @boolean_allowed,
        default: false,
        scope: :listing,
        label: "Show the post count",
        description: "Show the total number of posts under the listing title.",
        depends_on: nil
      },
      %{
        key: "featured_enabled",
        type: :boolean,
        allowed: @boolean_allowed,
        default: true,
        scope: :listing,
        label: "Highlight featured posts",
        description:
          "When true, posts flagged featured in the editor are pinned to the top of the listing and shown larger.",
        depends_on: nil
      },
      %{
        key: "featured_layout",
        type: :enum,
        allowed: Constants.featured_layouts(),
        default: Constants.default_featured_layout(),
        scope: :listing,
        label: "Featured layout",
        description:
          "How featured posts render: \"hero\" (a band above the grid) or \"card\" (a larger card within the grid).",
        depends_on: "featured_enabled"
      },
      %{
        key: "featured_style",
        type: :enum,
        allowed: Constants.band_styles(),
        default: Constants.default_band_style(),
        scope: :listing,
        label: "Featured style",
        description:
          "The paint of featured cards, orthogonal to the layout: \"classic\" (image beside/above the text), \"cover\" (the featured image is the background, text overlaid), \"cover_panel\" (background image with a solid text panel), \"minimal\" (text only), or \"top\" (16:9 image banner above the text).",
        depends_on: "featured_enabled"
      },
      %{
        key: "newest_enabled",
        type: :boolean,
        allowed: @boolean_allowed,
        default: false,
        scope: :listing,
        label: "Highlight the latest post",
        description:
          "When true, the most recent post is pulled out of the grid into its own \"Latest\" band under any featured posts and shown larger.",
        depends_on: nil
      },
      %{
        key: "newest_layout",
        type: :enum,
        allowed: Constants.newest_layouts(),
        default: Constants.default_newest_layout(),
        scope: :listing,
        label: "Latest layout",
        description:
          "How the latest post renders: \"hero\" (a band above the grid) or \"card\" (a larger card within the grid).",
        depends_on: "newest_enabled"
      },
      %{
        key: "newest_style",
        type: :enum,
        allowed: Constants.band_styles(),
        default: Constants.default_band_style(),
        scope: :listing,
        label: "Latest style",
        description: "The paint of the Latest-band card — same vocabulary as featured_style.",
        depends_on: "newest_enabled"
      },
      %{
        key: "listing_image_links",
        type: :boolean,
        allowed: @boolean_allowed,
        default: true,
        scope: :listing,
        label: "Clickable card images",
        description:
          "When true (the default), a post card's image clicks through to the post, same as the title.",
        depends_on: nil
      },
      %{
        key: "listing_animations",
        type: :boolean,
        allowed: @boolean_allowed,
        default: true,
        scope: :listing,
        label: "Card hover animations",
        description:
          "When true (the default), listing cards lift slightly on hover as a click cue. Reduced-motion users never see the lift.",
        depends_on: nil
      },
      %{
        key: "scroll_timeline_enabled",
        type: :boolean,
        allowed: @boolean_allowed,
        default: false,
        scope: :listing,
        label: "Date-timeline rail",
        description:
          "Show a clickable date rail down the side of the listing to jump through the archive.",
        depends_on: nil
      },
      %{
        key: "scroll_timeline_granularity",
        type: :enum,
        allowed: Constants.timeline_granularities(),
        default: Constants.default_timeline_granularity(),
        scope: :listing,
        label: "Timeline markers",
        description:
          "Resolution of the timeline rail's markers: \"auto\" (fit to the posts' span), \"year\", \"month\", or \"day\".",
        depends_on: "scroll_timeline_enabled"
      },

      # --- Post page --------------------------------------------------------
      %{
        key: "post_width",
        type: :enum,
        allowed: Constants.post_widths(),
        default: Constants.default_post_width(),
        scope: :post,
        label: "Content width",
        description: "Width of the post's content column: \"narrow\", \"normal\", or \"wide\".",
        depends_on: nil
      },
      %{
        key: "post_date_position",
        type: :enum,
        allowed: Constants.post_date_positions(),
        default: Constants.default_post_date_position(),
        scope: :post,
        label: "Post date position",
        description:
          "Where the post's date renders relative to the title: \"above\", \"below\", or \"hidden\".",
        depends_on: nil
      },
      %{
        key: "show_breadcrumbs",
        type: :boolean,
        allowed: @boolean_allowed,
        default: false,
        scope: :post,
        label: "Breadcrumb trail",
        description:
          "Show the \"Home / Blog / …\" breadcrumb trail on the listing and post pages.",
        depends_on: nil
      },
      %{
        key: "show_featured_image",
        type: :boolean,
        allowed: @boolean_allowed,
        default: false,
        scope: :post,
        label: "Featured image",
        description: "Show the post's featured image as a hero at the top of the post page.",
        depends_on: nil
      },
      %{
        key: "show_top_back_link",
        type: :boolean,
        allowed: @boolean_allowed,
        default: true,
        scope: :post,
        label: "Top back link",
        description:
          "Show the subtle \"Back to <group>\" link at the top of the post page, mirroring the footer button (default on).",
        depends_on: nil
      },
      %{
        key: "show_reading_time",
        type: :boolean,
        allowed: @boolean_allowed,
        default: false,
        scope: :post,
        label: "Reading time",
        description: "Show an estimated \"N min read\" under the title.",
        depends_on: nil
      },
      %{
        key: "show_tags",
        type: :boolean,
        allowed: @boolean_allowed,
        default: false,
        scope: :post,
        label: "Tags",
        description: "Show the post's tags as chips under the header.",
        depends_on: nil
      },
      %{
        key: "scroll_progress_enabled",
        type: :boolean,
        allowed: @boolean_allowed,
        default: false,
        scope: :post,
        label: "Reading-progress bar",
        description: "Show a thin bar at the top of post pages that fills as the reader scrolls.",
        depends_on: nil
      },
      %{
        key: "scroll_headings_enabled",
        type: :boolean,
        allowed: @boolean_allowed,
        default: false,
        scope: :post,
        label: "Heading navigation rail",
        description:
          "Show a side rail of the post's headings (hidden automatically on short posts).",
        depends_on: nil
      },

      # --- Appearance -------------------------------------------------------
      %{
        key: "scrollbar_style",
        type: :enum,
        allowed: Constants.scrollbar_styles(),
        default: Constants.default_scrollbar_style(),
        scope: :appearance,
        label: "Scrollbar style",
        description:
          "Native scrollbar styling for every public page in the group: \"default\", \"branded\", or \"thin\". Only recolors the real bar — scrolling stays native.",
        depends_on: nil
      }
    ]
  end

  @doc "Returns just the setting keys (strings), in `schema/0` order."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(schema(), & &1.key)

  @doc """
  Returns a `%{key => default}` map of every setting's default value — the
  effective config of a brand-new group before any edits.
  """
  @spec default_config() :: %{String.t() => term()}
  def default_config, do: Map.new(schema(), fn s -> {s.key, s.default} end)

  @doc """
  Validates a proposed params map against the spec, normalizing recognized
  settings to their canonical types (booleans to `true`/`false`, enums to
  strings).

  Returns `{:ok, normalized}` — every input key preserved, with keys this module
  owns normalized — or `{:error, errors}` where each error is
  `%{key: key, reason: reason}`. Recognized settings are normalized to their
  canonical STRING key (so atom-keyed input like `%{post_width: "wide"}` comes
  back as `%{"post_width" => "wide"}` — `update_group/3` matches string keys
  only and would silently ignore an atom key). Keys not in the spec (e.g.
  `name`, `slug`) pass through untouched so the result can go straight to
  `update_group/3`.
  """
  @spec validate_params(map()) :: {:ok, map()} | {:error, [map()]}
  def validate_params(params) when is_map(params) do
    by_key = Map.new(schema(), fn s -> {s.key, s} end)

    {normalized, errors} =
      Enum.reduce(params, {%{}, []}, fn {key, value}, acc ->
        validate_param(Map.get(by_key, spec_key(key)), key, value, acc)
      end)

    if errors == [], do: {:ok, normalized}, else: {:error, Enum.reverse(errors)}
  end

  # Not a setting this module governs — pass through unchanged.
  defp validate_param(nil, key, value, {acc, errs}), do: {Map.put(acc, key, value), errs}

  # A governed setting: cast the value and store under the canonical string key.
  defp validate_param(setting, _key, value, {acc, errs}) do
    case cast_value(setting, value) do
      {:ok, cast} -> {Map.put(acc, setting.key, cast), errs}
      {:error, reason} -> {acc, [%{key: setting.key, reason: reason} | errs]}
    end
  end

  # Spec keys are strings; accept atom-keyed input for lookup without ever
  # to_string/1-ing arbitrary terms (a map/list key must not raise).
  defp spec_key(key) when is_binary(key), do: key
  defp spec_key(key) when is_atom(key), do: Atom.to_string(key)
  defp spec_key(_key), do: nil

  # Booleans accept the true/false booleans or their common string/toggle forms.
  defp cast_value(%{type: :boolean}, value) when value in [true, "true", "on"], do: {:ok, true}

  defp cast_value(%{type: :boolean}, value) when value in [false, "false", "off"],
    do: {:ok, false}

  defp cast_value(%{type: :boolean}, _value),
    do: {:error, "must be a boolean (true or false)"}

  defp cast_value(%{type: :enum, allowed: allowed}, value) when is_binary(value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, "must be one of: " <> Enum.join(allowed, ", ")}
  end

  defp cast_value(%{type: :enum, allowed: allowed}, value) when is_atom(value),
    do: cast_value(%{type: :enum, allowed: allowed}, Atom.to_string(value))

  # Anything else (maps, lists, numbers) is invalid for an enum — return an
  # error instead of letting to_string/1 raise Protocol.UndefinedError.
  defp cast_value(%{type: :enum, allowed: allowed}, _value),
    do: {:error, "must be one of: " <> Enum.join(allowed, ", ")}
end
