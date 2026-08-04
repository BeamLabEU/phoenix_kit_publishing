defmodule PhoenixKit.Modules.Publishing.Web.Controller.Listing do
  @moduledoc """
  Group listing functionality for the publishing controller.

  Handles rendering post listings with:
  - Language filtering and fallback
  - Pagination
  - Translation link building for listings
  """

  use Gettext, backend: PhoenixKitPublishing.Gettext

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PublishingCategory

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

        # 302 + flash, mirroring the post page's smart fallback — NOT a 301:
        # "this language has no posts" is a content state, and a cached 301
        # would keep bouncing readers after the first translation is added.
        {:redirect_with_flash, fallback_url,
         gettext("No posts in this language yet. Showing closest match.")}

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

  defp resolve_language_posts([], published_posts, _group_slug, language) do
    # Nothing in the requested language (exact or base-dialect). If OTHER
    # languages have published posts, redirect to one of those listings
    # instead of rendering an empty page — the listing twin of the post
    # page's smart fallback. (This branch was dead for a long time: the
    # second filter used to re-run the caller's identical filter, so it
    # always came back empty and every miss rendered the empty listing.)
    case fallback_language_with_content(published_posts, language) do
      nil -> :not_found
      fallback_language -> {:fallback, fallback_language}
    end
  end

  # Picks the language whose listing the fallback redirect targets: the
  # primary language when it has content, else the alphabetically first
  # available language (deterministic — the old first-post rule flipped with
  # sort order). Returns nil when the target's LISTING URL would equal the
  # requested one (`group_listing_path` strips dialects to base codes, so a
  # same-base sibling would 301 to the URL being served — a redirect loop);
  # rendering the empty listing is the safe degenerate answer there.
  defp fallback_language_with_content(published_posts, requested_language) do
    available =
      published_posts
      |> Enum.flat_map(&(&1[:available_languages] || []))
      |> Enum.uniq()

    primary = LanguageHelpers.get_primary_language()

    preferred =
      if primary in available do
        primary
      else
        available |> Enum.sort() |> List.first()
      end

    requested_base = LanguageHelpers.url_language_code(requested_language)

    if preferred && LanguageHelpers.url_language_code(preferred) != requested_base do
      preferred
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
       # date+time) must count same-day posts across every page, the pinned
       # featured/newest bands, AND every language — URL resolution
       # (Posts.list_times_on_date/2) is language-agnostic, so a
       # language-filtered count emits a date-only URL for a date whose
       # same-day sibling merely lacks this translation, and that URL then
       # 302s to the FIRST time on the date: a different post, possibly in a
       # different language.
       date_counts: PublishingHTML.build_date_counts(ctx.published_posts),
       current_language: ctx.canonical_language,
       translations: translations,
       page: page,
       per_page: per_page,
       total_count: total_count,
       total_pages: total_pages,
       breadcrumbs: breadcrumbs
     }}
  end

  @search_limit 50

  @doc """
  Renders the group listing as SEARCH RESULTS for `query`. Falls back to the
  normal listing when the group's `search_enabled` setting is off — a `?q=`
  on a search-disabled group is ignored, not an error. The `:ok` shape
  matches `render_group_index/3` plus `:search_query`, with the
  Featured/Latest bands suppressed and a single results page (capped at 50
  matches, newest first).
  """
  def render_search_results(conn, group_slug, language, query, params) do
    case fetch_group(group_slug) do
      {:ok, group} ->
        if Map.get(group, "search_enabled", false) do
          search_with_canonical_check(conn, group, group_slug, language, query)
        else
          render_group_listing(conn, group_slug, language, params)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Same canonical-prefix 301 the plain listing enforces — search results
  # are indexable HTML with their own og:url, so serving them 200 at a
  # non-canonical prefix is a duplicate-content hole. The consumer's
  # redirect_301 preserves ?q= via with_query_string.
  defp search_with_canonical_check(conn, group, group_slug, language, query) do
    canonical_language = Language.get_canonical_url_language(language)
    canonical_url = PublishingHTML.group_listing_path(canonical_language, group_slug)

    if canonical_redirect?(conn, language, canonical_language, canonical_url) do
      {:redirect_301, canonical_url}
    else
      do_render_search(group, group_slug, language, query)
    end
  end

  defp do_render_search(group, group_slug, language, query) do
    canonical_language = Language.get_canonical_url_language(language)
    {posts, date_counts} = search_posts(group_slug, canonical_language, query)
    display_name = Publishing.translated_group_name(group, canonical_language) || group_slug

    translations =
      Translations.build_listing_translations(
        group_slug,
        canonical_language,
        PostFetching.fetch_posts_with_cache(group_slug)
      )

    {:ok,
     %{
       page_title: display_name,
       group: group,
       posts: posts,
       featured_posts: [],
       featured_layout: Map.get(group, "featured_layout", "hero"),
       featured_style: Map.get(group, "featured_style", "classic"),
       newest_posts: [],
       newest_layout: Map.get(group, "newest_layout", "hero"),
       newest_style: Map.get(group, "newest_style", "classic"),
       date_counts: date_counts,
       current_language: canonical_language,
       translations: translations,
       page: 1,
       per_page: @search_limit,
       total_count: length(posts),
       total_pages: if(posts == [], do: 0, else: 1),
       breadcrumbs: [%{label: display_name, url: nil}],
       search_query: query
     }}
  end

  @doc """
  Search matches for a group's public listing: a DB substring pass (title +
  body of active PUBLISHED versions, candidate languages, ILIKE-escaped)
  intersected with the chronological cache maps — so results carry the same
  resolved titles/URLs/order as the listing. Returns `{posts, date_counts}`,
  the counts computed over the WHOLE published set so a matched timestamp
  post's URL keeps its time segment when non-matched same-day siblings exist.
  """
  # The DB uuid pass is capped far above the visible result count, NOT at it:
  # LIMIT without ORDER BY returns an arbitrary subset, so truncating to 50 in
  # SQL would drop newest matches for high-frequency substrings. The wide cap
  # only bounds abuse; the newest-50 selection happens after the chronological
  # intersect. Known limit: the intersect runs over the listing cache (most
  # recent ~5,000 posts), so matches older than the cache horizon don't
  # surface — same horizon the listing itself has.
  @db_match_cap 2000

  def search_posts(group_slug, language, query) do
    uuids =
      group_slug
      |> DBStorage.search_published_post_uuids(
        language_candidates(language),
        query,
        @db_match_cap
      )
      |> MapSet.new()

    all = chronological_posts(group_slug, language)

    matches =
      all
      |> Enum.filter(&MapSet.member?(uuids, &1[:uuid]))
      |> Enum.take(@search_limit)

    {matches, group_date_counts(group_slug)}
  end

  @doc """
  The date→count map that decides the date-only vs date+time URL form for
  timestamp posts, computed over the group's published set across ALL
  languages — the same basis URL resolution (`Posts.list_times_on_date/2`)
  uses. Never build these counts from a language-filtered list: the card
  would emit a date-only URL whenever the same-day sibling merely lacks the
  viewer's translation, and that URL resolves to a different post.
  """
  def group_date_counts(group_slug) do
    group_slug
    |> PostFetching.fetch_posts_with_cache()
    |> filter_published()
    |> PublishingHTML.build_date_counts()
  end

  # Content-language candidates for the DB search. A full-dialect request
  # ("en-GB") matches that dialect plus a legacy base-code row ONLY — widening
  # to sibling dialects would surface en-US-only matches on the en-GB listing.
  # A base-code request ("en") is the ambiguous form: any enabled dialect of
  # the base can be what the listing resolves to, so all of them qualify.
  defp language_candidates(language) do
    base = LanguageHelpers.url_language_code(language) || language

    if language == base do
      dialects =
        Enum.filter(Publishing.enabled_language_codes(), fn code ->
          LanguageHelpers.url_language_code(code) == base
        end)

      Enum.uniq([base | dialects])
    else
      [language, base]
    end
  rescue
    _ -> [language]
  end

  @doc """
  `chronological_posts/3` narrowed to a term scope: `nil` (whole group),
  `{:category, slug}` (the category AND its descendants — WordPress archive
  rule), or `{:tag, tag}` (case-insensitive tag match). Returns
  `{:ok, posts, label}` where label is the category's translated name (nil
  for the whole group, the raw tag for tags), or `{:error, :not_found}` for
  an unknown category / a tag no published post carries.
  """
  def scoped_chronological_posts(group_slug, language, nil) do
    {:ok, chronological_posts(group_slug, language), nil}
  end

  def scoped_chronological_posts(group_slug, language, {:category, category_slug}) do
    with {:ok, category} <- Categories.by_slug(group_slug, category_slug) do
      subtree = Categories.subtree_uuids(group_slug, category.uuid)

      posts =
        group_slug
        |> chronological_posts(language)
        |> Enum.filter(fn post ->
          Enum.any?(post[:category_uuids] || [], &MapSet.member?(subtree, &1))
        end)

      {:ok, posts, PublishingCategory.translated_name(category, language)}
    end
  end

  def scoped_chronological_posts(group_slug, language, {:tag, tag}) do
    needle = String.downcase(tag)

    posts =
      group_slug
      |> chronological_posts(language)
      |> Enum.filter(fn post ->
        (get_in(post, [:metadata, :tags]) || [])
        |> Enum.any?(&(String.downcase(to_string(&1)) == needle))
      end)

    # A tag exists only through use — an unmatched tag is a 404, not an
    # empty archive (mirrors WordPress).
    if posts == [], do: {:error, :not_found}, else: {:ok, posts, tag}
  end

  @doc """
  Renders a category/tag archive: the listing shape (`render_group_index/3`
  fields) with the term's posts, the bands suppressed, and a `:term_filter`
  map (`%{type:, label:, count:}`) for the heading. Single results page,
  newest first, capped like search.
  """
  def render_term_archive(conn, group_slug, language, term) do
    case fetch_group(group_slug) do
      {:ok, group} ->
        # Canonical-prefix parity with the plain listing (archives are
        # indexable HTML); the consumer preserves the query string. Group
        # existence is checked FIRST so a garbage group 404s without a hop.
        canonical_language = Language.get_canonical_url_language(language)
        canonical_url = PublishingHTML.term_archive_path(canonical_language, group_slug, term)

        if canonical_redirect?(conn, language, canonical_language, canonical_url) do
          {:redirect_301, canonical_url}
        else
          do_render_term_archive(group, group_slug, canonical_language, term)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_render_term_archive(group, group_slug, canonical_language, term) do
    with {:ok, posts, label} <- scoped_chronological_posts(group_slug, canonical_language, term) do
      display_name = Publishing.translated_group_name(group, canonical_language) || group_slug
      {type, raw} = term
      term_label = label || raw

      translations =
        Translations.build_listing_translations(
          group_slug,
          canonical_language,
          PostFetching.fetch_posts_with_cache(group_slug)
        )

      {:ok,
       %{
         page_title: "#{display_name} · #{term_label}",
         group: group,
         posts: Enum.take(posts, @search_limit),
         featured_posts: [],
         featured_layout: Map.get(group, "featured_layout", "hero"),
         featured_style: Map.get(group, "featured_style", "classic"),
         newest_posts: [],
         newest_layout: Map.get(group, "newest_layout", "hero"),
         newest_style: Map.get(group, "newest_style", "classic"),
         # Full-group, all-language counts — a same-day sibling outside this
         # archive (or without this translation) must still force the
         # time-segment URL form for timestamp posts.
         date_counts: group_date_counts(group_slug),
         current_language: canonical_language,
         translations: translations,
         page: 1,
         per_page: @search_limit,
         total_count: length(posts),
         total_pages: if(posts == [], do: 0, else: 1),
         breadcrumbs: [%{label: display_name, url: nil}],
         # `value` is the raw slug/tag (URL identity — feeds, autodiscovery);
         # `label` is the translated display name.
         term_filter: %{type: type, value: raw, label: term_label, count: length(posts)}
       }}
    end
  end

  @doc """
  The group's published posts for the requested language, title/excerpt-resolved
  and sorted newest-first — the shared source for the RSS feed and the post
  page's prev/next navigation. Deliberately independent of the group's
  `listing_sort`: feeds and chronological neighbors always mean "newest first".
  """
  def chronological_posts(group_slug, language, limit \\ nil) do
    posts =
      group_slug
      |> PostFetching.fetch_posts_with_cache()
      |> filter_published()
      |> filter_by_exact_language(group_slug, language)
      |> resolve_posts_for_language(language)
      # uuid tie-break (same rationale as split_newest/2): published_at has
      # second precision, so same-second publishes would otherwise order
      # non-deterministically across cache rebuilds — flipping feed order
      # and swapping prev/next neighbors.
      |> Enum.sort_by(&{listing_sort_key(&1), &1[:uuid] || ""}, :desc)

    if limit, do: Enum.take(posts, limit), else: posts
  end

  @doc """
  The chronological neighbors of a post within its group + language, as
  `%{newer:, older:, date_counts:}` — either neighbor `nil` at the chronology's
  edge (or when the post isn't in the published set, e.g. a draft preview).
  `date_counts` covers the WHOLE published set, so a timestamp neighbor's URL
  correctly includes its time segment when the date has same-day siblings.
  """
  def neighbor_posts(group_slug, language, post_uuid) do
    posts = chronological_posts(group_slug, language)
    date_counts = group_date_counts(group_slug)

    {newer, older} =
      case Enum.find_index(posts, &(&1[:uuid] == post_uuid)) do
        # Sorted newest-first: the entry before is newer, the one after is older.
        nil -> {nil, nil}
        idx -> {if(idx > 0, do: Enum.at(posts, idx - 1)), Enum.at(posts, idx + 1)}
      end

    %{newer: newer, older: older, date_counts: date_counts}
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
    # One settings read for the whole pass — this runs over the listing cache
    # (up to 5,000 entries) on every public request.
    now = Constants.site_now()

    Enum.filter(posts, fn post ->
      post[:metadata] && Constants.published?(post.metadata.status) &&
        not Constants.scheduled_ahead?(post, now)
    end)
  end

  @doc """
  Filter posts to only include those that have matching language content.
  Handles both exact matches and base code matches (e.g., "en" matches "en-US").
  Status comes from the post level; the matched language's CONTENT must also
  be real — the editor's "Add language" creates `{title: "Untitled",
  content: ""}` on the post's active version, which is public the instant it
  commits, so existence-only visibility rendered an Untitled card with an
  empty preview on that language's listing. Real = a non-default title OR a
  non-empty excerpt (a title-only translation still lists).
  """
  def filter_by_exact_language(posts, _group_slug, language) do
    Enum.filter(posts, fn post ->
      available = post[:available_languages] || []

      case find_matching_language(language, available) do
        nil -> false
        matched_key -> matched_content_real?(post, matched_key)
      end
    end)
  end

  defp matched_content_real?(post, key) do
    case post[:language_titles] do
      %{} = titles when is_map_key(titles, key) ->
        title = Map.get(titles, key)
        excerpt = get_in(post, [:language_excerpts, key])

        (title not in [nil, ""] and title != Constants.default_title()) or
          (is_binary(excerpt) and excerpt != "")

      # Maps without per-language titles (minimal fixtures, legacy shapes)
      # keep existence-only semantics.
      _ ->
        true
    end
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

  A full dialect that is itself ENABLED (a real sibling URL like `/en-gb/`)
  never falls back onto a sibling dialect — only onto a literal legacy base
  row (`"en"`). Base-code requests and non-enabled dialect requests keep the
  historical tolerant matching.
  """
  def find_matching_language(language, available_languages) do
    cond do
      # Direct match
      language in available_languages ->
        language

      # Base code - find a dialect that matches
      Language.base_code?(language) ->
        Language.find_dialect_for_base_in_languages(language, available_languages)

      # Full dialect not directly present
      true ->
        match_full_dialect(language, available_languages)
    end
  end

  defp match_full_dialect(language, available_languages) do
    down = String.downcase(language)
    base = DialectMapper.extract_base(language)

    ci_exact = Enum.find(available_languages, &(String.downcase(&1) == down))

    cond do
      ci_exact != nil ->
        ci_exact

      # An enabled sibling URL matches its own row or the legacy base row —
      # never the OTHER sibling (that would list en-US content on /en-gb/).
      Enum.any?(LanguageHelpers.enabled_language_codes(), &(String.downcase(&1) == down)) ->
        if base in available_languages, do: base

      true ->
        Language.find_dialect_for_base_in_languages(base, available_languages)
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
