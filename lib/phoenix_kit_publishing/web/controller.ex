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

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Comments, as: PublishingComments
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Views
  alias PhoenixKit.Modules.Publishing.Web.Controller.Fallback
  alias PhoenixKit.Modules.Publishing.Web.Controller.Feed
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostRendering
  alias PhoenixKit.Modules.Publishing.Web.Controller.Routing
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
  reader is logged in. Plain form posts get a flash + redirect back to the
  post (or the group listing when the post can't be resolved); requests
  from the page's fetch enhancement (`x-pk-comment-fetch` header) get a
  JSON verdict instead so the client can swap the thread in place.
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
    # The flash strings below are gettext'd; without this the POST renders
    # them in the default (or a recycled worker's residual) locale while
    # redirecting back to the reader's localized page.
    set_gettext_locale(language)
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
        comment_outcome(
          conn,
          :error,
          gettext("That post is no longer available."),
          PublishingHTML.group_listing_path(language, group_slug)
        )

      # Honeypot: a filled "website" field is a bot — pretend success.
      params["website"] not in [nil, ""] ->
        comment_outcome(conn, :silent, nil, back_path)

      not comment_token_valid?(conn, params["ft"]) ->
        comment_outcome(conn, :error, gettext("The form expired — please try again."), back_path)

      is_nil(current_user_uuid(conn)) ->
        comment_outcome(conn, :error, gettext("Please log in to comment."), back_path)

      true ->
        submit_comment(conn, post, params, back_path)
    end
  end

  # One exit point for every comment-POST outcome. The plain form flow
  # flashes + redirects; the fetch-enhanced flow (x-pk-comment-fetch,
  # set by the page's progressive-enhancement script) gets JSON so the
  # client can swap the thread in place instead of reloading. :silent =
  # the honeypot's pretend-success (no flash, ok to the bot either way).
  defp comment_outcome(conn, kind, message, path) do
    if get_req_header(conn, "x-pk-comment-fetch") != [] do
      case kind do
        :error -> conn |> put_status(422) |> json(%{ok: false, message: message})
        _ -> json(conn, %{ok: true, message: message})
      end
    else
      case kind do
        :silent -> redirect(conn, to: path)
        kind -> conn |> put_flash(kind, message) |> redirect(to: path)
      end
    end
  end

  defp submit_comment(conn, post, params, back_path) do
    content = params["content"] |> to_string() |> String.trim()
    note_id = comment_note_id(params)
    parent_uuid = comment_parent_uuid(params)

    # A note-panel comment redirects back with that panel's :target open;
    # a reply lands on its parent comment. (Error paths use the request's
    # view of the thread; success re-derives from the created comment.)
    back_path = comment_anchor(back_path, note_id, parent_uuid)

    case PublishingComments.create(post[:uuid], current_user_uuid(conn), content,
           parent_uuid: parent_uuid,
           note_id: note_id
         ) do
      {:ok, comment} ->
        # Anchor from the stored truth: a reply INHERITS its parent's
        # note_id, so replying inside a panel must reopen that panel even
        # though the reply form never carried note_id itself.
        success_path =
          comment_anchor(back_path, comment.metadata["note_id"], comment.parent_uuid)

        comment_outcome(conn, :info, comment_posted_message(comment), success_path)

      {:error, reason} ->
        comment_outcome(conn, :error, comment_error_message(reason), back_path)
    end
  end

  defp comment_anchor(path, note_id, _parent_uuid) when is_binary(note_id) and note_id != "",
    do: replace_anchor(path, "pk-note-panel-#{note_id}")

  defp comment_anchor(path, _note_id, parent_uuid) when is_binary(parent_uuid),
    do: replace_anchor(path, "comment-#{parent_uuid}")

  defp comment_anchor(path, _note_id, _parent_uuid), do: path

  # Don't claim "posted" for a row the reader can't see: with the comments
  # module's moderation on, create returns status "pending", and the thread
  # only lists published rows — so a success message followed by no visible
  # comment reads as "the site ate it".
  #
  # A literal, not `Constants.published?/1`: that is the PUBLISHING
  # vocabulary, and its own docs say so — this is the comments module's
  # status on a different table.
  defp comment_posted_message(%{status: "published"}), do: gettext("Comment posted.")

  defp comment_posted_message(_comment),
    do: gettext("Thanks — your comment is awaiting review.")

  defp comment_error_message(:empty_comment), do: gettext("The comment can't be empty.")
  defp comment_error_message(:content_too_long), do: gettext("That comment is too long.")

  defp comment_error_message(:parent_not_found),
    do: gettext("The comment you replied to is no longer available.")

  defp comment_error_message(:max_depth_exceeded),
    do: gettext("This thread is too deep to reply to.")

  defp comment_error_message(_), do: gettext("Couldn't post your comment — please try again.")

  # A note anchor is the url-safe digest Renderer.note_dom_id/1 emits —
  # anything else is a crafted payload and is dropped (the comment then
  # posts as a regular thread comment rather than erroring).
  defp comment_note_id(params) do
    case params["note_id"] do
      note_id when is_binary(note_id) ->
        if Regex.match?(~r/^[A-Za-z0-9_-]{4,32}$/, note_id), do: note_id, else: nil

      _ ->
        nil
    end
  end

  # UUID-cast up front: the value is echoed into the redirect anchor
  # (#comment-<uuid>), so junk must never travel that far.
  defp comment_parent_uuid(params) do
    with parent_uuid when is_binary(parent_uuid) <- params["parent_uuid"],
         {:ok, _} <- Ecto.UUID.cast(parent_uuid) do
      parent_uuid
    else
      _ -> nil
    end
  end

  defp replace_anchor(path, anchor) do
    [base | _] = String.split(path, "#", parts: 2)
    base <> "#" <> anchor
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
      dispatch_parsed_path(conn, parsed_path, language)
    end
  end

  defp dispatch_parsed_path(conn, {:listing, group_slug}, language),
    do: handle_group_listing(conn, group_slug, language)

  defp dispatch_parsed_path(conn, {:feed, group_slug, scope}, language),
    do: handle_feed(conn, group_slug, language, scope)

  defp dispatch_parsed_path(conn, {:category, group_slug, category_slug}, language),
    do: handle_term_archive(conn, group_slug, language, {:category, category_slug})

  defp dispatch_parsed_path(conn, {:tag, group_slug, tag}, language),
    do: handle_term_archive(conn, group_slug, language, {:tag, tag})

  defp dispatch_parsed_path(conn, {:slug_post, group_slug, post_slug}, language),
    do: handle_post(conn, group_slug, {:slug, post_slug}, language)

  defp dispatch_parsed_path(conn, {:timestamp_post, group_slug, date, time}, language),
    do: handle_post(conn, group_slug, {:timestamp, date, time}, language)

  defp dispatch_parsed_path(conn, {:date_only_post, group_slug, date}, language),
    do: handle_date_only_url(conn, group_slug, date, language)

  defp dispatch_parsed_path(conn, {:versioned_post, group_slug, post_slug, version}, language),
    do: handle_versioned_post(conn, group_slug, post_slug, version, language)

  defp dispatch_parsed_path(conn, {:error, reason}, _language),
    do: handle_not_found(conn, reason)

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
          url: canonical_absolute_url(conn, assigns.current_language, listing_url),
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

      # The listing's language fallback (requested language has no posts,
      # another language does) — 302 + flash like the post page's smart
      # fallback, never a cacheable 301.
      {:redirect_with_flash, path, message} ->
        conn
        |> put_flash(:info, message)
        |> redirect(to: path)

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
         :render <- feed_canonical_redirect(conn, group_slug, language, scope),
         {:ok, all_posts, term_label} <-
           Listing.scoped_chronological_posts(group_slug, language, scope) do
      # date_counts over the group's WHOLE published set (all languages, all
      # terms) — never the windowed/scoped list: a same-day sibling outside
      # the window, outside the term, or without this translation must still
      # force the time-segment URL form for timestamp items, because date-URL
      # resolution is group-wide.
      posts = Enum.take(all_posts, feed_item_limit())

      xml =
        Feed.render_rss(group, posts,
          base_url: base_url(conn),
          language: language,
          date_counts: Listing.group_date_counts(group_slug),
          scope: scope,
          # The translated term name — the HTML archive heading shows it;
          # without it the feed's channel title interpolated the raw slug.
          scope_label: term_label
        )

      conn
      |> put_resp_content_type("application/rss+xml")
      |> send_resp(200, IO.iodata_to_binary(xml))
    else
      {:redirect_301, url} ->
        redirect_301(conn, url)

      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(html: PhoenixKitWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  # Canonical-prefix parity for feeds — strictly feed-to-feed (the target is
  # feed_path/3 by construction, never the HTML smart fallback the moduledoc
  # above forbids). Readers follow permanent redirects, and without this the
  # channel's rel="self" link (built canonical) disagreed with the URL that
  # served it.
  defp feed_canonical_redirect(conn, group_slug, language, scope) do
    canonical_language = Language.get_canonical_url_language(language)
    canonical_url = PublishingHTML.feed_path(canonical_language, group_slug, scope)

    if Language.prefixed_default_language_request?(conn, canonical_language) and
         not Language.request_matches_canonical_url?(conn, canonical_url) do
      {:redirect_301, canonical_url}
    else
      :render
    end
  end

  # Category / tag archive: the listing template with the term's posts and a
  # results heading; the Featured/Latest bands are suppressed. An unknown
  # category 404s via the fallback (the group exists, so it redirects to the
  # listing with the "closest match" flash — same policy as a missing post).
  defp handle_term_archive(conn, group_slug, language, term) do
    case Listing.render_term_archive(conn, group_slug, language, term) do
      {:ok, assigns} ->
        # og:url must be THIS archive's URL, not the group listing — the
        # archive is its own canonical page; advertising the listing marked
        # every category/tag archive as a duplicate of the group root.
        listing_url =
          PublishingHTML.term_archive_path(assigns.current_language, group_slug, term)

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

      {:redirect_301, url} ->
        redirect_301(conn, url)

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
        |> assign_post_notes(Map.get(assigns, :group, %{}), assigns.post)
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

      # The canonical-language redirect a versioned URL can now return
      # (respond_with_browsable_version) — without this clause it crashed
      # with a FunctionClauseError instead of redirecting.
      {:redirect_301, url} ->
        redirect_301(conn, url)

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
        |> assign_post_notes(Map.get(assigns, :group, %{}), assigns.post)
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
    #
    # Normalized to the BASE code: catalogue directories are base-coded
    # (priv/gettext/{en,et,fr,it,ru}) and gettext has no dialect fallback, so
    # put_locale("fr-FR") matches nothing and every public string silently
    # renders in English. Full codes reach here on unprefixed default-language
    # requests (language = content_language, e.g. "et-EE") and on
    # multi-dialect canonical languages ("en-GB") — invisible on
    # English-default sites because the msgid fallback IS English.
    locale = LanguageHelpers.url_language_code(language) || language
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Gettext.put_locale(PhoenixKitPublishing.Gettext, locale)
  end

  # Issue the canonical 301 while preserving the request's query string — a
  # `?utm_source=…` link that hits a canonical/locale redirect must not have its
  # campaign params stripped.
  defp redirect_301(conn, url) do
    conn
    |> put_status(301)
    |> redirect(to: with_query_string(conn, url))
  end

  @doc false
  # Public only so the merge rules can be unit-tested without staging a
  # canonical redirect; takes anything with a :query_string.
  def with_query_string(%{query_string: qs}, url) when is_binary(qs) and qs != "" do
    # Whatever the canonical URL already decided stays decided. The listing's
    # canonical carries its own `?page=`, built from this same request, so
    # appending the request's query string wholesale emitted `?page=2&page=2`
    # — one value read, two written, in the URL search engines are told is
    # the real one. Campaign params still ride along; the target just wins
    # any key it names.
    target_keys = url |> URI.parse() |> Map.get(:query) |> decoded_keys()

    extra =
      qs
      |> URI.decode_query()
      |> Enum.reject(fn {key, _} -> key in target_keys end)

    case extra do
      [] -> url
      pairs -> url <> if(target_keys == [], do: "?", else: "&") <> URI.encode_query(pairs)
    end
  end

  def with_query_string(_conn, url), do: url

  defp decoded_keys(nil), do: []
  defp decoded_keys(query), do: query |> URI.decode_query() |> Map.keys()

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
        # Same rule as the listing previews (fa50732): right-language derived
        # text beats the version-level data["description"], which carries no
        # language — otherwise a translated page shares one language's text
        # with every social scraper and the JSON-LD. The version field stays
        # as the last resort when this language has no body to derive from.
        description:
          og_override["description"] || derived_og_description(post) ||
            Map.get(post.metadata, :description),
        image: absolute_url(base_url, image_meta[:url]),
        url: canonical_absolute_url(conn, language, canonical_url),
        locale: og_locale(language),
        type: "article"
      }
      |> maybe_put(:image_width, image_meta[:width])
      |> maybe_put(:image_height, image_meta[:height])
      |> maybe_put(:image_type, image_meta[:mime_type])

    maybe_refine_og_with_module(og, conn, post, language)
  end

  # The per-language og:description default: a plain-text excerpt of the
  # language's own body. nil (not "") when there is nothing to derive, so the
  # caller's `||` chain can fall through to the version-level description.
  defp derived_og_description(post) do
    case PublishingHTML.extract_excerpt(post.content) do
      text when is_binary(text) and text != "" -> String.slice(text, 0, 300)
      _ -> nil
    end
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

  # Multi-domain hosts: canonical/og:url prefer the language's "home" host
  # from the workspace-wide :canonical_host_resolver MFA
  # (`config :phoenix_kit, :canonical_host_resolver, {Mod, :fun}` — called
  # with the page language, returns a host or nil). On the home host the
  # language is that domain's default, so its own locale prefix is stripped.
  # Resolver absent/nil/raising ⇒ legacy behavior (request host).
  defp canonical_absolute_url(conn, language, relative_url) do
    case resolve_canonical_host(language) do
      nil ->
        base_url =
          "#{conn.scheme}://#{conn.host}#{if conn.port in [80, 443], do: "", else: ":#{conn.port}"}"

        absolute_url(base_url, relative_url)

      host ->
        absolute_url("https://#{host}", strip_language_prefix(relative_url, language))
    end
  end

  defp resolve_canonical_host(language) do
    case Application.get_env(:phoenix_kit, :canonical_host_resolver) do
      {mod, fun} -> apply(mod, fun, [language])
      _ -> nil
    end
  rescue
    error ->
      Logger.warning(
        "[Publishing] canonical_host_resolver raised, falling back to request host: " <>
          Exception.message(error)
      )

      nil
  end

  defp strip_language_prefix(url, language) when is_binary(url) and is_binary(language) do
    base = LanguageHelpers.url_language_code(language)

    case String.split(url, "/", parts: 3) do
      ["", ^base] -> "/"
      ["", ^base, rest] -> "/" <> rest
      _ -> url
    end
  end

  defp strip_language_prefix(url, _), do: url

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
      # The post's real note ids, so a comment anchored to a note that no
      # longer exists folds back into the main thread instead of vanishing.
      known_note_ids = Enum.map(conn.assigns[:post_notes] || [], & &1.id)
      page = PublishingComments.for_post_page(post.uuid, known_note_ids)

      conn
      |> assign(:comments_enabled, true)
      |> assign(:post_comments, page.thread)
      |> assign(:post_comment_count, page.count)
      |> assign(:note_comments, page.note_comments)
      |> assign(
        :comment_form_token,
        Phoenix.Token.sign(conn, "pk_pub_comment", System.system_time(:second))
      )
    else
      # Full default set — a host layout referencing these must not
      # KeyError just because commenting is off.
      conn
      |> assign(:comments_enabled, false)
      |> assign(:post_comments, [])
      |> assign(:post_comment_count, 0)
      |> assign(:note_comments, %{})
      |> assign(:comment_form_token, nil)
    end
  end

  # The author notes for the slide-out panels — only extracted when the
  # group renders notes in panel style (the footnotes style keeps them
  # inside the cached body HTML).
  defp assign_post_notes(conn, group, post) do
    if PostRendering.group_notes_style(group) == "panel" do
      assign(conn, :post_notes, Renderer.list_notes(post.content))
    else
      assign(conn, :post_notes, [])
    end
  end

  # The post's categories for the chips row — only fetched when the group
  # shows them.
  #
  # Read off the post map rather than by post uuid, because the map is the
  # version being rendered: someone on `?v=2` sees how v2 was filed, not how
  # the live version is filed today. Resolving uuids to rows is a lookup
  # against the group's category list, which is small and already cached.
  defp assign_post_categories(conn, group, post) do
    if Map.get(group, "show_categories", false) do
      uuids = Map.get(post.metadata || %{}, :category_uuids, [])
      assign(conn, :post_categories, Categories.categories_by_uuids(post.group, uuids))
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
      translations
      # Same rule as the in-page switcher (HTML.build_public_translations):
      # a disabled/legacy language is not publicly routable (RouterDispatch
      # only rewrites enabled locales), so handing its URL to the host's
      # switcher publishes a dead link. Current entry survives as the anchor.
      |> Enum.reject(fn t -> Map.get(t, :enabled) == false and not (t.current || false) end)
      |> Enum.map(fn t ->
        %{
          code: t.code,
          name: t.name,
          flag: t.flag,
          url: t.url,
          current: t.current,
          # Post translations can include legacy/disabled languages — keep the
          # flag so host layouts can exclude them from hreflang. Listing
          # translations are pre-filtered to enabled and default to true.
          enabled: Map.get(t, :enabled, true)
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
