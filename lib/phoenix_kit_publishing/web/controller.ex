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
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Web.Controller.Fallback
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostRendering
  alias PhoenixKit.Modules.Publishing.Web.Controller.Routing
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  @admin_edit_helper_mod PhoenixKitWeb.AdminEditHelper

  @show_language_switcher_key "publishing_show_language_switcher"

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
    case Listing.render_group_listing(conn, group_slug, language, conn.params) do
      {:ok, assigns} ->
        listing_url = PublishingHTML.group_listing_path(assigns.current_language, group_slug)

        base_url =
          "#{conn.scheme}://#{conn.host}#{if conn.port in [80, 443], do: "", else: ":#{conn.port}"}"

        conn
        |> assign(:page_title, assigns.page_title)
        |> assign(:group, assigns.group)
        |> assign(:posts, assigns.posts)
        |> assign(:current_language, assigns.current_language)
        |> assign_publishing_render_context(assigns.translations)
        |> assign(:page, assigns.page)
        |> assign(:per_page, assigns.per_page)
        |> assign(:total_count, assigns.total_count)
        |> assign(:total_pages, assigns.total_pages)
        |> assign(:breadcrumbs, assigns.breadcrumbs)
        |> assign(:og, %{
          title: assigns.group["name"],
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
        conn
        |> put_status(301)
        |> redirect(to: url)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
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
        |> render(:show)

      {:redirect_301, url} ->
        conn
        |> put_status(301)
        |> redirect(to: url)

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
        |> render(:show)

      {:redirect, url} ->
        redirect(conn, to: url)

      {:redirect_301, url} ->
        conn
        |> put_status(301)
        |> redirect(to: url)

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
    Gettext.put_locale(PhoenixKitWeb.Gettext, language)
  end

  defp build_og_data(conn, post, canonical_url, language) do
    description = Map.get(post.metadata, :description)
    image = PublishingHTML.featured_image_url(post, "large")

    base_url =
      "#{conn.scheme}://#{conn.host}#{if conn.port in [80, 443], do: "", else: ":#{conn.port}"}"

    %{
      title: post.metadata.title,
      description: description,
      image: absolute_url(base_url, image),
      url: absolute_url(base_url, canonical_url),
      locale: og_locale(language),
      type: "article"
    }
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
