defmodule PhoenixKit.Modules.Publishing.Web.HTML do
  @moduledoc """
  HTML rendering functions for Publishing.Web.Controller.
  """
  use PhoenixKitWeb, :html

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Storage

  @timestamp_modes Constants.timestamp_modes()
  @slug_modes Constants.slug_modes()

  import PhoenixKitWeb.Components.LanguageSwitcher

  def all_groups(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
    flash={@flash}
    page_title={@page_title}
    current_path={@conn.request_path}
    >
    <div class="groups-overview-container max-w-6xl mx-auto px-6 py-8">
    <%!-- Page Header --%>
    <header class="mb-8">
      <h1 class="text-2xl sm:text-4xl font-bold mb-2">Publishing</h1>
      <p class="text-base sm:text-lg text-base-content/70">
        Explore our published content
      </p>
    </header>
    <%!-- Group Cards --%>
    <%= if length(@groups) > 0 do %>
      <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
        <%= for group <- @groups do %>
          <article class="card bg-base-200 shadow-md hover:shadow-lg transition-shadow">
            <div class="card-body">
              <h2 class="card-title text-2xl">
                <.link
                  navigate={group_listing_path(@current_language, group["slug"])}
                  class="hover:text-primary"
                >
                  {group["name"]}
                </.link>
              </h2>

              <div class="text-sm text-base-content/70 mt-2">
                <span>{group["post_count"]} posts</span>
              </div>

              <div class="card-actions justify-end mt-4">
                <.link
                  navigate={group_listing_path(@current_language, group["slug"])}
                  class="btn btn-sm btn-primary"
                >
                  View Posts →
                </.link>
              </div>
            </div>
          </article>
        <% end %>
      </div>
    <% else %>
      <div class="alert alert-info">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          class="stroke-current shrink-0 w-6 h-6"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
          >
          </path>
        </svg>
        <span>No groups configured yet.</span>
      </div>
    <% end %>
    </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  def index(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
    flash={@flash}
    page_title={@page_title}
    current_path={@conn.request_path}
    >
    <div class="group-index-container max-w-6xl mx-auto px-6 py-8">
    <%!-- Breadcrumb Navigation --%>
    <div class="breadcrumbs text-sm mb-6">
      <ul>
        <%= for breadcrumb <- @breadcrumbs do %>
          <li>
            <%= if breadcrumb.url do %>
              <.link navigate={breadcrumb.url}>{breadcrumb.label}</.link>
            <% else %>
              {breadcrumb.label}
            <% end %>
          </li>
        <% end %>
      </ul>
    </div>
    <%!-- Group Header --%>
    <header class="mb-8">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl sm:text-4xl font-bold mb-2">{@group["name"]}</h1>
          <p class="text-base sm:text-lg text-base-content/70">
            {ngettext("1 post", "%{count} posts", @total_count)}
          </p>
        </div>
        <%!-- Admin Edit Button --%>
        <%= if assigns[:admin_edit_url] do %>
          <a href={@admin_edit_url} class="btn btn-sm btn-ghost gap-2">
            <.icon name="hero-pencil-square" class="w-4 h-4" />
            {@admin_edit_label || "Edit"}
          </a>
        <% end %>
      </div>
      <%!-- Language Switcher --%>
      <%= if length(@translations) > 1 do %>
        <div class="mt-4">
          <.language_switcher
            languages={build_public_translations(@translations, @current_language)}
            current_language={@current_language}
            show_status={false}
            size={:sm}
          />
        </div>
      <% end %>
    </header>
    <%!-- Posts Grid --%>
    <%= if @total_count > 0 do %>
      <% date_counts = build_date_counts(@posts) %>
      <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
        <%= for post <- @posts do %>
          <article class="card bg-base-200 shadow-md hover:shadow-lg transition-shadow">
            <%= if featured_image_url = featured_image_url(post, "medium") do %>
              <figure class="h-40 w-full overflow-hidden rounded-t-2xl bg-base-300">
                <img
                  src={featured_image_url}
                  alt={post.metadata.title || gettext("Featured image")}
                  class="h-full w-full object-cover"
                  loading="lazy"
                />
              </figure>
            <% end %>
            <div class="card-body">
              <h2 class="card-title text-xl">
                <.link
                  navigate={build_post_url(@group["slug"], post, @current_language, date_counts)}
                  class="hover:text-primary"
                >
                  {post.metadata.title}
                </.link>
              </h2>

              <% excerpt =
                if Map.get(post.metadata, :description) do
                  post.metadata.description
                else
                  extract_excerpt(post.content)
                end %>
              <%= if excerpt && excerpt != "" do %>
                <p class="text-sm text-base-content/70 line-clamp-3">
                  {excerpt}
                </p>
              <% end %>

              <div class="card-actions justify-between items-center mt-4">
                <%= if has_publication_date?(post) do %>
                  <time
                    class="text-xs text-base-content/60"
                    datetime={post.metadata.published_at || ""}
                  >
                    {format_post_date(post, @group["slug"], date_counts)}
                  </time>
                <% else %>
                  <span class="text-xs text-base-content/60"></span>
                <% end %>

                <.link
                  navigate={build_post_url(@group["slug"], post, @current_language, date_counts)}
                  class="btn btn-sm btn-primary"
                >
                  {gettext("Read More →")}
                </.link>
              </div>
            </div>
          </article>
        <% end %>
      </div>
      <%!-- Pagination --%>
      <%= if @total_pages > 1 do %>
        <div class="join mt-8 flex justify-center">
          <%= for page_num <- 1..@total_pages do %>
            <%= if page_num == @page do %>
              <button class="join-item btn btn-active">{page_num}</button>
            <% else %>
              <.link
                navigate={group_listing_path(@current_language, @group["slug"], page: page_num)}
                class="join-item btn"
              >
                {page_num}
              </.link>
            <% end %>
          <% end %>
        </div>
      <% end %>
    <% else %>
      <div class="alert alert-info">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          class="stroke-current shrink-0 w-6 h-6"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
          >
          </path>
        </svg>
        <span>{gettext("No published posts yet.")}</span>
      </div>
    <% end %>
    </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  def show(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
    flash={@flash}
    page_title={@page_title}
    current_path={@conn.request_path}
    phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
    >
    <article class="post-container max-w-4xl mx-auto px-6 py-8">
    <%!-- Breadcrumb Navigation --%>
    <div class="breadcrumbs text-sm mb-6">
      <ul>
        <%= for breadcrumb <- @breadcrumbs do %>
          <li>
            <%= if breadcrumb.url do %>
              <.link navigate={breadcrumb.url}>{breadcrumb.label}</.link>
            <% else %>
              {breadcrumb.label}
            <% end %>
          </li>
        <% end %>
      </ul>
    </div>

    <%!-- Post Header --%>
    <header class="mb-8 border-b pb-6">
      <%= if has_publication_date?(@post) do %>
        <div class="flex items-center gap-2 text-sm text-base-content/70">
          <%!-- Publication Date (includes time when multiple posts on same date) --%>
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
            />
          </svg>
          <time datetime={@post.metadata.published_at || ""}>
            {format_post_date(@post, @group_slug)}
          </time>
        </div>
      <% end %>
      <div class="flex flex-wrap items-center gap-4 mt-4">
        <%!-- Language Switcher --%>
        <%= if length(@translations) > 1 do %>
          <.language_switcher
            languages={build_public_translations(@translations, @current_language)}
            current_language={@current_language}
            show_status={false}
            size={:sm}
          />
        <% end %>
        <%!-- Admin Edit Button --%>
        <%= if assigns[:admin_edit_url] do %>
          <a href={@admin_edit_url} class="btn btn-sm btn-ghost gap-2">
            <.icon name="hero-pencil-square" class="w-4 h-4" />
            {@admin_edit_label || "Edit"}
          </a>
        <% end %>
        <%!-- Version History Dropdown --%>
        <%= if @version_dropdown do %>
          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-ghost btn-sm gap-1">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              v{@version_dropdown.current_version}
              <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 9l-7 7-7-7"
                />
              </svg>
            </div>
            <ul
              tabindex="0"
              class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-40 border border-base-200"
            >
              <%= for v <- @version_dropdown.versions do %>
                <li>
                  <.link
                    navigate={v.url}
                    class={"flex items-center justify-between #{if v.is_current, do: "active"}"}
                  >
                    <span>v{v.version}</span>
                    <%= if v.is_live do %>
                      <span class="badge badge-success badge-xs h-auto">live</span>
                    <% end %>
                  </.link>
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>
      </div>
      <h1 class="text-3xl font-bold mt-4">
        {@post.metadata.title || PhoenixKit.Modules.Publishing.Constants.default_title()}
      </h1>
    </header>
    <%!-- Post Content --%>
    <div class="markdown-content max-w-none">
      {raw(@html_content)}
    </div>
    <%!-- Post Footer --%>
    <footer class="mt-12 pt-6 border-t">
      <.link
        navigate={group_listing_path(@current_language, @group_slug)}
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> {gettext("Back to %{group}",
          group: String.capitalize(@group_slug)
        )}
      </.link>
    </footer>
    </article>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  @doc """
  Builds the public URL for a group listing page.
  Omits the locale prefix when the site is effectively single-language.
  Can also omit the default-language prefix when that setting is enabled.
  """
  def group_listing_path(language, group_slug, params \\ []) do
    language =
      LanguageHelpers.url_language_code(language) || LanguageHelpers.get_primary_language_base()

    segments =
      if LanguageHelpers.use_language_prefix?(language),
        do: [language, group_slug],
        else: [group_slug]

    base_path = build_public_path(segments)

    case params do
      [] -> base_path
      _ -> base_path <> "?" <> URI.encode_query(params)
    end
  end

  @doc """
  Builds a post URL based on mode.
  Omits the locale prefix when the site is effectively single-language.
  Can also omit the default-language prefix when that setting is enabled.

  For slug mode posts, uses the language-specific URL slug (from post.url_slug
  or post.language_slugs[language]) for SEO-friendly localized URLs.

  For timestamp mode posts:
  - If only one post exists on the date, uses date-only URL (e.g., /group/2025-12-09)
  - If multiple posts exist on the date, includes time (e.g., /group/2025-12-09/16:26)
  """
  def build_post_url(group_slug, post, language, date_counts \\ nil) do
    language =
      LanguageHelpers.url_language_code(language) || LanguageHelpers.get_primary_language_base()

    case post.mode do
      mode when mode in @slug_modes ->
        # Use language-specific URL slug for SEO-friendly localized URLs
        url_slug = get_url_slug_for_language(post, language)

        segments =
          if LanguageHelpers.use_language_prefix?(language),
            do: [language, group_slug, url_slug],
            else: [group_slug, url_slug]

        build_public_path(segments)

      mode when mode in @timestamp_modes ->
        date = get_timestamp_date(post)
        post_count = lookup_date_count(date_counts, group_slug, date)

        segments = timestamp_url_segments(language, group_slug, date, post_count > 1, post)

        build_public_path(segments)

      _ ->
        # Use language-specific URL slug for fallback mode as well
        url_slug = get_url_slug_for_language(post, language)

        segments =
          if LanguageHelpers.use_language_prefix?(language),
            do: [language, group_slug, url_slug],
            else: [group_slug, url_slug]

        build_public_path(segments)
    end
  end

  defp timestamp_url_segments(language, group_slug, date, true = _include_time, post) do
    time = get_timestamp_time(post)

    if LanguageHelpers.use_language_prefix?(language),
      do: [language, group_slug, date, time],
      else: [group_slug, date, time]
  end

  defp timestamp_url_segments(language, group_slug, date, false = _include_time, _post) do
    if LanguageHelpers.use_language_prefix?(language),
      do: [language, group_slug, date],
      else: [group_slug, date]
  end

  # Gets the URL slug for a specific language
  # Priority:
  # 1. Direct url_slug field on post (set by controller for specific language)
  # 2. language_slugs map (from cache, contains all languages)
  # 3. metadata.url_slug (from content record, current language only)
  # 4. post.slug (post slug fallback)
  defp get_url_slug_for_language(post, language) do
    cond do
      # Direct url_slug on post (highest priority, set by controller)
      Map.get(post, :url_slug) not in [nil, ""] ->
        post.url_slug

      # language_slugs map from cache
      map_size(Map.get(post, :language_slugs, %{})) > 0 ->
        resolved_key =
          LanguageHelpers.resolve_language_key(language, Map.keys(post.language_slugs))

        Map.get(post.language_slugs, resolved_key, post.slug)

      # metadata.url_slug
      is_map(Map.get(post, :metadata)) and Map.get(post.metadata, :url_slug) not in [nil, ""] ->
        post.metadata.url_slug

      # Default to post slug
      true ->
        post.slug
    end
  end

  @doc """
  Builds a public path with explicit date and time (always includes time).
  Used when redirecting from date-only URLs to full timestamp URLs.
  """
  def build_public_path_with_time(language, group_slug, date, time) do
    language =
      LanguageHelpers.url_language_code(language) || LanguageHelpers.get_primary_language_base()

    segments =
      if LanguageHelpers.use_language_prefix?(language),
        do: [language, group_slug, date, time],
        else: [group_slug, date, time]

    build_public_path(segments)
  end

  @doc """
  Formats a date for display using locale-aware month names.
  """
  def format_date(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_date()
    |> locale_strftime(gettext("%B %d, %Y"))
  end

  def format_date(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        datetime
        |> DateTime.to_date()
        |> locale_strftime(gettext("%B %d, %Y"))

      _ ->
        datetime_string
    end
  end

  def format_date(_), do: ""

  @doc """
  Formats a date with time for display.
  Used when multiple posts exist on the same date.
  """
  def format_date_with_time(datetime) when is_struct(datetime, DateTime) do
    date_str = locale_strftime(datetime, gettext("%B %d, %Y"))
    time_str = Calendar.strftime(datetime, "%H:%M")
    gettext("%{date} at %{time}", date: date_str, time: time_str)
  end

  def format_date_with_time(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        date_str = locale_strftime(datetime, gettext("%B %d, %Y"))
        time_str = Calendar.strftime(datetime, "%H:%M")
        gettext("%{date} at %{time}", date: date_str, time: time_str)

      _ ->
        datetime_string
    end
  end

  def format_date_with_time(_), do: ""

  @doc """
  Checks if a post has a publication date to display.
  For timestamp mode, the date comes from the DB fields.
  For slug mode, it comes from metadata.published_at.
  """
  def has_publication_date?(post) do
    case post.mode do
      mode when mode in @timestamp_modes ->
        # Timestamp mode always has a date (from DB fields)
        post[:date] != nil

      _ ->
        # Slug mode uses metadata.published_at
        published_at = get_in(post, [:metadata, :published_at])
        published_at != nil and published_at != ""
    end
  end

  @doc """
  Formats a post's publication date, including time only when multiple posts exist on the same date.
  """
  def format_post_date(post, group_slug, date_counts \\ nil) do
    case post.mode do
      mode when mode in @timestamp_modes ->
        # For timestamp mode, use date/time from DB fields
        date = get_timestamp_date(post)
        post_count = lookup_date_count(date_counts, group_slug, date)

        if post_count > 1 do
          format_timestamp_date_with_time(post)
        else
          format_timestamp_date(post)
        end

      _ ->
        format_date(post.metadata.published_at)
    end
  end

  @doc """
  Formats a date for URL.
  """
  def format_date_for_url(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  def format_date_for_url(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        datetime
        |> DateTime.to_date()
        |> Date.to_iso8601()

      _ ->
        "2025-01-01"
    end
  end

  def format_date_for_url(_), do: "2025-01-01"

  @doc """
  Formats time for URL (HH:MM).
  """
  def format_time_for_url(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
    |> String.slice(0..4)
  end

  def format_time_for_url(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        datetime
        |> DateTime.to_time()
        |> Time.truncate(:second)
        |> Time.to_string()
        |> String.slice(0..4)

      _ ->
        "00:00"
    end
  end

  def format_time_for_url(_), do: "00:00"

  @doc """
  Pluralizes a word based on count.
  """
  def pluralize(1, singular, _plural), do: "1 #{singular}"
  def pluralize(count, _singular, plural), do: "#{count} #{plural}"

  @doc """
  Extracts and renders an excerpt from post content.
  Returns content before <!-- more --> tag, or first paragraph if no tag.
  Renders markdown and strips HTML tags for plain text display.
  """
  def extract_excerpt(content) when is_binary(content) do
    excerpt_markdown =
      if String.contains?(content, "<!-- more -->") do
        # Extract content before <!-- more --> tag
        content
        |> String.split("<!-- more -->")
        |> List.first()
        |> String.trim()
      else
        # Get first paragraph (content before first double newline)
        content
        |> String.split(~r/\n\s*\n/, parts: 2)
        |> List.first()
        |> String.trim()
      end

    # Render markdown to HTML
    html = Renderer.render_markdown(excerpt_markdown)

    # Strip HTML tags to get plain text
    html
    |> Phoenix.HTML.raw()
    |> Phoenix.HTML.safe_to_string()
    |> strip_html_tags()
    |> String.trim()
  end

  def extract_excerpt(_), do: ""

  defp strip_html_tags(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Formats a timestamp post's date for display (e.g., "December 31, 2025")
  defp format_timestamp_date(post) do
    cond do
      is_struct(post[:date], Date) ->
        locale_strftime(post.date, gettext("%B %d, %Y"))

      is_binary(post[:date]) ->
        case Date.from_iso8601(post.date) do
          {:ok, date} -> locale_strftime(date, gettext("%B %d, %Y"))
          _ -> post.date
        end

      true ->
        format_date(post.metadata.published_at)
    end
  end

  # Formats a timestamp post's date with time for display (e.g., "December 31, 2025 at 03:42")
  defp format_timestamp_date_with_time(post) do
    date_str = format_timestamp_date(post)
    time_str = get_timestamp_time(post)
    gettext("%{date} at %{time}", date: date_str, time: time_str)
  end

  # Gets the date for a timestamp-mode post from post.date field (DB fields)
  # Falls back to metadata.published_at if post.date not available
  defp get_timestamp_date(post) do
    cond do
      # Use post.date from DB fields (e.g., Date struct or "2025-12-31")
      is_struct(post[:date], Date) ->
        Date.to_iso8601(post.date)

      is_binary(post[:date]) ->
        post.date

      # Fallback to metadata.published_at if no post.date
      true ->
        format_date_for_url(post.metadata.published_at)
    end
  end

  # Gets the time for a timestamp-mode post from post.time field (DB fields)
  # Falls back to metadata.published_at if post.time not available
  defp get_timestamp_time(post) do
    cond do
      # Use post.time from DB fields (e.g., "03:42" or ~T[03:42:00])
      is_struct(post[:time], Time) ->
        post.time |> Time.to_string() |> String.slice(0..4)

      is_binary(post[:time]) ->
        # Ensure format is HH:MM (5 chars)
        String.slice(post.time, 0..4)

      # Fallback to metadata.published_at if no post.time
      true ->
        format_time_for_url(post.metadata.published_at)
    end
  end

  defp build_public_path(segments) do
    parts =
      url_prefix_segments() ++
        (segments
         |> Enum.reject(&(&1 in [nil, ""]))
         |> Enum.map(&to_string/1))

    case parts do
      [] -> "/"
      _ -> "/" <> Enum.join(parts, "/")
    end
  end

  defp url_prefix_segments do
    Config.get_url_prefix()
    |> case do
      "/" -> []
      prefix -> prefix |> String.trim("/") |> String.split("/", trim: true)
    end
  end

  @doc """
  Pre-computes date counts for timestamp-mode posts to avoid per-post DB queries.

  Returns a map of `%{date_string => count}` for use with `build_post_url/4`
  and `format_post_date/3`.
  """
  def build_date_counts(posts) do
    posts
    |> Enum.filter(&(&1.mode in @timestamp_modes))
    |> Enum.map(&get_timestamp_date/1)
    |> Enum.frequencies()
  end

  # Looks up date count from pre-computed map, falling back to DB query
  defp lookup_date_count(nil, group_slug, date) do
    Publishing.count_posts_on_date(group_slug, date)
  end

  defp lookup_date_count(date_counts, _group_slug, date) when is_map(date_counts) do
    Map.get(date_counts, date, 0)
  end

  @doc """
  Resolves a featured image URL for a post, falling back to the original variant.
  """
  def featured_image_url(post, variant \\ "medium") do
    post.metadata
    |> Map.get(:featured_image_uuid)
    |> resolve_featured_image_url(variant)
  end

  defp resolve_featured_image_url(nil, _variant), do: nil
  defp resolve_featured_image_url("", _variant), do: nil

  defp resolve_featured_image_url(file_uuid, variant) when is_binary(file_uuid) do
    Storage.get_public_url_by_uuid(file_uuid, variant) ||
      Storage.get_public_url_by_uuid(file_uuid)
  rescue
    _ -> nil
  end

  @doc """
  Builds language data for the publishing_language_switcher component on public pages.
  Converts the @translations assign to the format expected by the component.
  """
  def build_public_translations(translations, _current_language) do
    Enum.map(translations, fn translation ->
      %{
        code: translation[:code] || translation.code,
        display_code: translation[:display_code] || translation[:code] || translation.code,
        name: translation[:name] || translation.name,
        flag: translation[:flag] || "",
        url: translation[:url] || translation.url,
        status: "published",
        exists: true
      }
    end)
  end

  # Locale-aware Calendar.strftime that translates month names via gettext.
  # The format string itself can also be translated (e.g., "%d %B %Y" for day-first locales).
  defp locale_strftime(date_or_datetime, format) do
    Calendar.strftime(date_or_datetime, format,
      month_names: fn month ->
        Enum.at(translated_month_names(), month - 1)
      end,
      abbreviated_month_names: fn month ->
        Enum.at(translated_abbreviated_month_names(), month - 1)
      end
    )
  end

  defp translated_month_names do
    [
      gettext("January"),
      gettext("February"),
      gettext("March"),
      gettext("April"),
      gettext("May"),
      gettext("June"),
      gettext("July"),
      gettext("August"),
      gettext("September"),
      gettext("October"),
      gettext("November"),
      gettext("December")
    ]
  end

  defp translated_abbreviated_month_names do
    [
      gettext("Jan"),
      gettext("Feb"),
      gettext("Mar"),
      gettext("Apr"),
      gettext("May"),
      gettext("Jun"),
      gettext("Jul"),
      gettext("Aug"),
      gettext("Sep"),
      gettext("Oct"),
      gettext("Nov"),
      gettext("Dec")
    ]
  end
end
