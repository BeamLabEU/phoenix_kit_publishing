defmodule PhoenixKit.Modules.Publishing.Web.Controller do
  @moduledoc """
  Public post display controller.

  Handles public-facing routes for viewing published posts with multi-language support.

  URL patterns:
    /:language/:group_slug/:post_slug - Slug mode post
    /:language/:group_slug/:date/:time - Timestamp mode post
    /:language/:group_slug - Group listing

  ## Architecture

  This controller delegates to specialized submodules:
  - `Routing` - URL path parsing and segment building
  - `Language` - Language detection and resolution
  - `SlugResolution` - URL slug resolution and redirects
  - `PostFetching` - Post retrieval from cache/database
  - `Listing` - Group listing rendering and pagination
  - `PostRendering` - Post rendering and version handling
  - `Translations` - Translation link building
  - `Fallback` - 404 handling and smart fallback chain
  """

  use PhoenixKitWeb, :controller
  use Gettext, backend: PhoenixKitPublishing.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Comments, as: PublishingComments
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Web.Controller.Fallback
  alias PhoenixKit.Modules.Publishing.Web.Controller.Feed
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostRendering
  alias PhoenixKit.Modules.Publishing.Web.Controller.Routing
  alias PhoenixKit.Modules.Publishing.Views
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  @admin_edit_helper_mod PhoenixKitWeb.AdminEditHelper

  # Phase 2 seam: the `phoenix_kit_og` plugin (PhoenixKitOG) exports `refine_og/4`
  # and gets the final say over the OG map, layering a rendered image on top of the
  # per-post simple override (see build_og_data/4). It's an optional dep and may not
  # be compiled into a given host, so no_warn_undefined keeps the guarded remote
  # call quiet.
  @og_module PhoenixKitOG
  @compile {:no_warn_undefined, PhoenixKitOG}

  @show_language_switcher_key "publishing_show_language_switcher"

  # ============================================================================
  # Plugs
  # ============================================================================

  # Host root layouts build canonical/og:url/hreflang from
  # `conn.assigns.url_path`. LiveView pages get that assign from the
  # `phoenix_kit` on_mount hook; plain-controller renders had no equivalent,
  # so every page served by this controller fell back to the layout's "/"
  # default and canonicalized to the homepage (e.g. hydroforce.ee's /legal
  # pages all pointed their canonical at "/", and Google dropped them as
  # duplicates).
  #
  # `show/2` is this controller's only action, so a module `plug` runs ahead
  # of every render branch below (listing, post, versioned post, date-only,
  # 404 fallback) without needing to touch each one. Only sets the value
  # when absent, mirroring the on_mount hook's semantics of never
  # clobbering an assign a host already set (`Plug.Conn` has no
  # `assign_new/3` — that's a LiveView/Component-only helper).
  plug :assign_url_path

  defp assign_url_path(conn, _opts) do
    if Map.has_key?(conn.assigns, :url_path) do
      conn
    else
      assign(conn, :url_path, conn.request_path)
    end
  end

  # ============================================================================
  # Main Entry Points
  # ============================================================================

  @doc """
  Displays a post, group listing, or all groups overview.

  Path parsing determines which action to take:
  - [] -> Invalid request (no group specified)
  - [group_slug] -> Group listing
  - [group_slug, post_slug] -> Slug mode post
  - [group_slug, date] -> Date-only timestamp (resolves to single post or first post)
  - [group_slug, date, time] -> Timestamp mode post
  """
  def show(conn, %{"language" => language_param} = params) do
    # Detect if 'language' param is actually a language code or a group slug.
    # This allows the same route to work for both single and multi-language setups.
    {language, adjusted_params} = Language.detect_language_or_group(language_param, params)

    conn =
      conn
      |> rewrite_params_after_shift(params, adjusted_params)
      |> assign(:current_language, language)

    set_gettext_locale(language)

    if Publishing.enabled?() and public_enabled?() do
      case Routing.build_segments(adjusted_params) do
        [] ->
          handle_not_found(conn, :invalid_path)

        segments ->
          handle_parsed_path(conn, Routing.parse_path(segments), language)
      end
    else
      handle_not_found(conn, :module_disabled)
    end
  end

  # Fallback for routes without language parameter
  # This handles the non-localized route where :group might actually be a language code
  def show(conn, params) do
    if Publishing.enabled?() and public_enabled?() do
      # Check if the first segment (group) is actually a language with content
      case Language.detect_language_in_group_param(params) do
        {:language_detected, language, adjusted_params} ->
          # First segment was a language code with content - use localized logic
          conn =
            conn
            |> rewrite_params_after_shift(params, adjusted_params)
            |> assign(:current_language, language)

          set_gettext_locale(language)
          handle_request(conn, language, adjusted_params)

        :not_a_language ->
          # First segment is a group slug - use default language
          language = Language.get_default_language()
          conn = assign(conn, :current_language, language)
          set_gettext_locale(language)
          handle_request(conn, language, params)
      end
    else
      handle_not_found(conn, :module_disabled)
    end
  end

  @doc """
  Public comment submission (the dead-view POST form on post pages).

  Guards, in order: module+public on, the group exists and has
  comments_enabled, the comments seam is available, honeypot empty, the
  signed form token is 3s–1day old (bots submit instantly; stale tabs
  re-render), the post uuid belongs to the group's published set, and the
  reader is logged in. Every outcome redirects back to the post (or the
  group listing when the post can't be resolved) with a flash — no JSON,
  no dead ends.
  """
  def create_comment(conn, params) do
    group_slug = params["group"]

    with true <- Publishing.enabled?() and public_enabled?(),
         {:ok, group} <- Publishing.get_group(group_slug),
         true <- Map.get(group, "comments_enabled", false),
         true <- PublishingComments.available?() do
      handle_comment_submission(conn, group, params)
    else
      _ -> handle_not_found(conn, :group_not_found)
    end
  end

  defp handle_comment_submission(conn, group, params) do
    group_slug = group["slug"]
    language = params["language"] || Language.get_default_language()
    post_uuid = params["post_uuid"]

    post =
      Listing.chronological_posts(group_slug, language)
      |> Enum.find(&(&1[:uuid] == post_uuid))

    back_path =
      case post do
        nil -> PublishingHTML.group_listing_path(language, group_slug)
        post -> PublishingHTML.build_post_url(group_slug, post, language) <> "#comments"
      end

    cond do
      is_nil(post) ->
        conn
        |> put_flash(:error, gettext("That post is no longer available."))
        |> redirect(to: PublishingHTML.group_listing_path(language, group_slug))

      # Honeypot: a filled "website" field is a bot — pretend success.
      params["website"] not in [nil, ""] ->
        redirect(conn, to: back_path)

      not comment_token_valid?(conn, params["ft"]) ->
        conn
        |> put_flash(:error, gettext("The form expired — please try again."))
        |> redirect(to: back_path)

      is_nil(current_user_uuid(conn)) ->
        conn
        |> put_flash(:error, gettext("Please log in to comment."))
        |> redirect(to: back_path)

      true ->
        submit_comment(conn, post, params, back_path)
    end
  end

  defp submit_comment(conn, post, params, back_path) do
    content = params["content"] |> to_string() |> String.trim()

    case PublishingComments.create(post[:uuid], current_user_uuid(conn), content) do
      {:ok, _comment} ->
        conn
        |> put_flash(:info, gettext("Comment posted."))
        |> redirect(to: back_path)

      {:error, :empty_comment} ->
        conn
        |> put_flash(:error, gettext("The comment can't be empty."))
        |> redirect(to: back_path)

      {:error, :content_too_long} ->
        conn
        |> put_flash(:error, gettext("That comment is too long."))
        |> redirect(to: back_path)

      {:error, _} ->
        conn
        |> put_flash(:error, gettext("Couldn't post your comment — please try again."))
        |> redirect(to: back_path)
    end
  end

  # 3s minimum (instant submits are bots), 1 day maximum (stale tabs).
  defp comment_token_valid?(conn, token) when is_binary(token) do
    case Phoenix.Token.verify(conn, "pk_pub_comment", token, max_age: 86_400) do
      {:ok, signed_at} -> System.system_time(:second) - signed_at >= 3
      _ -> false
    end
  end

  defp comment_token_valid?(_conn, _), do: false

  defp current_user_uuid(conn) do
    case conn.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

  # When `Language.detect_*` reinterprets which segment is the group and which
  # is the language, downstream code (including the smart-fallback in
  # `Controller.Fallback`) needs to see the corrected `group`/`path` on
  # `conn.params`. Without this, the fallback reads the raw bindings and
  # blames the wrong slug — manifesting as "404 instead of in-group fallback"
  # for URLs like `/<group>/<missing-post>` that happened to match the
  # localized route as `language=<group>, group=<missing-post>`.
  # Same-binding pattern: both heads match the same variable, so this clause
  # fires only when adjusted_params is identical to original_params (no shift).
  defp rewrite_params_after_shift(conn, original_params, original_params), do: conn

  defp rewrite_params_after_shift(conn, _original_params, adjusted_params) do
    # Map.merge preserves all original keys — conn.params["language"] may be
    # stale after a language→group shift. No downstream reader uses it (locale
    # is held in conn.assigns.current_language), so this is intentional.
    %{conn | params: Map.merge(conn.params, adjusted_params)}
  end

  # ============================================================================
  # Request Handlers
  # ============================================================================

  # Handles request after language has been resolved (localized or default)
  defp handle_request(conn, language, params) do
    case Routing.build_segments(params) do
      [] ->
        handle_not_found(conn, :invalid_path)

      segments ->
        handle_parsed_path(conn, Routing.parse_path(segments), language)
    end
  end

  # Dispatches to appropriate handler based on parsed path
  # Checks group exists and is active before serving content
  defp handle_parsed_path(conn, parsed_path, language) do
    group_slug = extract_group_slug(parsed_path)

    if group_slug && group_trashed?(group_slug) do
      handle_not_found(conn, :group_not_found)
    else
      case parsed_path do
        {:listing, group_slug} ->
          handle_group_listing(conn, group_slug, language)

        {:feed, group_slug, scope} ->
          handle_feed(conn, group_slug, language, scope)

        {:category, group_slug, category_slug} ->
          handle_term_archive(conn, group_slug, language, {:category, category_slug})

        {:tag, group_slug, tag} ->
          handle_term_archive(conn, group_slug, language, {:tag, tag})

        {:slug_post, group_slug, post_slug} ->
          handle_post(conn, group_slug, {:slug, post_slug}, language)

        {:timestamp_post, group_slug, date, time} ->
          handle_post(conn, group_slug, {:timestamp, date, time}, language)

        {:date_only_post, group_slug, date} ->
          handle_date_only_url(conn, group_slug, date, language)

        {:versioned_post, group_slug, post_slug, version} ->
          handle_versioned_post(conn, group_slug, post_slug, version, language)

        {:error, reason} ->
          handle_not_found(conn, reason)
      end
    end
  end

  # Suppress dialyzer warning — catch-all is defensive fallback for unexpected route formats
  @dialyzer {:nowarn_function, extract_group_slug: 1}
  defp extract_group_slug({:error, _}), do: nil
  defp extract_group_slug({_, group_slug}), do: group_slug
  defp extract_group_slug({_, group_slug, _}), do: group_slug
  defp extract_group_slug({_, group_slug, _, _}), do: group_slug
  defp extract_group_slug(_), do: nil

  defp group_trashed?(nil), do: false
  defp group_trashed?(group_slug) when not is_binary(group_slug), do: false

  defp group_trashed?(group_slug) do
    case Publishing.get_group(group_slug) do
      {:ok, group} -> group["status"] == "trashed"
      {:error, _} -> false
    end
  end

  # ============================================================================
  # Group Listing Handler
  # ============================================================================

  defp handle_group_listing(conn, group_slug, language) do
    result =
      case search_param(conn) do
        nil -> Listing.render_group_listing(conn, group_slug, language, conn.params)
        query -> Listing.render_search_results(conn, group_slug, language, query, conn.params)
      end

    case result do
      {:ok, assigns} ->
        listing_url = PublishingHTML.group_listing_path(assigns.current_language, group_slug)
        base_url = base_url(conn)

        conn
        |> assign(:page_title, assigns.page_title)
        |> assign(:group, assigns.group)
        |> assign(:posts, assigns.posts)
        |> assign(:featured_posts, assigns.featured_posts)
        |> assign(:featured_layout, assigns.featured_layout)
        |> assign(:featured_style, assigns.featured_style)
        |> assign(:newest_posts, assigns.newest_posts)
        |> assign(:newest_layout, assigns.newest_layout)
        |> assign(:newest_style, assigns.newest_style)
        |> assign(:date_counts, assigns.date_counts)
        |> assign(:current_language, assigns.current_language)
        |> assign_publishing_render_context(assigns.translations)
        |> assign(:page, assigns.page)
        |> assign(:per_page, assigns.per_page)
        |> assign(:total_count, assigns.total_count)
        |> assign(:total_pages, assigns.total_pages)
        |> assign(:breadcrumbs, assigns.breadcrumbs)
        |> assign(:search_query, Map.get(assigns, :search_query))
        |> assign(:og, %{
          # page_title is the language-resolved display name (listing.ex) — keep
          # the social preview in the same language as the visible <h1>/<title>.
          title: assigns.page_title,
          url: base_url <> listing_url,
          locale: og_locale(assigns.current_language),
          type: "website"
        })
        |> maybe_assign_admin_edit(
          Routes.path("/admin/publishing/#{group_slug}"),
          "Edit Blog"
        )
        |> render(:index)

      {:redirect_301, url} ->
        redirect_301(conn, url)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  # ============================================================================
  # Feed Handler
  # ============================================================================

  # RSS 2.0 for a group (scope nil) or a category/tag archive within it. A
  # missing/trashed group, an unknown term, or the feeds kill-switch all 404
  # — a feed URL must never smart-fallback into an HTML redirect (readers
  # would ingest the listing page as a broken feed).
  defp handle_feed(conn, group_slug, language, scope) do
    with true <- PublishingHTML.feeds_enabled?(),
         {:ok, group} <- Publishing.get_group(group_slug),
         {:ok, all_posts, _term_label} <-
           Listing.scoped_chronological_posts(group_slug, language, scope) do
      # date_counts over the WHOLE scoped set, not the 50-item window —
      # a same-day sibling outside the window must still force the
      # time-segment URL form for timestamp items.
      posts = Enum.take(all_posts, feed_item_limit())

      xml =
        Feed.render_rss(group, posts,
          base_url: base_url(conn),
          language: language,
          date_counts: PublishingHTML.build_date_counts(all_posts),
          scope: scope
        )

      conn
      |> put_resp_content_type("application/rss+xml")
      |> send_resp(200, IO.iodata_to_binary(xml))
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(html: PhoenixKitWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  # Category / tag archive: the listing template with the term's posts and a
  # results heading; the Featured/Latest bands are suppressed. An unknown
  # category 404s via the fallback (the group exists, so it redirects to the
  # listing with the "closest match" flash — same policy as a missing post).
  defp handle_term_archive(conn, group_slug, language, term) do
    case Listing.render_term_archive(conn, group_slug, language, term) do
      {:ok, assigns} ->
        listing_url = PublishingHTML.group_listing_path(assigns.current_language, group_slug)
        base_url = base_url(conn)

        conn
        |> assign(:page_title, assigns.page_title)
        |> assign(:group, assigns.group)
        |> assign(:posts, assigns.posts)
        |> assign(:featured_posts, assigns.featured_posts)
        |> assign(:featured_layout, assigns.featured_layout)
        |> assign(:featured_style, assigns.featured_style)
        |> assign(:newest_posts, assigns.newest_posts)
        |> assign(:newest_layout, assigns.newest_layout)
        |> assign(:newest_style, assigns.newest_style)
        |> assign(:date_counts, assigns.date_counts)
        |> assign(:current_language, assigns.current_language)
        |> assign_publishing_render_context(assigns.translations)
        |> assign(:page, assigns.page)
        |> assign(:per_page, assigns.per_page)
        |> assign(:total_count, assigns.total_count)
        |> assign(:total_pages, assigns.total_pages)
        |> assign(:breadcrumbs, assigns.breadcrumbs)
        |> assign(:search_query, nil)
        |> assign(:term_filter, assigns.term_filter)
        |> assign(:og, %{
          title: assigns.page_title,
          url: base_url <> listing_url,
          locale: og_locale(assigns.current_language),
          type: "website"
        })
        |> render(:index)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  # Feeds serve the reader's backlog: one page of the listing is too little
  # (a catch-up reader misses posts), unbounded is abuse-prone. 50 mirrors
  # the common default of major feed generators.
  defp feed_item_limit, do: 50

  # The trimmed, length-capped ?q= search param — nil when absent/blank, so
  # the listing branch only enters search mode on a real query. The 100-char
  # cap bounds the ILIKE pattern a client can make the DB scan for.
  defp search_param(conn) do
    # fetch_query_params (idempotent) rather than conn.params — ?q= is a
    # query param by definition, and a minimal host/test endpoint without
    # Plug.Parsers never merges the query string into conn.params.
    case Plug.Conn.fetch_query_params(conn).query_params["q"] do
      q when is_binary(q) ->
        case String.trim(q) do
          "" -> nil
          trimmed -> String.slice(trimmed, 0, 100)
        end

      _ ->
        nil
    end
  end

  defp base_url(conn) do
    "#{conn.scheme}://#{conn.host}#{if conn.port in [80, 443], do: "", else: ":#{conn.port}"}"
  end

  # ============================================================================
  # Post Handlers
  # ============================================================================

  defp handle_post(conn, group_slug, identifier, language) do
    case PostRendering.render_post(conn, group_slug, identifier, language) do
      {:ok, assigns} ->
        canonical_url =
          PublishingHTML.build_post_url(group_slug, assigns.post, assigns.current_language)

        conn
        |> assign(:page_title, assigns.page_title)
        |> assign(:group_slug, assigns.group_slug)
        |> assign(:group_name, Map.get(assigns, :group_name) || assigns.group_slug)
        |> assign(:post, assigns.post)
        |> assign(:html_content, assigns.html_content)
        |> assign(:current_language, assigns.current_language)
        |> assign_publishing_render_context(assigns.translations)
        |> assign(:breadcrumbs, assigns.breadcrumbs)
        |> assign(:version_dropdown, assigns.version_dropdown)
        |> assign(:og, build_og_data(conn, assigns.post, canonical_url, assigns.current_language))
        |> maybe_assign_admin_edit(
          edit_post_admin_url(group_slug, assigns.post.uuid, assigns.current_language),
          "Edit Post"
        )
        |> assign_group_display_config(Map.get(assigns, :group, %{}))
        |> assign_post_neighbors(
          Map.get(assigns, :group, %{}),
          group_slug,
          assigns.current_language,
          assigns.post
        )
        |> assign_post_categories(Map.get(assigns, :group, %{}), assigns.post)
        |> track_post_view(Map.get(assigns, :group, %{}), assigns.post)
        |> assign_post_comments(Map.get(assigns, :group, %{}), assigns.post)
        |> render(:show)

      {:redirect_301, url} ->
        redirect_301(conn, url)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  defp handle_versioned_post(conn, group_slug, post_slug, version, language) do
    case PostRendering.render_versioned_post(conn, group_slug, post_slug, version, language) do
      {:ok, assigns} ->
        conn
        |> assign(:page_title, assigns.page_title)
        |> assign(:group_slug, assigns.group_slug)
        |> assign(:group_name, Map.get(assigns, :group_name) || assigns.group_slug)
        |> assign(:post, assigns.post)
        |> assign(:html_content, assigns.html_content)
        |> assign(:current_language, assigns.current_language)
        |> assign_publishing_render_context(assigns.translations)
        |> assign(:breadcrumbs, assigns.breadcrumbs)
        |> assign(:canonical_url, assigns.canonical_url)
        |> assign(:is_versioned_view, assigns.is_versioned_view)
        |> assign(:is_live_version, assigns.is_live_version)
        |> assign(:version, assigns.version)
        |> assign(:version_dropdown, assigns.version_dropdown)
        |> assign(
          :og,
          build_og_data(conn, assigns.post, assigns.canonical_url, assigns.current_language)
        )
        |> assign_group_display_config(Map.get(assigns, :group, %{}))
        |> render(:show)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  defp handle_date_only_url(conn, group_slug, date, language) do
    case PostRendering.handle_date_only_url(conn, group_slug, date, language) do
      {:ok, assigns} ->
        canonical_url =
          PublishingHTML.build_post_url(group_slug, assigns.post, assigns.current_language)

        conn
        |> assign(:page_title, assigns.page_title)
        |> assign(:group_slug, assigns.group_slug)
        |> assign(:group_name, Map.get(assigns, :group_name) || assigns.group_slug)
        |> assign(:post, assigns.post)
        |> assign(:html_content, assigns.html_content)
        |> assign(:current_language, assigns.current_language)
        |> assign_publishing_render_context(assigns.translations)
        |> assign(:breadcrumbs, assigns.breadcrumbs)
        |> assign(:version_dropdown, assigns.version_dropdown)
        |> assign(:og, build_og_data(conn, assigns.post, canonical_url, assigns.current_language))
        |> maybe_assign_admin_edit(
          edit_post_admin_url(group_slug, assigns.post.uuid, assigns.current_language),
          "Edit Post"
        )
        |> assign_group_display_config(Map.get(assigns, :group, %{}))
        |> assign_post_neighbors(
          Map.get(assigns, :group, %{}),
          group_slug,
          assigns.current_language,
          assigns.post
        )
        |> assign_post_categories(Map.get(assigns, :group, %{}), assigns.post)
        |> track_post_view(Map.get(assigns, :group, %{}), assigns.post)
        |> assign_post_comments(Map.get(assigns, :group, %{}), assigns.post)
        |> render(:show)

      {:redirect, url} ->
        redirect(conn, to: with_query_string(conn, url))

      {:redirect_301, url} ->
        redirect_301(conn, url)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  defp handle_not_found(conn, reason) do
    case Fallback.handle_not_found(conn, reason) do
      {:redirect_with_flash, path, message} ->
        conn
        |> put_flash(:info, message)
        |> redirect(to: path)

      {:render_404} ->
        conn
        |> put_status(:not_found)
        |> put_view(html: PhoenixKitWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  # ============================================================================
  # Configuration Helpers
  # ============================================================================

  defp public_enabled? do
    Settings.get_boolean_setting("publishing_public_enabled", true)
  end

  defp set_gettext_locale(language) do
    # Sets both: core's backend for host-rendered chrome (error pages, root
    # layout) and this module's own backend for publishing's own strings
    # (e.g. the "%{count} post(s)" counts in HTML.ex).
    Gettext.put_locale(PhoenixKitWeb.Gettext, language)
    Gettext.put_locale(PhoenixKitPublishing.Gettext, language)
  end

  # Issue the canonical 301 while preserving the request's query string — a
  # `?utm_source=…` link that hits a canonical/locale redirect must not have its
  # campaign params stripped.
  defp redirect_301(conn, url) do
    conn
    |> put_status(301)
    |> redirect(to: with_query_string(conn, url))
  end

  defp with_query_string(%{query_string: qs}, url) when is_binary(qs) and qs != "" do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> qs
  end

  defp with_query_string(_conn, url), do: url

  # Resolves the OG map for a post with per-field precedence:
  #
  #   OG module (Phase 2, if installed)  →  per-post simple override  →  derived default
  #
  # The simple per-post override lives in content.data["og"] (per-language) and
  # is surfaced as post.metadata.og by the mapper. Each field falls back
  # independently, so a post can override just the title and inherit the rest.
  defp build_og_data(conn, post, canonical_url, language) do
    og_override = Map.get(post.metadata, :og) || %{}

    base_url =
      "#{conn.scheme}://#{conn.host}#{if conn.port in [80, 443], do: "", else: ":#{conn.port}"}"

    image_meta = og_image_meta(post, og_override)

    og =
      %{
        title: og_override["title"] || post.metadata.title,
        description: og_override["description"] || Map.get(post.metadata, :description),
        image: absolute_url(base_url, image_meta[:url]),
        url: absolute_url(base_url, canonical_url),
        locale: og_locale(language),
        type: "article"
      }
      |> maybe_put(:image_width, image_meta[:width])
      |> maybe_put(:image_height, image_meta[:height])
      |> maybe_put(:image_type, image_meta[:mime_type])

    maybe_refine_og_with_module(og, conn, post, language)
  end

  # Resolves the effective featured image (override UUID > post's own
  # featured_image_uuid > nil) to `%{url, width, height, mime_type}`.
  # The dimensions + mime power the `og:image:*` hint tags that
  # Telegram / Facebook use to render the preview card before they've
  # actually fetched the bytes.
  defp og_image_meta(_post, %{"image_uuid" => uuid}) when is_binary(uuid) and uuid != "" do
    image_meta_for_uuid(uuid)
  end

  defp og_image_meta(post, _og_override) do
    uuid = Map.get(post.metadata, :featured_image_uuid)

    if is_binary(uuid) and uuid != "" do
      image_meta_for_uuid(uuid)
    else
      %{url: nil}
    end
  end

  defp image_meta_for_uuid(uuid) do
    # Prefer `large` — the visible variant on the OG card. Fall back to
    # `original` when large isn't generated. Either way `url` (below) is
    # always set from featured_image_url/2; only width/height/mime_type
    # are absent when neither variant record exists.
    variant = fetch_variant(uuid, "large") || fetch_variant(uuid, "original")
    url = PublishingHTML.featured_image_url(%{metadata: %{featured_image_uuid: uuid}}, "large")

    case variant do
      %{width: w, height: h, mime_type: mime} ->
        %{url: url, width: w, height: h, mime_type: mime}

      _ ->
        %{url: url}
    end
  rescue
    _ -> %{url: nil}
  end

  defp fetch_variant(uuid, variant) do
    Storage.get_file_instance_by_name(uuid, variant)
  rescue
    _ -> nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Phase 2 extension seam: when the `phoenix_kit_og` plugin is installed it gets
  # the final say, layering a rendered OG image on top of the per-post simple
  # override resolved above. Guarded so a host without the (optional) plugin falls
  # back to the override/default map. Mirrors maybe_assign_admin_edit/3.
  defp maybe_refine_og_with_module(og, conn, post, language) do
    mod = @og_module

    if Code.ensure_loaded?(mod) and function_exported?(mod, :refine_og, 4) do
      case mod.refine_og(og, conn, post, language) do
        %{} = refined -> refined
        _ -> og
      end
    else
      og
    end
  rescue
    # OG refinement must never crash a public post page render — keep the
    # per-post override/default result if the module raises.
    _ -> og
  end

  defp absolute_url(_base, nil), do: nil
  defp absolute_url(_base, ""), do: nil

  defp absolute_url(base, url) when is_binary(url) do
    cond do
      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") -> url
      # Protocol-relative (`//cdn/...`) is already absolute — leave it.
      String.starts_with?(url, "//") -> url
      String.starts_with?(url, "/") -> base <> url
      # Bare relative (e.g. a featured-image path like "images/og.png") — treat as
      # site-absolute so we don't emit "https://hostimages/og.png".
      true -> base <> "/" <> url
    end
  end

  defp absolute_url(_base, _url), do: nil

  # OpenGraph wants `language_TERRITORY` (underscore); our locale codes are
  # BCP47-style (`en-US`) or base-only (`ja`). Normalise the separator and
  # leave base-only codes as-is (territory unknown; consumers accept
  # language-only).
  defp og_locale(nil), do: nil
  defp og_locale(code) when is_binary(code), do: String.replace(code, "-", "_")
  defp og_locale(code), do: code

  # The post-page display settings pulled off the group map, with defaults
  # derived from Constants (same source as db_group_to_map, the PublishingGroup
  # accessors, and the GroupSettings spec — no per-layer literals to drift).
  defp post_display_defaults do
    %{
      scrollbar_style: Constants.default_scrollbar_style(),
      scroll_progress_enabled: false,
      scroll_headings_enabled: false,
      show_breadcrumbs: false,
      post_date_position: Constants.default_post_date_position(),
      post_width: Constants.default_post_width(),
      show_featured_image: false,
      show_reading_time: false,
      show_tags: false,
      show_top_back_link: true,
      show_prev_next: false,
      show_categories: false,
      show_view_counts: false
    }
  end

  # View counting + the optional count chip. Recording mutates the session
  # (the dedup marker), so it must run before render. Recording is async —
  # the displayed count may lag the reader's own visit by a beat, which is
  # why the chip hides at zero instead of greeting the first reader with
  # "0 views".
  defp track_post_view(conn, group, post) do
    if Map.get(group, "views_enabled", false) do
      conn = Views.maybe_record_view(conn, post.uuid)

      if Map.get(group, "show_view_counts", false) do
        assign(conn, :view_count, Views.total(post.uuid))
      else
        assign(conn, :view_count, nil)
      end
    else
      assign(conn, :view_count, nil)
    end
  end

  # Comment-thread assigns for the post page: the published thread + a signed
  # time-trap token for the form (a bot that posts instantly fails the age
  # check). Only fetched when the group's comments_enabled is on AND the
  # optional comments module is present+enabled.
  defp assign_post_comments(conn, group, post) do
    if Map.get(group, "comments_enabled", false) and PublishingComments.available?() do
      conn
      |> assign(:comments_enabled, true)
      |> assign(:post_comments, PublishingComments.list(post.uuid))
      |> assign(
        :comment_form_token,
        Phoenix.Token.sign(conn, "pk_pub_comment", System.system_time(:second))
      )
    else
      assign(conn, :comments_enabled, false)
    end
  end

  # The post's categories for the chips row — only fetched when the group
  # shows them.
  defp assign_post_categories(conn, group, post) do
    if Map.get(group, "show_categories", false) do
      assign(conn, :post_categories, Categories.categories_of_post(post.uuid))
    else
      assign(conn, :post_categories, [])
    end
  end

  # Chronological prev/next links for the post page, gated on the group's
  # show_prev_next setting so the (cache-backed) whole-group pass only runs
  # for groups that display the nav. Neighbors are same-group + same-language.
  defp assign_post_neighbors(conn, group, group_slug, language, post) do
    if Map.get(group, "show_prev_next", false) do
      %{newer: newer, older: older, date_counts: date_counts} =
        Listing.neighbor_posts(group_slug, language, post.uuid)

      conn
      |> assign(:newer_post, neighbor_link(newer, group_slug, language, date_counts))
      |> assign(:older_post, neighbor_link(older, group_slug, language, date_counts))
    else
      conn
      |> assign(:newer_post, nil)
      |> assign(:older_post, nil)
    end
  end

  defp neighbor_link(nil, _group_slug, _language, _date_counts), do: nil

  defp neighbor_link(post, group_slug, language, date_counts) do
    %{
      title: get_in(post, [:metadata, :title]) || Constants.default_title(),
      url: PublishingHTML.build_post_url(group_slug, post, language, date_counts)
    }
  end

  # Assigns the group's per-group display config (scrollbar/reading aids plus
  # the post-page presentation toggles) onto the post-page conn so
  # Web.HTML.show/1 can render them. Takes the group map the post-rendering
  # path already fetched (PostRendering.fetch_group/1) — no second fetch. A
  # missing group (%{}) degrades to the safe defaults (native bar, aids off).
  # Only nil falls back — a stored `false` must survive for default-true
  # settings (`||` would silently flip show_top_back_link back on).
  defp assign_group_display_config(conn, group) when is_map(group) do
    Enum.reduce(post_display_defaults(), conn, fn {key, default}, acc ->
      case Map.get(group, Atom.to_string(key)) do
        nil -> assign(acc, key, default)
        value -> assign(acc, key, value)
      end
    end)
  end

  defp maybe_assign_admin_edit(conn, path, label) do
    mod = @admin_edit_helper_mod

    if Code.ensure_loaded?(mod) and function_exported?(mod, :assign_admin_edit, 3) do
      mod.assign_admin_edit(conn, path, label)
    else
      conn
    end
  end

  # Build the admin Edit Post URL with the current public-side language
  # pinned via the `?lang=` query string. Without this, clicking "Edit
  # Post" from a non-default-language public page (e.g. `/sq/group/post`)
  # would open the editor in the default language because the editor LV
  # reads `params["lang"]` for its initial editing language and falls
  # back to default when the param is absent. Carrying `current_language`
  # forward keeps the editor open in the language the user was reading.
  defp edit_post_admin_url(group_slug, post_uuid, current_language) do
    Routes.path(
      "/admin/publishing/#{group_slug}/#{post_uuid}/edit?lang=#{URI.encode_www_form(current_language)}"
    )
  end

  # Expose publishing's per-translation URL list under a publishing-namespaced
  # assign so host root layouts and custom switchers can consume it. The host's
  # own switcher (e.g. core's `<.language_switcher_dropdown>`) reads this via
  # `assigns[:phoenix_kit_publishing_translations]` and uses the per-translation
  # URLs instead of the locale-rewrite default — important for groups with
  # per-language URL slugs where simple locale-rewrite produces wrong URLs.
  #
  # The internal `:translations` assign carries extra fields (`display_code`,
  # and on post routes `enabled`/`known`) that are private to the in-page
  # switcher. We normalise to a fixed 5-field shape at the boundary so the
  # public contract is uniform across listing and post routes.
  #
  # Assigns the render context shared by every public render branch (group
  # listing, post, versioned post, date-only): the raw `:translations` the
  # in-page switcher template reads, the normalized
  # `:phoenix_kit_publishing_translations` host-integration assign, and the
  # `:show_language_switcher` toggle. Extracted so the four branches can't
  # drift on this block (PR #15 follow-up).
  defp assign_publishing_render_context(conn, translations) do
    conn
    |> assign(:translations, translations)
    |> assign_publishing_translations(translations)
    |> assign(:show_language_switcher, show_language_switcher?())
  end

  # `translations` is always a list — `Translations.build_listing_translations/3`
  # and `build_translation_links/4` are the only producers and both return
  # lists unconditionally. No fallback clause: if that contract is ever
  # violated, let it crash so the regression surfaces.
  defp assign_publishing_translations(conn, translations) when is_list(translations) do
    normalized =
      Enum.map(translations, fn t ->
        %{
          code: t.code,
          name: t.name,
          flag: t.flag,
          url: t.url,
          current: t.current
        }
      end)

    assign(conn, :phoenix_kit_publishing_translations, normalized)
  end

  # Read the in-page-switcher toggle. Default `true` preserves the historical
  # behaviour for hosts that haven't flipped the setting.
  defp show_language_switcher? do
    Settings.get_boolean_setting(@show_language_switcher_key, true)
  end
end
