defmodule PhoenixKit.Modules.Publishing.Web.Controller.PostRendering do
  @moduledoc """
  Post rendering functionality for the publishing controller.

  Handles rendering individual posts including:
  - Content rendering with caching
  - Versioned post display
  - Date-only URL handling
  - Version dropdown building
  """

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostFetching
  alias PhoenixKit.Modules.Publishing.Web.Controller.SlugResolution
  alias PhoenixKit.Modules.Publishing.Web.Controller.Translations
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML

  @status_published Constants.status_published()
  @public_version_statuses [Constants.status_published(), Constants.status_archived()]

  # Suppress dialyzer false positive for defensive fallback pattern
  @dialyzer {:nowarn_function, render_post_content: 2}

  # ============================================================================
  # Main Rendering Functions
  # ============================================================================

  @doc """
  Renders a post after resolving URL slugs.
  """
  def render_post(conn, group_slug, identifier, language) do
    # For slug mode, resolve URL slug to internal slug first
    # This enables per-language URL slugs and 301 redirects for old slugs
    case SlugResolution.resolve_url_slug(group_slug, identifier, language) do
      {:redirect, redirect_url} ->
        # Old URL slug - 301 redirect to current URL
        {:redirect_301, redirect_url}

      {:ok, resolved_identifier} ->
        render_resolved_post(conn, group_slug, resolved_identifier, language)

      :passthrough ->
        render_resolved_post(conn, group_slug, identifier, language)
    end
  end

  @doc """
  Renders a post after identifier has been resolved.
  """
  def render_resolved_post(conn, group_slug, identifier, language) do
    case PostFetching.fetch_post(group_slug, identifier, language) do
      {:ok, post} ->
        cond do
          not Constants.published?(post.metadata.status) or Constants.scheduled_ahead?(post) ->
            log_404(conn, group_slug, identifier, language, :unpublished)
            {:error, :unpublished}

          # The editor's "Add language" writes {title: "Untitled", content: ""}
          # onto the ACTIVE version — instantly public. An untranslated stub
          # must read as a MISSING translation, not an empty published page:
          # :not_found sends it through the smart fallback (other language →
          # group listing). The primary language can't hit this — publishing
          # requires a real primary title.
          stub_translation?(post) ->
            log_404(conn, group_slug, identifier, language, :not_found)
            {:error, :not_found}

          true ->
            render_published_post(conn, group_slug, post, language)
        end

      {:error, reason} ->
        log_404(conn, group_slug, identifier, language, reason)
        {:error, reason}
    end
  end

  # Same canonical-language check the live path runs: without it,
  # /de/.../v/1 for a version with no German content silently served the
  # fallback language's body at 200 under the German URL.
  defp respond_with_browsable_version(conn, group_slug, post, version, language) do
    canonical_language = Language.get_canonical_url_language_for_post(post.language)
    canonical_url = build_version_url(group_slug, post, canonical_language, version)

    if canonical_redirect?(conn, language, canonical_language, canonical_url) do
      {:redirect_301, canonical_url}
    else
      build_versioned_post_response(group_slug, post, version)
    end
  end

  # An untranslated stub row: default/blank title AND a blank body.
  defp stub_translation?(post) do
    title = get_in(post, [:metadata, :title])
    body = post[:content]

    (title in [nil, ""] or title == Constants.default_title()) and
      (not is_binary(body) or String.trim(body) == "")
  end

  defp render_published_post(conn, group_slug, post, language) do
    canonical_language = Language.get_canonical_url_language_for_post(post.language)
    canonical_url = PublishingHTML.build_post_url(group_slug, post, canonical_language)

    if canonical_redirect?(conn, language, canonical_language, canonical_url) do
      {:redirect_301, canonical_url}
    else
      group = fetch_group(group_slug)
      html_content = render_post_content(post, notes_style: group_notes_style(group))
      group_name = resolve_group_name(group, group_slug, canonical_language)
      translations = Translations.build_translation_links(group_slug, post, canonical_language)
      breadcrumbs = build_breadcrumbs(group_slug, post, canonical_language, group_name)
      version_dropdown = build_version_dropdown(group_slug, post, canonical_language)

      {:ok,
       %{
         page_title: post.metadata.title || Constants.default_title(),
         group_slug: group_slug,
         group: group,
         group_name: group_name,
         post: post,
         html_content: html_content,
         current_language: canonical_language,
         translations: translations,
         breadcrumbs: breadcrumbs,
         version_dropdown: version_dropdown
       }}
    end
  end

  @doc """
  Renders a specific version of a post (for version browsing feature).
  """
  def render_versioned_post(conn, group_slug, url_slug, version, language) do
    internal_slug = SlugResolution.resolve_url_slug_to_internal(group_slug, url_slug, language)

    if post_allows_version_access?(group_slug, internal_slug, language) do
      render_browsable_version(conn, group_slug, internal_slug, version, language)
    else
      {:error, :version_access_disabled}
    end
  end

  defp render_browsable_version(conn, group_slug, internal_slug, version, language) do
    case Publishing.read_post(group_slug, internal_slug, language, version) do
      {:ok, post} ->
        # "Browse older versions" has to mean PREVIOUSLY published, not
        # currently published: publishing a new version archives the one it
        # replaces, so a live-status-only check made every historical URL 404
        # and left the dropdown unable to hold more than the active version.
        # A version that never shipped (plain draft, no published_at) stays
        # private.
        if publicly_browsable_version?(group_slug, post, version) do
          respond_with_browsable_version(conn, group_slug, post, version, language)
        else
          log_404(conn, group_slug, {:slug, internal_slug, version}, language, :unpublished)
          {:error, :unpublished}
        end

      {:error, reason} ->
        log_404(conn, group_slug, {:slug, internal_slug, version}, language, reason)
        {:error, reason}
    end
  end

  # Version history is a window onto a LIVE post's past, and both halves of
  # that sentence have to be checked.
  #
  # `historically_published?/1` alone answered only "did this version ever
  # ship", from the version's own row — which let two kinds of withdrawn
  # content stay readable:
  #
  #   * Take a published post down (unpublish/archive). Its `/v/N` URLs kept
  #     serving the full body: the post has no active version any more, but
  #     the archived row still carries the `published_at` that the check read
  #     as "was public once". Deliberately withdrawing a post has to close
  #     every door, not just the canonical one.
  #   * Give a never-published draft a publish date and set it to Archived —
  #     both writable from an ordinary save, since only `"published"` is
  #     reserved to `publish_version/4`. That forged the same "shipped once"
  #     shape on a version that never shipped at all.
  #
  # So: the post must currently BE published (there is a live version to have
  # history behind), and the requested version must be at or before it. A
  # genuinely superseded version is always older than the one that replaced
  # it; a draft waiting to go out is always newer.
  defp publicly_browsable_version?(group_slug, post, version) do
    {_allow_access, live_version} = get_cached_version_info(group_slug, post)

    is_integer(live_version) and is_integer(version) and version <= live_version and
      historically_published?(post)
  end

  # Published now, or archived after having been published at some point.
  defp historically_published?(%{metadata: metadata}) do
    case Map.get(metadata, :status) do
      @status_published -> true
      "archived" -> Map.get(metadata, :published_at) not in [nil, ""]
      _ -> false
    end
  end

  defp historically_published?(_), do: false

  defp build_versioned_post_response(group_slug, post, version) do
    canonical_language = Language.get_canonical_url_language_for_post(post.language)
    group = fetch_group(group_slug)
    html_content = render_post_content(post, notes_style: group_notes_style(group))
    group_name = resolve_group_name(group, group_slug, canonical_language)

    translations =
      Translations.build_translation_links(group_slug, post, canonical_language, version: version)

    breadcrumbs = build_breadcrumbs(group_slug, post, canonical_language, group_name)
    canonical_url = PublishingHTML.build_post_url(group_slug, post, canonical_language)
    version_dropdown = build_version_dropdown(group_slug, post, canonical_language)

    {_allow_access, live_version} = get_cached_version_info(group_slug, post)

    {:ok,
     %{
       page_title: post.metadata.title || Constants.default_title(),
       group_slug: group_slug,
       group: group,
       group_name: group_name,
       post: post,
       html_content: html_content,
       current_language: canonical_language,
       translations: translations,
       breadcrumbs: breadcrumbs,
       canonical_url: canonical_url,
       is_versioned_view: true,
       is_live_version: version == live_version,
       version: version,
       version_dropdown: version_dropdown
     }}
  end

  @doc """
  Handles date-only URLs (e.g., /group/2025-12-09).
  If only one post exists on that date, render it directly.
  If multiple posts exist, redirect to the first one with time in URL.
  """
  def handle_date_only_url(conn, group_slug, date, language) do
    case Listing.fetch_group(group_slug) do
      {:ok, _group} ->
        handle_date_posts(conn, group_slug, date, language)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_date_posts(conn, group_slug, date, language) do
    case Publishing.list_times_on_date(group_slug, date) do
      [] ->
        render_post(conn, group_slug, {:slug, date}, language)

      [single_time] ->
        render_post(conn, group_slug, {:timestamp, date, single_time}, language)

      [first_time | _rest] ->
        canonical_language = Language.get_canonical_url_language(language)
        redirect_url = build_timestamp_url(group_slug, date, first_time, canonical_language)
        {:redirect, redirect_url}
    end
  end

  # ============================================================================
  # Content Rendering
  # ============================================================================

  @doc """
  Renders post content with caching for published posts.
  Uses Renderer.render_post/2 which caches based on content hash.
  """
  def render_post_content(post, opts \\ []) do
    case Renderer.render_post(post, opts) do
      {:ok, html} ->
        html

      # Fallback to uncached rendering if render_post returns unexpected
      # format. Map.get: bare maps without :group/:language must not raise —
      # render_markdown treats a non-binary tuple element as "no tag links".
      _ ->
        Renderer.render_markdown(post.content,
          tag_links: {Map.get(post, :group), Map.get(post, :language)},
          notes_style: Keyword.get(opts, :notes_style)
        )
    end
  end

  @doc ~S(The group's author-notes display style: "footnotes" or "panel".)
  def group_notes_style(group) when is_map(group),
    do: Map.get(group, "notes_style", Constants.default_notes_style())

  def group_notes_style(_), do: Constants.default_notes_style()

  # ============================================================================
  # Version Dropdown
  # ============================================================================

  @doc """
  Builds version dropdown data for the public post template.
  Returns nil if version access is disabled or only one published version exists.
  Uses listing cache for fast lookups.
  """
  def build_version_dropdown(group_slug, post, language) do
    # Try to get cached data first (sub-microsecond from :persistent_term)
    # The cache stores the live version with all version metadata
    {allow_access, live_version} = get_cached_version_info(group_slug, post)

    version_statuses = Map.get(post, :version_statuses) || %{}
    current_version = Map.get(post, :version, 1)

    if allow_access and version_statuses != %{} do
      # Published now, or archived (i.e. superseded by a later publish) — the
      # same "previously published" rule the versioned route uses. Filtering on
      # the live status alone left the dropdown unable to list anything but the
      # active version, which is the one you're already reading.
      published_versions =
        version_statuses
        |> Enum.filter(fn {_v, status} -> status in @public_version_statuses end)
        |> Enum.map(fn {v, _status} -> v end)
        |> Enum.sort(:desc)

      build_version_dropdown_data(
        published_versions,
        group_slug,
        post,
        language,
        current_version,
        live_version
      )
    else
      nil
    end
  end

  defp build_version_dropdown_data(published_versions, _group_slug, _post, _lang, _current, _live)
       when length(published_versions) <= 1,
       do: nil

  defp build_version_dropdown_data(
         published_versions,
         group_slug,
         post,
         language,
         current_version,
         live_version
       ) do
    versions_with_urls =
      Enum.map(published_versions, fn version ->
        %{
          version: version,
          url: build_version_url(group_slug, post, language, version),
          is_current: version == current_version,
          is_live: version == live_version
        }
      end)

    %{versions: versions_with_urls, current_version: current_version}
  end

  @doc """
  Gets version info from cache (allow_version_access and live_version).
  Falls back to DB reads if cache miss.
  """
  def get_cached_version_info(group_slug, current_post) do
    # Use appropriate cache lookup based on post mode
    cache_result = ListingCache.find_post_by_mode(group_slug, current_post)

    case cache_result do
      {:ok, cached_post} ->
        # Cache stores the live version's metadata
        allow_access = Map.get(cached_post.metadata, :allow_version_access, false)
        live_version = cached_post.version
        {allow_access, live_version}

      {:error, _} ->
        # Cache miss - fall back to DB reads
        post_identifier = get_post_identifier(current_post)

        primary_language = LanguageHelpers.get_primary_language()

        allow_access = get_allow_access_from_db(group_slug, current_post, primary_language)
        live_version = get_live_version_from_db(group_slug, post_identifier)
        {allow_access, live_version}
    end
  end

  defp get_post_identifier(post) do
    post[:uuid] || post.slug
  end

  # Fallback: Gets allow_version_access from DB when cache misses
  defp get_allow_access_from_db(group_slug, current_post, primary_language) do
    if current_post.language == primary_language do
      Map.get(current_post.metadata, :allow_version_access, false)
    else
      post_identifier = get_post_identifier(current_post)

      case Publishing.read_post(group_slug, post_identifier, primary_language, nil) do
        {:ok, primary_post} -> Map.get(primary_post.metadata, :allow_version_access, false)
        {:error, _} -> false
      end
    end
  end

  # Fallback: Gets published version from DB when cache misses
  defp get_live_version_from_db(group_slug, post_identifier) do
    case Publishing.get_published_version(group_slug, post_identifier) do
      {:ok, version} -> version
      {:error, _} -> nil
    end
  end

  @doc """
  Checks if a specific post allows public access to older versions.
  Always reads from the primary language's live version to ensure consistency.
  """
  def post_allows_version_access?(group_slug, post_slug, _language) do
    primary_language = LanguageHelpers.get_primary_language()

    # Read the live version (version: nil means get latest/live)
    case Publishing.read_post(group_slug, post_slug, primary_language, nil) do
      {:ok, post} ->
        Map.get(post.metadata, :allow_version_access, false)

      {:error, _} ->
        # If we can't read the live version, deny access
        false
    end
  end

  # ============================================================================
  # URL Building
  # ============================================================================

  @doc """
  Builds URL for a specific version of a post.
  """
  def build_version_url(group_slug, post, language, version) do
    base_url = PublishingHTML.build_post_url(group_slug, post, language)
    "#{base_url}/v/#{version}"
  end

  @doc """
  Builds a timestamp URL with date and time.
  """
  def build_timestamp_url(group_slug, date, time, language) do
    PublishingHTML.build_public_path_with_time(language, group_slug, date, time)
  end

  # ============================================================================
  # Breadcrumbs
  # ============================================================================

  @doc """
  Builds breadcrumbs for a post page.
  """
  def build_breadcrumbs(group_slug, post, language, group_name) do
    [
      %{label: group_name, url: PublishingHTML.group_listing_path(language, group_slug)},
      %{label: post.metadata.title, url: nil}
    ]
  end

  # Fetches the group's public map once per request — the same map feeds the
  # language-resolved display name here and the controller's per-group display
  # config (assign_group_display_config/2), so post pages don't fetch twice.
  defp fetch_group(group_slug) do
    case Listing.fetch_group(group_slug) do
      {:ok, group} -> group
      {:error, _} -> %{}
    end
  end

  # Post pages show the group name in the breadcrumb and the "Back to …"
  # footer — resolve it in the viewer's language (data["name_i18n"]) the same
  # way the listing does, falling back to the primary name, then the slug.
  defp resolve_group_name(group, group_slug, language) do
    Publishing.translated_group_name(group, language) || group_slug
  end

  # ============================================================================
  # Logging
  # ============================================================================

  # credo:disable-for-lines:10 Credo.Check.Warning.MissingMetadataKeyInLoggerConfig
  defp log_404(conn, group_slug, identifier, language, reason) do
    Logger.info("Publishing 404",
      group_slug: group_slug,
      identifier: inspect(identifier),
      reason: reason,
      language: language,
      user_agent: Plug.Conn.get_req_header(conn, "user-agent") |> List.first(),
      path: conn.request_path
    )
  end

  defp canonical_redirect?(conn, language, canonical_language, canonical_url) do
    (canonical_language != language or
       Language.prefixed_default_language_request?(conn, canonical_language)) and
      not Language.request_matches_canonical_url?(conn, canonical_url)
  end
end
