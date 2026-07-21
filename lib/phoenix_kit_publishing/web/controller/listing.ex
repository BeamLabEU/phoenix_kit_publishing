defmodule PhoenixKit.Modules.Publishing.Web.Controller.Listing do
  @moduledoc """
  Group listing functionality for the publishing controller.

  Handles rendering post listings with:
  - Language filtering and fallback
  - Pagination
  - Translation link building for listings
  """

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.LanguageHelpers

  @timestamp_modes Constants.timestamp_modes()
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostFetching
  alias PhoenixKit.Modules.Publishing.Web.Controller.Translations
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings

  # ============================================================================
  # Group Listing Rendering
  # ============================================================================

  @doc """
  Renders a group listing page.
  """
  def render_group_listing(conn, group_slug, language, params) do
    case fetch_group(group_slug) do
      {:ok, group} ->
        # Only preserve pagination params for redirects
        pagination_params = Map.take(params, ["page"])

        # Check if we need to redirect to canonical URL
        canonical_language = Language.get_canonical_url_language(language)

        canonical_url =
          PublishingHTML.group_listing_path(canonical_language, group_slug, pagination_params)

        if canonical_redirect?(conn, language, canonical_language, canonical_url) do
          {:redirect_301, canonical_url}
        else
          page = get_page_param(params)
          per_page = get_per_page_setting()

          # Try cache first, fall back to DB query
          all_posts_unfiltered = PostFetching.fetch_posts_with_cache(group_slug)
          published_posts = filter_published(all_posts_unfiltered)

          # Resolve posts for the requested language, with fallback handling
          listing_context = %{
            group: group,
            group_slug: group_slug,
            language: language,
            canonical_language: canonical_language,
            published_posts: published_posts,
            all_posts_unfiltered: all_posts_unfiltered,
            page: page,
            per_page: per_page,
            pagination_params: pagination_params
          }

          resolve_listing_posts_for_language(conn, listing_context)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Language Resolution for Listings
  # ============================================================================

  @doc """
  Resolves posts for the requested language, handling exact match vs fallback.
  """
  def resolve_listing_posts_for_language(conn, ctx) do
    exact_language_posts =
      filter_by_exact_language(ctx.published_posts, ctx.group_slug, ctx.language)

    case resolve_language_posts(
           exact_language_posts,
           ctx.published_posts,
           ctx.group_slug,
           ctx.language
         ) do
      {:exact, posts} ->
        render_group_index(conn, ctx, posts)

      {:fallback, fallback_language} ->
        fallback_url =
          PublishingHTML.group_listing_path(
            fallback_language,
            ctx.group_slug,
            ctx.pagination_params
          )

        {:redirect_301, fallback_url}

      :not_found ->
        # Group exists but no published posts — render empty listing instead of 404
        render_group_index(conn, ctx, [])
    end
  end

  # Returns {:exact, posts}, {:fallback, language}, or :not_found
  defp resolve_language_posts(exact_posts, _published_posts, _group_slug, _language)
       when exact_posts != [] do
    {:exact, exact_posts}
  end

  defp resolve_language_posts([], published_posts, group_slug, language) do
    fallback_posts = filter_by_exact_language(published_posts, group_slug, language)

    if fallback_posts != [] do
      {:fallback, get_fallback_language(language, fallback_posts)}
    else
      :not_found
    end
  end

  defp canonical_redirect?(conn, language, canonical_language, canonical_url) do
    (canonical_language != language or
       Language.prefixed_default_language_request?(conn, canonical_language)) and
      not Language.request_matches_canonical_url?(conn, canonical_url)
  end

  # ============================================================================
  # Group Index Rendering
  # ============================================================================

  @doc """
  Renders the group index page with resolved posts.
  """
  def render_group_index(_conn, ctx, all_posts) do
    all_posts = sort_listing(all_posts, Map.get(ctx.group, "listing_sort", "newest"))
    featured_enabled = Map.get(ctx.group, "featured_enabled", true)
    {featured_posts, grid_posts} = partition_featured(all_posts, featured_enabled)
    newest_enabled = Map.get(ctx.group, "newest_enabled", false)
    {newest_posts, grid_posts} = split_newest(grid_posts, newest_enabled)

    # Pagination runs over the grid (non-featured, non-latest) posts only. Featured
    # and latest posts are pinned into their own sections shown on page 1 and
    # excluded from the grid, so they never appear twice. `total_count` stays the
    # full published count for the header; `total_pages` is derived from the grid
    # so the pager matches the grid.
    total_count = length(all_posts)
    grid_count = length(grid_posts)
    per_page = max(ctx.per_page, 1)
    total_pages = if grid_count > 0, do: ceil(grid_count / per_page), else: 0
    page = min(ctx.page, max(total_pages, 1))

    posts =
      grid_posts
      |> paginate(page, per_page)
      |> resolve_posts_for_language(ctx.canonical_language)

    featured =
      if page <= 1,
        do: resolve_posts_for_language(featured_posts, ctx.canonical_language),
        else: []

    newest =
      if page <= 1,
        do: resolve_posts_for_language(newest_posts, ctx.canonical_language),
        else: []

    display_name =
      Publishing.translated_group_name(ctx.group, ctx.canonical_language) || ctx.group_slug

    breadcrumbs = [%{label: display_name, url: nil}]

    translations =
      Translations.build_listing_translations(
        ctx.group_slug,
        ctx.canonical_language,
        ctx.all_posts_unfiltered
      )

    {:ok,
     %{
       page_title: display_name,
       group: ctx.group,
       posts: posts,
       featured_posts: featured,
       featured_layout: Map.get(ctx.group, "featured_layout", "hero"),
       featured_style: Map.get(ctx.group, "featured_style", "classic"),
       newest_posts: newest,
       newest_layout: Map.get(ctx.group, "newest_layout", "hero"),
       newest_style: Map.get(ctx.group, "newest_style", "classic"),
       # Group-wide, not page-visible: URL disambiguation (date-only vs
       # date+time) must count same-day posts across every page AND the pinned
       # featured/newest bands — a page-2 render otherwise undercounts a date
       # shared with a pinned or other-page post and emits an ambiguous URL.
       date_counts: PublishingHTML.build_date_counts(all_posts),
       current_language: ctx.canonical_language,
       translations: translations,
       page: page,
       per_page: per_page,
       total_count: total_count,
       total_pages: total_pages,
       breadcrumbs: breadcrumbs
     }}
  end

  # Orders the published posts by effective publish date, newest or oldest first
  # per the group's `listing_sort`. The effective date is post_date/post_time for
  # timestamp-mode posts and the version's published_at for slug-mode posts (which
  # have no post_date) — so a slug-mode blog sorts by when readers saw the post,
  # not by row-creation time. Keys are ISO-8601 strings, which sort chronologically.
  defp sort_listing(posts, "oldest"), do: Enum.sort_by(posts, &listing_sort_key/1, :asc)
  defp sort_listing(posts, _newest), do: Enum.sort_by(posts, &listing_sort_key/1, :desc)

  defp listing_sort_key(post) do
    cond do
      match?(%Date{}, post[:date]) ->
        time =
          case post[:time] do
            %Time{} = t -> Time.to_iso8601(t)
            _ -> "00:00:00"
          end

        Date.to_iso8601(post.date) <> "T" <> time

      is_binary(get_in(post, [:metadata, :published_at])) and post.metadata.published_at != "" ->
        post.metadata.published_at

      true ->
        "0000-01-01T00:00:00"
    end
  end

  # Splits published posts into {featured, regular}, preserving the incoming
  # order within each side (Enum.split_with is stable). When the group has
  # featured display turned off, everything is treated as regular.
  defp partition_featured(posts, false), do: {[], posts}

  defp partition_featured(posts, true) do
    Enum.split_with(posts, &featured_post?/1)
  end

  defp featured_post?(post) do
    case post[:metadata] do
      %{featured: true} -> true
      _ -> false
    end
  end

  # Pulls the chronologically newest post out of the grid for the "Latest"
  # band. Picked by the same effective-date key the listing sorts by, so it is
  # the newest post regardless of the group's listing_sort direction. Runs
  # after partition_featured/2 — a featured newest post stays in the Featured
  # band (more important) and Latest takes the next-newest.
  defp split_newest(posts, false), do: {[], posts}
  defp split_newest([], true), do: {[], []}

  defp split_newest(posts, true) do
    # uuid tie-break: same-second effective dates would otherwise pin
    # whichever post enumerates first in the current sort order, so a sort
    # toggle or cache regen could swap the Latest band between ties.
    newest = Enum.max_by(posts, &{listing_sort_key(&1), &1[:uuid] || ""})
    # List.delete removes by structural equality — safe because post maps
    # carry distinct uuids, so two entries can never be structurally equal.
    {[newest], List.delete(posts, newest)}
  end

  # ============================================================================
  # Per-Language Resolution
  # ============================================================================

  # Resolves listing post metadata (title, excerpt) for the requested language.
  # DB-mode listing maps carry `language_titles` and `language_excerpts` maps
  # so the template shows the correct translation, not just the primary language.
  defp resolve_posts_for_language(posts, language) do
    Enum.map(posts, fn post ->
      resolve_post_for_language(post, language)
    end)
  end

  defp resolve_post_for_language(post, language) do
    lang_titles = post[:language_titles] || %{}
    lang_excerpts = post[:language_excerpts] || %{}
    metadata = post[:metadata] || %{}

    resolved_key = LanguageHelpers.resolve_language_key(language, Map.keys(lang_titles))

    title = Map.get(lang_titles, resolved_key, metadata[:title] || Constants.default_title())
    excerpt = Map.get(lang_excerpts, resolved_key)

    post
    |> Map.update(:metadata, %{title: title}, &Map.put(&1, :title, title))
    |> then(fn p ->
      if excerpt, do: Map.put(p, :content, excerpt), else: p
    end)
  end

  # ============================================================================
  # Filtering Functions
  # ============================================================================

  @doc """
  Filters posts to only include published ones.
  Excludes timestamp-mode posts with a future post_date.
  """
  def filter_published(posts) do
    today = Date.utc_today()

    Enum.filter(posts, fn post ->
      post[:metadata] && post.metadata.status == "published" && not future_post?(post, today)
    end)
  end

  defp future_post?(post, today) do
    post[:mode] in @timestamp_modes and post[:date] != nil and
      Date.compare(post[:date], today) == :gt
  end

  @doc """
  Filter posts to only include those that have matching language content.
  Handles both exact matches and base code matches (e.g., "en" matches "en-US").
  Translation visibility is based on existence only — status comes from the post level.
  """
  def filter_by_exact_language(posts, _group_slug, language) do
    Enum.filter(posts, fn post ->
      available = post[:available_languages] || []
      find_matching_language(language, available) != nil
    end)
  end

  @doc """
  Strict version - only matches exact language, no fallback to base code.
  """
  def filter_by_exact_language_strict(posts, language) do
    Enum.filter(posts, fn post ->
      available = post[:available_languages] || []
      language in available
    end)
  end

  @doc """
  Find a matching language in available languages.
  Handles exact matches and base code matching.
  """
  def find_matching_language(language, available_languages) do
    cond do
      # Direct match
      language in available_languages ->
        language

      # Base code - find a dialect that matches
      Language.base_code?(language) ->
        Language.find_dialect_for_base_in_languages(language, available_languages)

      # Full dialect not found - try base code match
      true ->
        base = DialectMapper.extract_base(language)
        Language.find_dialect_for_base_in_languages(base, available_languages)
    end
  end

  @doc """
  Get the actual language that the fallback matched.
  Used to redirect to the correct URL when requested language has no content.
  """
  def get_fallback_language(requested_language, posts) do
    # Look at the first post to find what language actually matched
    case posts do
      [first_post | _] ->
        find_matching_language(requested_language, first_post.available_languages) ||
          requested_language

      [] ->
        requested_language
    end
  end

  # ============================================================================
  # Pagination
  # ============================================================================

  @doc """
  Paginates a list of posts.
  """
  def paginate(posts, page, per_page) do
    posts
    |> Enum.drop((page - 1) * per_page)
    |> Enum.take(per_page)
  end

  @doc """
  Gets the page number from params.
  """
  def get_page_param(params) do
    case Map.get(params, "page", "1") do
      page when is_binary(page) ->
        case Integer.parse(page) do
          {num, _} when num > 0 -> num
          _ -> 1
        end

      page when is_integer(page) and page > 0 ->
        page

      _ ->
        1
    end
  end

  @doc """
  Gets the posts per page setting.
  """
  def get_per_page_setting do
    value = Settings.get_setting_cached("publishing_posts_per_page")

    case value do
      nil ->
        20

      v when is_binary(v) ->
        case Integer.parse(v) do
          {num, _} when num > 0 -> num
          _ -> 20
        end

      v when is_integer(v) and v > 0 ->
        v

      _ ->
        20
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc """
  Fetches group configuration by slug.
  """
  def fetch_group(group_slug) do
    group_slug = group_slug |> to_string() |> String.trim()

    case Enum.find(Publishing.list_groups(), &group_slug_matches?(&1, group_slug)) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group}
    end
  end

  defp group_slug_matches?(%{"slug" => slug}, target) when is_binary(slug) do
    String.downcase(slug) == String.downcase(target)
  end

  defp group_slug_matches?(_, _), do: false
end
