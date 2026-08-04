defmodule PhoenixKit.Modules.Publishing.Web.Editor do
  @moduledoc """
  Markdown editor for publishing posts.

  This LiveView handles post editing with support for:
  - Collaborative editing (presence tracking, lock management)
  - AI translation
  - Version management
  - Multi-language support
  - Autosave
  - Media selection

  The implementation is split into submodules:
  - Editor.Collaborative - Presence and lock management
  - Editor.Translation - AI translation workflow
  - Editor.Versions - Version switching and creation
  - Editor.Forms - Form building and normalization
  - Editor.Persistence - Save operations
  - Editor.Preview - Preview mode handling
  - Editor.Helpers - Shared utilities
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitPublishing.Gettext

  # Suppress dialyzer warnings for pattern matches
  @dialyzer {:nowarn_function, handle_event: 3}

  # `PhoenixKitOG` is an optional plugin. Every call site is guarded
  # with `Code.ensure_loaded?/1`, but the compiler still warns unless
  # we tell it the symbol is expected to be undefined in that case.
  @compile {:no_warn_undefined, PhoenixKitOG}

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Errors
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Modules.Publishing.SlugHelpers
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language, as: ControllerLanguage
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI, as: AI
  import Leaf, only: [leaf_editor: 1]

  alias PhoenixKit.Modules.Publishing.Hashtags
  alias PhoenixKit.Modules.Publishing.Renderer

  # Submodule aliases
  alias PhoenixKit.Modules.Publishing.Web.Editor.Collaborative
  alias PhoenixKit.Modules.Publishing.Web.Editor.Forms
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers
  alias PhoenixKit.Modules.Publishing.Web.Editor.Persistence
  alias PhoenixKit.Modules.Publishing.Web.Editor.Translation
  alias PhoenixKit.Modules.Publishing.Web.Editor.Versions
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Import publishing-specific components
  import PhoenixKitWeb.Components.LanguageSwitcher
  import PhoenixKit.Modules.Publishing.Web.Components.VersionSwitcher

  require Logger

  # Save quickly — DB writes are ~5ms, no reason to delay
  @autosave_debounce_ms 500

  # ============================================================================
  # Template Helper Delegations
  # ============================================================================

  defdelegate datetime_local_value(value), to: Forms
  defdelegate featured_image_preview_url(value), to: Helpers
  defdelegate format_language_list(codes), to: Helpers

  defdelegate build_editor_languages(post, enabled_languages, current_language),
    to: Helpers

  # JS command for language switching. Skeleton visibility is controlled
  # server-side via @editor_loading assign — the switch_language handler sets
  # it to true (showing skeleton, hiding fields), and handle_params sets it
  # back to false when the new language data is ready.
  defp switch_lang_js(lang_code, current_lang) do
    if lang_code == current_lang do
      %JS{}
    else
      JS.push("switch_language", value: %{language: lang_code})
    end
  end

  # True when the PhoenixKitOG plugin is installed AND the admin has
  # flipped its kill switch on. In that case the editor's OG-image
  # override becomes a fallback — the plugin renders a template-driven
  # image whenever an assignment resolves for this post.
  defp og_module_active? do
    Code.ensure_loaded?(PhoenixKitOG) and
      function_exported?(PhoenixKitOG, :enabled?, 0) and
      PhoenixKitOG.enabled?()
  rescue
    _ -> false
  end

  # Asks the OG plugin to render the current post through whatever
  # template resolves for it, returning a URL — or nil if nothing
  # resolves or the plugin isn't installed. Called from the editor
  # template so the preview updates whenever the post assign changes.
  defp og_preview_url(nil, _language), do: nil

  defp og_preview_url(post, language) do
    if og_module_active?() and function_exported?(PhoenixKitOG, :preview_og_image_url, 3) do
      case PhoenixKitOG.preview_og_image_url(post, nil, language) do
        {:ok, url} -> url
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  # ============================================================================
  # Mount
  # ============================================================================

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"] || params["category"] || params["type"]

    live_source =
      socket.id ||
        "publishing-editor-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    ai_endpoints = Translation.list_ai_endpoints()

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Publishing Editor"))
      |> assign(:group_slug, group_slug)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> assign(:show_media_selector, false)
      |> assign(:autosave_blocked, nil)
      |> assign(:media_selector_target, "featured_image_uuid")
      |> assign(:media_selection_mode, :single)
      |> assign(:media_selected_uuids, MapSet.new())
      |> assign(:featured_image_advanced_open, false)
      |> assign(:og_overrides_open, false)
      |> assign(:is_autosaving, false)
      |> assign(:autosave_timer, nil)
      |> assign(:slug_manually_set, false)
      |> assign(:last_auto_slug, "")
      |> assign(:url_slug_manually_set, false)
      |> assign(:last_auto_url_slug, "")
      |> assign(:slug_truncated, false)
      |> assign(:live_source, live_source)
      |> assign(:form_key, nil)
      |> assign(:lock_owner?, true)
      |> assign(:readonly?, false)
      |> assign(:lock_owner_user, nil)
      |> assign(:spectators, [])
      |> assign(:other_viewers, [])
      |> assign(:last_activity_at, System.monotonic_time(:second))
      |> assign(:lock_expiration_timer, nil)
      |> assign(:lock_warning_shown, false)
      |> assign(:form, %{})
      |> assign(:post, nil)
      |> assign(:content, "")
      |> assign(:group_mode, nil)
      |> assign(:current_language, nil)
      |> assign(:current_language_enabled, true)
      |> assign(:current_language_known, true)
      |> assign(:is_primary_language, true)
      |> assign(:default_language, nil)
      |> assign(:default_language_name, nil)
      |> assign(:available_languages, [])
      |> assign(:all_enabled_languages, [])
      |> Helpers.mark_clean()
      |> assign(:is_new_post, false)
      |> assign(:is_new_translation, false)
      |> assign(:editor_loading, false)
      |> assign(:public_url, nil)
      |> assign(:current_version, nil)
      |> assign(:available_versions, [])
      |> assign(:version_statuses, %{})
      |> assign(:version_dates, %{})
      |> assign(:editing_published_version, false)
      |> assign(:viewing_older_version, false)
      |> assign(:show_new_version_modal, false)
      |> assign(:new_version_source, nil)
      |> assign(:show_slug_conflict_modal, false)
      |> assign(:slug_conflict_info, nil)
      |> assign(:show_ai_translation, false)
      |> assign(:ai_enabled, Code.ensure_loaded?(PhoenixKitAI) and AI.enabled?())
      |> assign(:og_module_active?, og_module_active?())
      |> assign(:ai_endpoints, ai_endpoints)
      |> assign(:ai_selected_endpoint_uuid, Translation.get_default_ai_endpoint_uuid())
      |> assign(:ai_prompts, Translation.list_ai_prompts())
      |> assign(:ai_selected_prompt_uuid, Translation.get_default_ai_prompt_uuid())
      |> assign(:ai_default_prompt_exists, Translation.default_translation_prompt_exists?())
      |> assign(:ai_default_prompt_stale, Translation.default_translation_prompt_stale?())
      |> assign(:ai_translation_status, nil)
      |> assign(:ai_translation_progress, nil)
      |> assign(:ai_translation_total, nil)
      |> assign(:ai_translation_languages, [])
      |> assign(:ai_translation_failures, 0)
      |> assign(:translation_locked?, false)
      |> assign(:translations_in_flight, MapSet.new())
      |> assign(:show_translation_confirm, false)
      |> assign(:pending_translation_languages, [])
      |> assign(:translation_warnings, [])
      |> assign(:show_cancel_confirm, false)
      |> assign(:current_path, Routes.path("/admin/publishing/#{group_slug}/edit"))

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:group_slug] && socket.assigns[:post] && socket.assigns[:lock_owner?] do
      Collaborative.broadcast_editor_activity(socket, :left)
    end

    Collaborative.unsubscribe_from_old_post_topics(socket)
    Collaborative.cancel_lock_expiration_timer(socket)

    :ok
  end

  # ============================================================================
  # Handle Params
  # ============================================================================

  @impl true

  # Match both /admin/publishing/:group/new route AND legacy ?new=true
  def handle_params(params, _uri, %{assigns: %{live_action: :new}} = socket)
      when not is_map_key(params, "preview_token") do
    handle_new_post(socket)
  end

  def handle_params(%{"new" => "true"} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    handle_new_post(socket)
  end

  # UUID-based route: /admin/publishing/:group/:post_uuid/edit
  def handle_params(%{"post_uuid" => post_uuid} = params, uri, socket)
      when not is_map_key(params, "preview_token") do
    socket =
      socket
      |> assign(:endpoint_url, extract_endpoint_url(uri))
      |> reset_translation_state(params)

    handle_uuid_post_params(socket, post_uuid, params)
  end

  def handle_params(%{"path" => path} = params, uri, socket)
      when not is_map_key(params, "preview_token") do
    socket =
      socket
      |> assign(:endpoint_url, extract_endpoint_url(uri))
      |> reset_translation_state(params)

    handle_path_post_params(socket, path, params)
  end

  def handle_params(_params, _uri, socket) do
    # Nothing above matched AND no post is loaded (a bare /:group/edit URL,
    # or a stale preview-token link) — the render dereferences @post, so
    # falling through with nil crashed the LV. Bounce to the group listing.
    if socket.assigns[:post] || socket.assigns[:is_new_post] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Post not found"))
       |> push_navigate(to: Routes.path("/admin/publishing/#{socket.assigns.group_slug}"))}
    end
  end

  # Clear the in-flight translation spinner when (re)loading a post scope. A
  # version or language switch patches through handle_params, but completion
  # events for the PREVIOUS scope are deliberately ignored — so without this
  # the editor would stay locked behind a spinner until a full remount.
  #
  # The lock itself can't be cleared as freely. Switching away from a version
  # the AI is writing and back again used to unlock the editor while the write
  # was still in flight, and whichever save landed last won. So the versions
  # with a translation running are remembered, and returning to one puts its
  # lock back rather than starting fresh.
  defp reset_translation_state(socket, params) do
    socket
    |> assign(
      :translation_locked?,
      translation_running_for?(socket.assigns[:translations_in_flight], params)
    )
    |> assign(:ai_translation_progress, nil)
  end

  @doc false
  # Whether the version these params are switching TO has a translation
  # running. Public so the rule can be pinned without standing up the AI
  # pipeline.
  def translation_running_for?(in_flight, params) do
    scope = params["v"] |> parse_version_param() |> version_scope()

    MapSet.member?(in_flight || MapSet.new(), scope)
  end

  defp version_scope(nil), do: nil
  defp version_scope(version), do: to_string(version)

  # Derive the public-facing origin (scheme://host[:port]) from the current
  # request URI so the edit page can show the same full public URL the post
  # listing does. Mirrors Web.Listing.extract_endpoint_url/1.
  defp extract_endpoint_url(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, port: port}
      when not is_nil(scheme) and not is_nil(host) ->
        port_string = if port in [80, 443], do: "", else: ":#{port}"
        "#{scheme}://#{host}#{port_string}"

      _ ->
        ""
    end
  end

  defp extract_endpoint_url(_), do: ""

  # Resolve a post by UUID but require it to belong to the group in the URL.
  # read_post_by_uuid/3 resolves purely by UUID, so without this the editor would
  # load a post from another group and then validate slug uniqueness against the
  # wrong group — letting it mint duplicate slugs in the real group (M6).
  defp read_post_by_uuid_in_group(post_uuid, group_slug, language, version) do
    case Publishing.read_post_by_uuid(post_uuid, language, version) do
      {:ok, post} ->
        if post[:group] == group_slug, do: {:ok, post}, else: {:error, :wrong_group}

      other ->
        other
    end
  end

  defp handle_uuid_post_params(socket, post_uuid, params) do
    group_slug = socket.assigns.group_slug
    group_mode = Publishing.get_group_mode(group_slug)

    version = parse_version_param(params["v"])
    language = params["lang"]

    case read_post_by_uuid_in_group(post_uuid, group_slug, language, version) do
      {:ok, post} ->
        all_enabled_languages = Publishing.enabled_language_codes()

        old_form_key = socket.assigns[:form_key]

        old_post_slug =
          socket.assigns[:post] && PublishingPubSub.broadcast_id(socket.assigns.post)

        {socket, form_key} =
          if language && new_translation_request?(language, post) do
            handle_new_translation_params(
              socket,
              post,
              group_slug,
              group_mode,
              language,
              all_enabled_languages
            )
          else
            handle_existing_post_params(
              socket,
              post,
              group_slug,
              group_mode,
              nil,
              all_enabled_languages
            )
          end

        socket =
          socket
          |> Collaborative.setup_collaborative_editing(form_key,
            old_form_key: old_form_key,
            old_post_slug: old_post_slug
          )
          |> Translation.maybe_restore_translation_status()
          |> assign(:editor_loading, false)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:editor_loading, false)
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  defp handle_path_post_params(socket, path, params) do
    group_slug = socket.assigns.group_slug
    group_mode = Publishing.get_group_mode(group_slug)

    case Publishing.read_post(group_slug, path) do
      {:ok, post} ->
        all_enabled_languages = Publishing.enabled_language_codes()
        requested_lang = Map.get(params, "lang")

        old_form_key = socket.assigns[:form_key]

        old_post_slug =
          socket.assigns[:post] && PublishingPubSub.broadcast_id(socket.assigns.post)

        {socket, form_key} =
          if requested_lang && new_translation_request?(requested_lang, post) do
            handle_new_translation_params(
              socket,
              post,
              group_slug,
              group_mode,
              requested_lang,
              all_enabled_languages
            )
          else
            handle_existing_post_params(
              socket,
              post,
              group_slug,
              group_mode,
              path,
              all_enabled_languages
            )
          end

        socket =
          socket
          |> Collaborative.setup_collaborative_editing(form_key,
            old_form_key: old_form_key,
            old_post_slug: old_post_slug
          )
          |> Translation.maybe_restore_translation_status()
          |> assign(:editor_loading, false)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:editor_loading, false)
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  defp handle_new_post(socket) do
    group_slug = socket.assigns.group_slug
    group_mode = Publishing.get_group_mode(group_slug)
    all_enabled_languages = Publishing.enabled_language_codes()
    primary_language = Publishing.get_primary_language()

    now = UtilsDate.utc_now() |> DateTime.truncate(:second) |> Forms.floor_datetime_to_minute()
    virtual_post = Helpers.build_virtual_post(group_slug, group_mode, primary_language, now)

    form = Forms.post_form(virtual_post)

    # Socket-scoped: two admins composing NEW posts are two unrelated
    # drafts, but the shared "group:new:lang" key made the second a
    # read-only spectator of the first's unsaved buffer. A new post has no
    # shared identity until it's saved — nothing to collaborate on.
    form_key =
      PublishingPubSub.generate_form_key(group_slug, virtual_post, :new) <> ":" <> socket.id

    old_form_key = socket.assigns[:form_key]
    old_post_slug = socket.assigns[:post] && PublishingPubSub.broadcast_id(socket.assigns.post)

    socket =
      socket
      |> assign(:group_mode, group_mode)
      |> assign(:post, virtual_post)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> Forms.assign_form_with_tracking(form, slug_manually_set: false)
      |> assign(:content, "")
      |> assign(:available_languages, virtual_post.available_languages)
      |> assign(:all_enabled_languages, all_enabled_languages)
      |> Helpers.assign_current_language(primary_language)
      |> assign(:current_path, Helpers.build_new_post_url(group_slug))
      |> Helpers.mark_clean()
      |> assign(:is_new_post, true)
      |> assign(:public_url, nil)
      |> assign(:form_key, form_key)
      |> assign(:current_version, 1)
      |> assign(:available_versions, [])
      |> assign(:version_statuses, %{})
      |> assign(:version_dates, %{})
      |> assign(:editing_published_version, false)
      |> assign(:saved_status, "draft")
      |> push_event("changes-status", %{has_changes: false})

    socket =
      Collaborative.setup_collaborative_editing(socket, form_key,
        old_form_key: old_form_key,
        old_post_slug: old_post_slug
      )

    {:noreply, socket}
  end

  defp parse_version_param(nil), do: nil
  defp parse_version_param(v) when is_integer(v), do: v

  defp parse_version_param(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_version_param(_), do: nil

  # True when two collaborative form keys address the same post AND the same
  # version, differing only in language — the pair that shares version-level
  # fields and therefore has to reload on each other's saves.
  defp same_post_and_version?(key_a, key_b) do
    case {String.split(key_a, ":"), String.split(key_b, ":")} do
      {[group, uuid, version, _lang_a], [group, uuid, version, _lang_b]} ->
        # Only the version-scoped edit key shape ("<group>:<uuid>:v<N>:<lang>").
        # A bare `"v" <> _` prefix test also accepts a language code in that
        # slot ("vi"), which other 4-segment key shapes can carry.
        version_segment?(version)

      _ ->
        false
    end
  end

  defp version_segment?("v" <> number), do: number != "" and String.match?(number, ~r/^\d+$/)
  defp version_segment?(_), do: false

  # Returns true when the requested ?lang= parameter does not resolve to any
  # existing content row on the post — i.e. the editor should open a blank
  # form for adding a new translation. A bare base code that matches one of
  # the post's enabled dialects (e.g. ?lang=en against ["en-GB", "ru"]) is
  # treated as editing the existing dialect, not as a new-translation request.
  defp new_translation_request?(language, %{available_languages: available}) do
    resolved = ControllerLanguage.resolve_language_for_post(language, available)
    down = String.downcase(language)

    cond do
      # Nothing resolvable — definitely new.
      resolved not in available ->
        true

      # Resolved to the exact row (case-insensitively) — existing.
      String.downcase(resolved) == down ->
        false

      # Resolved to the legacy BASE row ("en" for ?lang=en-US) — existing;
      # opening it drives the promote-in-place flow (AGENTS Issue #11).
      resolved == DialectMapper.extract_base(language) ->
        false

      # Resolved to a SIBLING dialect. If the requested code is itself an
      # ENABLED dialect, this is a new-translation request — the old silent
      # bounce made adding the second enabled dialect (en-GB on an
      # en-US-only post) impossible: the blank form self-destructed into
      # the sibling on the very next handle_params pass.
      Enum.any?(LanguageHelpers.enabled_language_codes(), &(String.downcase(&1) == down)) ->
        true

      true ->
        false
    end
  end

  defp handle_new_translation_params(
         socket,
         post,
         group_slug,
         group_mode,
         switch_to_lang,
         all_enabled_languages
       ) do
    current_version = Map.get(post, :version, 1)

    virtual_post =
      post
      |> Map.put(:original_language, post.language)
      |> Map.put(:language, switch_to_lang)
      |> Map.put(:group, group_slug)
      |> Map.put(:content, "")
      |> Map.put(:metadata, Map.put(post.metadata, :title, ""))
      |> Map.put(:mode, post.mode)
      |> Map.put(:slug, post.slug)

    form = Forms.post_form_with_primary_status(group_slug, virtual_post, current_version)
    fk = PublishingPubSub.generate_form_key(group_slug, virtual_post, :edit)

    available_versions = Map.get(post, :available_versions, [])

    sock =
      socket
      |> assign(:group_mode, group_mode)
      |> assign(:post, virtual_post)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> Forms.assign_form_with_tracking(form, slug_manually_set: false)
      |> assign(:content, "")
      |> assign(:available_languages, post.available_languages)
      |> assign(:all_enabled_languages, all_enabled_languages)
      |> Helpers.assign_current_language(switch_to_lang)
      |> assign(
        :current_path,
        Helpers.build_edit_url(group_slug, post,
          lang: switch_to_lang,
          version: current_version
        )
      )
      |> assign(:current_version, current_version)
      |> assign(:available_versions, available_versions)
      |> assign(:version_statuses, Map.get(post, :version_statuses, %{}))
      |> assign(:version_dates, Map.get(post, :version_dates, %{}))
      |> assign(
        :viewing_older_version,
        Versions.viewing_older_version?(current_version, available_versions, switch_to_lang)
      )
      |> Helpers.mark_clean()
      |> assign(:is_new_translation, true)
      |> assign(:public_url, nil)
      |> assign(:form_key, fk)
      |> assign(:saved_status, form["status"])
      |> push_event("changes-status", %{has_changes: false})

    {sock, fk}
  end

  defp handle_existing_post_params(
         socket,
         post,
         group_slug,
         group_mode,
         _path,
         all_enabled_languages
       ) do
    version = Map.get(post, :version, 1)
    form = Forms.post_form_with_primary_status(group_slug, post, version)
    fk = PublishingPubSub.generate_form_key(group_slug, post, :edit)

    is_published = Constants.published?(form["status"])

    sock =
      socket
      |> assign(:group_mode, group_mode)
      |> assign(:post, %{post | group: group_slug})
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> Forms.assign_form_with_tracking(form)
      |> assign(:content, post.content)
      |> assign(:available_languages, post.available_languages)
      |> assign(:all_enabled_languages, all_enabled_languages)
      |> Helpers.assign_current_language(post.language)
      |> assign(
        :current_path,
        Helpers.build_edit_url(group_slug, post, version: version, lang: post.language)
      )
      |> Helpers.mark_clean()
      |> assign(:public_url, Helpers.build_public_url(post, post.language))
      |> assign(:form_key, fk)
      |> assign(:current_version, Map.get(post, :version, 1))
      |> assign(:available_versions, Map.get(post, :available_versions, []))
      |> assign(:version_statuses, Map.get(post, :version_statuses, %{}))
      |> assign(:version_dates, Map.get(post, :version_dates, %{}))
      |> assign(:editing_published_version, is_published)
      |> assign(
        :viewing_older_version,
        Versions.viewing_older_version?(
          Map.get(post, :version, 1),
          Map.get(post, :available_versions, []),
          post.language
        )
      )
      |> assign(:is_new_translation, false)
      |> assign(:saved_status, Map.get(post.metadata, :status, "draft"))
      |> push_event("changes-status", %{has_changes: false})

    {sock, fk}
  end

  # ============================================================================
  # Handle Events - Form Updates
  # ============================================================================

  @impl true
  def handle_event("update_meta", params, socket) do
    socket = maybe_reclaim_lock(socket)

    if socket.assigns.readonly? or socket.assigns.translation_locked? do
      {:noreply, socket}
    else
      # Clear stale flashes up front so a fresh slug-truncation warning set by
      # the slug-update step below survives this render (it used to be wiped by
      # a clear_flash at the END of the handler).
      # Keep :error — an autosave/save failure is the one message the writer
      # must not lose, and this runs on every keystroke.
      socket = clear_flash(socket, :info)
      socket = clear_flash(socket, :warning)
      target = Map.get(params, "_target", [])
      params = prepare_meta_params(params, target, socket)

      new_form =
        socket.assigns.form
        |> Map.merge(params)
        |> Forms.normalize_form()

      {socket_with_slug, new_form, _slug_events} =
        process_slug_updates(socket, params, target, new_form)

      has_changes = Forms.dirty?(socket_with_slug.assigns.post, new_form, socket.assigns.content)

      # Recompute the blocked reason on every edit, not just when a save runs.
      # Otherwise fixing the cause leaves the warning up forever whenever the
      # fix also makes the form clean (retyping the original title): nothing is
      # pending, so no autosave fires, so nothing clears it.
      socket_with_slug =
        assign(socket_with_slug, :autosave_blocked, blocked_reason(socket_with_slug, new_form))

      language = Helpers.editor_language(socket.assigns)

      {updated_post, public_url} =
        update_post_from_form(socket.assigns.post, new_form, language)

      socket =
        assign_meta_updates(
          socket_with_slug,
          new_form,
          updated_post,
          public_url,
          has_changes
        )

      socket = if has_changes, do: schedule_autosave(socket), else: socket

      Collaborative.broadcast_form_change(socket, :meta, new_form)
      socket = Collaborative.touch_activity(socket)

      {:noreply, socket}
    end
  end

  # Takes the lock back after an inactivity lapse. Needed as its OWN event
  # because every editable control is disabled while readonly? is true, so the
  # banner's old "start typing to resume" was impossible to act on.
  def handle_event("resume_editing", _params, socket) do
    socket = Collaborative.try_reclaim_lock(socket)

    if socket.assigns[:readonly?] do
      {:noreply,
       put_flash(
         socket,
         :warning,
         gettext("Someone else is editing this post now — you can still watch.")
       )}
    else
      {:noreply, put_flash(socket, :info, gettext("You're editing again."))}
    end
  end

  def handle_event("regenerate_slug", _params, socket) do
    socket = maybe_reclaim_lock(socket)

    if socket.assigns.group_mode == "slug" and not socket.assigns.readonly? and
         not socket.assigns.translation_locked? do
      title = socket.assigns.form["title"] || ""

      {socket, new_form, _slug_events} =
        Forms.maybe_update_slug_from_title(socket, title, force: true)

      has_changes = Forms.dirty?(socket.assigns.post, new_form, socket.assigns.content)

      # Marking dirty without arming autosave meant the regenerated slug sat
      # unsaved until the writer happened to type elsewhere — the same hole
      # clear_audio had.
      socket =
        socket
        |> assign(:form, new_form)
        |> assign(:has_pending_changes, has_changes)
        |> push_event("changes-status", %{has_changes: has_changes})

      socket = if has_changes, do: schedule_autosave(socket), else: socket
      Collaborative.broadcast_form_change(socket, :meta, new_form)
      socket = Collaborative.touch_activity(socket)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Handle Events - Save
  # ============================================================================

  def handle_event("save", _params, socket) when socket.assigns.readonly? == true do
    socket = maybe_reclaim_lock(socket)

    cond do
      socket.assigns.readonly? ->
        {:noreply, put_flash(socket, :error, gettext("Cannot save - you are spectating"))}

      socket.assigns.translation_locked? ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot save while translation is in progress"))}

      true ->
        Persistence.perform_save(socket)
    end
  end

  def handle_event("save", _params, socket)
      when socket.assigns.translation_locked? == true do
    {:noreply, put_flash(socket, :error, gettext("Cannot save while translation is in progress"))}
  end

  def handle_event("save", _params, socket) do
    Persistence.perform_save(socket)
  rescue
    e ->
      Logger.error("Editor save failed: #{Exception.message(e)}")

      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Something went wrong while saving this post.") <>
           " " <> Errors.truncate_for_log(Exception.message(e), 200)
       )}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("clear_translation", _params, socket) do
    cond do
      # Match every other destructive editor event (save, new_version, etc.):
      # spectators and viewers locked out of the current translation can't
      # mutate. Without this guard a spectator could send this event
      # directly via the socket and hard-delete the translation row.
      socket.assigns[:readonly?] ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to clear translations"))}

      socket.assigns[:translation_locked?] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This translation is currently locked by another editor")
         )}

      true ->
        clear_translation_unguarded(socket)
    end
  end

  # ============================================================================
  # Handle Events - Media
  # ============================================================================

  def handle_event("open_media_selector", params, socket) do
    target = Map.get(params, "field", "featured_image_uuid")

    {:noreply,
     socket
     |> assign(:media_selector_target, target)
     |> assign(:show_media_selector, true)}
  end

  # Clearing writes "" — the same signal the text input sends when emptied by
  # hand — which the save path turns into a real removal (Posts.put_audio_uuid).
  # Delegates to the shared clear pipeline so the clear actually PERSISTS: the
  # first cut only marked the form dirty, so clicking X and then waiting left
  # the field looking empty while the audio was still attached (autosave only
  # ever fires from schedule_autosave/1). It also inherits the lock reclaim,
  # the translation-lock guard, and the live broadcast to other editors.
  def handle_event("clear_audio", _params, socket) do
    clear_image_field(socket, "audio_uuid", gettext("Audio version removed"))
  end

  def handle_event("clear_featured_image", _params, socket),
    do: clear_image_field(socket, "featured_image_uuid", gettext("Featured image cleared"))

  def handle_event("clear_og_image", _params, socket),
    do: clear_image_field(socket, "og_image_uuid", gettext("OG image cleared"))

  # UI-only — open/close state for `<details>` panels. No lock check on purpose;
  # toggling a panel is not an edit and spectators are free to expand/collapse.
  def handle_event("toggle_featured_image_advanced", _params, socket) do
    {:noreply, update(socket, :featured_image_advanced_open, &(!&1))}
  end

  def handle_event("toggle_og_overrides", _params, socket) do
    {:noreply, update(socket, :og_overrides_open, &(!&1))}
  end

  # ============================================================================
  # Handle Events - AI Translation
  # ============================================================================

  def handle_event("toggle_ai_translation", _params, socket) do
    {:noreply, assign(socket, :show_ai_translation, !socket.assigns.show_ai_translation)}
  end

  def handle_event("select_ai_endpoint", %{"endpoint_uuid" => endpoint_uuid}, socket) do
    endpoint_uuid = if endpoint_uuid == "", do: nil, else: endpoint_uuid

    {:noreply, assign(socket, :ai_selected_endpoint_uuid, endpoint_uuid)}
  end

  def handle_event("select_ai_prompt", %{"prompt_uuid" => prompt_uuid}, socket) do
    prompt_uuid = if prompt_uuid == "", do: nil, else: prompt_uuid

    {:noreply, assign(socket, :ai_selected_prompt_uuid, prompt_uuid)}
  end

  # These write the shared default prompt, not this post — but they're edit
  # actions offered inside an editor that is telling the user it's read-only,
  # and the buttons are disabled to match.
  def handle_event("generate_default_translation_prompt", _params, socket)
      when socket.assigns.readonly? == true,
      do: {:noreply, socket}

  def handle_event("regenerate_default_translation_prompt", _params, socket)
      when socket.assigns.readonly? == true,
      do: {:noreply, socket}

  def handle_event("generate_default_translation_prompt", _params, socket) do
    case Translation.generate_default_translation_prompt() do
      {:ok, prompt} ->
        {:noreply,
         socket
         |> assign(:ai_prompts, Translation.list_ai_prompts())
         |> assign(:ai_selected_prompt_uuid, prompt.uuid)
         |> assign(:ai_default_prompt_exists, true)
         |> Phoenix.LiveView.put_flash(:info, gettext("Default translation prompt created"))}

      {:error, changeset} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Couldn't create the default translation prompt.") <>
             " " <> Errors.message(changeset)
         )}
    end
  end

  def handle_event("regenerate_default_translation_prompt", _params, socket) do
    case Translation.regenerate_default_translation_prompt() do
      {:ok, prompt} ->
        {:noreply,
         socket
         |> assign(:ai_prompts, Translation.list_ai_prompts())
         |> assign(:ai_selected_prompt_uuid, prompt.uuid)
         |> assign(:ai_default_prompt_exists, true)
         |> assign(:ai_default_prompt_stale, false)
         |> Phoenix.LiveView.put_flash(:info, gettext("Default translation prompt updated"))}

      {:error, changeset} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Couldn't update the default translation prompt.") <>
             " " <> Errors.message(changeset)
         )}
    end
  end

  def handle_event("translate_to_all_languages", _params, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      target_languages = Translation.get_all_target_languages(socket)
      empty_opts = {:warning, gettext("No other languages enabled to translate to")}
      Translation.enqueue_translation(socket, target_languages, empty_opts)
    end
  end

  def handle_event("translate_missing_languages", _params, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      target_languages = Translation.get_target_languages_for_translation(socket)
      empty_opts = {:info, gettext("All languages already have translations")}
      Translation.enqueue_translation(socket, target_languages, empty_opts)
    end
  end

  def handle_event("translate_to_this_language", _params, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      Translation.start_translation_to_current(socket)
    end
  end

  def handle_event("confirm_translation", _params, socket)
      when socket.assigns.readonly? == true do
    {:noreply, socket}
  end

  def handle_event("confirm_translation", _params, socket) do
    target_languages = socket.assigns.pending_translation_languages

    current_warnings = Translation.build_translation_warnings(socket, target_languages)

    if current_warnings != socket.assigns.translation_warnings do
      {:noreply, assign(socket, :translation_warnings, current_warnings)}
    else
      socket =
        socket
        |> assign(:show_translation_confirm, false)
        |> assign(:pending_translation_languages, [])
        |> assign(:translation_warnings, [])

      Translation.do_enqueue_translation(socket, target_languages)
    end
  end

  def handle_event("cancel_translation", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_translation_confirm, false)
     |> assign(:pending_translation_languages, [])
     |> assign(:translation_warnings, [])}
  end

  # ============================================================================
  # Handle Events - Version Management
  # ============================================================================

  def handle_event("switch_version", %{"version" => version_str}, socket) do
    # Parse defensively — a hand-crafted `?v=abc` would otherwise crash the LV on
    # String.to_integer/1 (L1). parse_version_param/1 returns nil on junk.
    version = parse_version_param(version_str)

    cond do
      is_nil(version) ->
        {:noreply, put_flash(socket, :error, gettext("Version not found"))}

      version == socket.assigns.current_version ->
        {:noreply, socket}

      true ->
        # Flush pending edits BEFORE the switch replaces the buffer, the same
        # way "preview" does. Cancelling the timer alone stopped a wrong-context
        # save but still discarded the work; if the flush can't complete (blank
        # title, slug conflict) we stay put and let the writer see why.
        case flush_before_switch(socket) do
          {:blocked, socket} ->
            {:noreply, socket}

          {:ok, socket} ->
            do_switch_version(socket, version)
        end
    end
  end

  def handle_event("open_new_version_modal", _params, socket) do
    if socket.assigns[:readonly?] or socket.assigns[:is_new_post] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:show_new_version_modal, true)
       |> assign(:new_version_source, nil)}
    end
  end

  def handle_event("close_new_version_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_version_modal, false)
     |> assign(:new_version_source, nil)}
  end

  def handle_event("close_slug_conflict_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_slug_conflict_modal, false)
     |> assign(:slug_conflict_info, nil)}
  end

  def handle_event("set_new_version_source", %{"source" => "blank"}, socket) do
    {:noreply, assign(socket, :new_version_source, nil)}
  end

  def handle_event("set_new_version_source", %{"source" => version_str}, socket)
      when is_binary(version_str) do
    case Integer.parse(version_str) do
      {version, _} -> {:noreply, assign(socket, :new_version_source, version)}
      :error -> {:noreply, socket}
    end
  end

  # Crafted payloads (non-binary source) must not crash the LV.
  def handle_event("set_new_version_source", _params, socket), do: {:noreply, socket}

  def handle_event("create_version_from_source", _params, socket)
      when socket.assigns.readonly? == true do
    {:noreply, socket}
  end

  def handle_event("create_version_from_source", _params, socket) do
    # Creating a version reads PERSISTED state and navigates away, so pending
    # edits would be both excluded from the new version and lost.
    case flush_before_switch(socket) do
      {:blocked, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        case Versions.create_version_from_source(socket) do
          {:ok, socket} -> {:noreply, socket}
          {:error, socket} -> {:noreply, socket}
        end
    end
  end

  # ============================================================================
  # Handle Events - Language Switching
  # ============================================================================

  def handle_event("switch_language", %{"language" => new_language}, socket)
      when is_binary(new_language) do
    if socket.assigns[:is_new_post] do
      {:noreply,
       put_flash(socket, :warning, gettext("Save the post to enable language switching"))}
    else
      # Same policy as the version switch: the language buffer is about to be
      # replaced, so outstanding edits get written first, and a flush that
      # can't complete keeps us here with the reason visible.
      case flush_before_switch(socket) do
        {:blocked, socket} -> {:noreply, socket}
        {:ok, socket} -> do_switch_language(socket, new_language)
      end
    end
  end

  # ============================================================================
  # Handle Events - Navigation
  # ============================================================================

  # Crafted payloads (non-binary language) must not crash the LV.
  def handle_event("switch_language", _params, socket), do: {:noreply, socket}

  def handle_event("preview", _params, socket) do
    # Save first if there are pending changes (autosave is 500ms but user might click fast).
    # Never save for a read-only spectator — they always read has_pending_changes: true
    # after a remote sync, so an unguarded save here would clobber the lock owner's work.
    if socket.assigns.has_pending_changes and not socket.assigns[:readonly?] do
      {:noreply, saved} = Persistence.perform_save(socket)

      # If the save didn't go through (a validation error or the url_slug-conflict
      # modal left changes pending), stay on the editor and show that — don't
      # navigate to a stale preview and silently drop the error/modal (L2).
      if saved.assigns.has_pending_changes do
        {:noreply, saved}
      else
        {:noreply, navigate_to_preview(saved)}
      end
    else
      {:noreply, navigate_to_preview(socket)}
    end
  end

  def handle_event("attempt_cancel", _params, %{assigns: %{has_pending_changes: false}} = socket) do
    handle_event("cancel", %{}, socket)
  end

  def handle_event("attempt_cancel", _params, socket) do
    # Server-rendered confirm (was a JS confirm() via push_event, which broke
    # under CSP / on navigation along with the rest of the inline script).
    {:noreply, assign(socket, :show_cancel_confirm, true)}
  end

  def handle_event("dismiss_cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :show_cancel_confirm, false)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> push_event("changes-status", %{has_changes: false})
     |> push_navigate(to: Routes.path("/admin/publishing/#{socket.assigns.group_slug}"))}
  end

  def handle_event("back_to_list", _params, socket) do
    handle_event("attempt_cancel", %{}, socket)
  end

  defp clear_translation_unguarded(socket) do
    group_slug = socket.assigns.group_slug
    post = socket.assigns.post
    language = socket.assigns.current_language
    post_uuid = post[:uuid]
    # Target the version the editor is actually on, not whatever is newest —
    # otherwise clearing a translation while viewing/editing an older version
    # hard-deletes the language row from the wrong (e.g. live) version.
    version = socket.assigns[:current_version]

    result =
      Publishing.clear_translation(group_slug, post_uuid, language, version,
        actor_uuid: Shared.actor_uuid_from_socket(socket)
      )

    case result do
      :ok ->
        primary_lang = LanguageHelpers.get_primary_language()
        # Keep the VERSION pin — clearing a translation while on draft v2
        # used to navigate without ?v= and silently land back on the live
        # version, abandoning the draft context.
        url = Helpers.build_edit_url(group_slug, post, lang: primary_lang, version: version)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Translation cleared"))
         |> push_navigate(to: url)}

      {:error, :last_language} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot remove the last language from a post"))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Couldn't clear this translation.") <> " " <> Errors.message(reason)
         )}
    end
  end

  # Update post struct with current form values for accurate public URL and status display
  defp update_post_from_form(post, form, language) do
    # Status is version-level — all languages share the same status
    new_status = form["status"]
    available_langs = Map.get(post, :available_languages, [language])
    updated_language_statuses = Map.new(available_langs, fn lang -> {lang, new_status} end)

    form_slug = form["slug"]
    form_url_slug = form["url_slug"]

    updated_post =
      post
      |> Map.put(:metadata, Map.merge(post.metadata, %{status: new_status}))
      |> Map.put(:language_statuses, updated_language_statuses)
      |> then(fn p ->
        if form_slug && form_slug != "", do: Map.put(p, :slug, form_slug), else: p
      end)
      |> Map.put(:url_slug, if(form_url_slug in [nil, ""], do: nil, else: form_url_slug))

    {updated_post, Helpers.build_public_url(updated_post, language)}
  end

  # ============================================================================
  # Helper functions for update_meta to reduce complexity
  # ============================================================================

  defp prepare_meta_params(params, target, socket) do
    params = Map.drop(params, ["_target"])
    params = Forms.preserve_auto_url_slug(params, socket)

    # When typing in the title field, the browser sends stale slug/url_slug values.
    # Preserve the server's current slug to avoid overwriting the auto-generated value.
    if target == ["title"] do
      params
      |> Map.put("slug", socket.assigns.form["slug"] || "")
      |> Map.put("url_slug", socket.assigns.form["url_slug"] || "")
    else
      params
    end
  end

  defp process_slug_updates(socket, params, target, new_form) do
    slug_manually_set =
      if target == ["slug"],
        do: detect_slug_manual_set(params, new_form, socket),
        else: socket.assigns.slug_manually_set

    url_slug_manually_set =
      if target == ["url_slug"],
        do: detect_url_slug_manual_set(params, new_form, socket),
        else: socket.assigns.url_slug_manually_set

    maybe_generate_slug_from_title(
      socket,
      params,
      new_form,
      slug_manually_set,
      url_slug_manually_set
    )
  end

  defp assign_meta_updates(socket, new_form, updated_post, public_url, has_changes) do
    # The regenerated slug rides in `new_form` and renders via the input's
    # `value={@form["slug"]}`, so no client-side slug push is needed.
    socket
    |> assign(:form, new_form)
    |> assign(:post, updated_post)
    |> assign(:slug_manually_set, socket.assigns.slug_manually_set)
    |> assign(:url_slug_manually_set, socket.assigns.url_slug_manually_set)
    |> assign(:has_pending_changes, has_changes)
    |> assign(:public_url, public_url)
    |> push_event("changes-status", %{has_changes: has_changes})
  end

  # ============================================================================
  # Handle Info - Autosave
  # ============================================================================

  @impl true
  def handle_info({:deferred_language_switch, group_slug, target_language}, socket) do
    old_form_key = socket.assigns[:form_key]

    if old_form_key && connected?(socket) do
      alias PhoenixKit.Modules.Publishing.PresenceHelpers
      PresenceHelpers.untrack_editing_session(old_form_key, socket)
      PresenceHelpers.unsubscribe_from_editing(old_form_key)
      PublishingPubSub.unsubscribe_from_editor_form(old_form_key)
    end

    post = socket.assigns.post

    url =
      Helpers.build_edit_url(group_slug, post,
        lang: target_language,
        version: socket.assigns[:current_version]
      )

    {:noreply, push_patch(socket, to: url)}
  end

  @impl true
  def handle_info(:autosave, socket) do
    # A read-only spectator must never autosave — their buffer is stale and would
    # clobber the lock owner's work. translation_locked? alone didn't cover them.
    #
    # Nor while the slug-conflict modal is open: the changes stay pending, so
    # each keystroke rescheduled autosave, which hit the same conflict and
    # re-opened the dialog the writer had just dismissed. They resolve it and
    # save by hand.
    if socket.assigns.has_pending_changes and not socket.assigns.translation_locked? and
         not socket.assigns[:readonly?] and
         not socket.assigns[:show_slug_conflict_modal] do
      socket =
        socket
        |> assign(:is_autosaving, true)
        |> assign(:autosave_timer, nil)
        |> push_event("autosave-status", %{saving: true})

      {:noreply, updated_socket} = Persistence.perform_save(socket)

      {:noreply,
       updated_socket
       |> assign(:is_autosaving, false)
       |> push_event("autosave-status", %{saving: false})}
    else
      {:noreply, assign(socket, :autosave_timer, nil)}
    end
  rescue
    e ->
      Logger.error("[Publishing.Editor] Autosave failed: #{Exception.message(e)}")

      {:noreply,
       socket
       |> assign(:is_autosaving, false)
       |> assign(:autosave_timer, nil)
       |> push_event("autosave-status", %{saving: false})
       |> put_flash(:error, gettext("Autosave failed — click Save to retry"))}
  end

  # ============================================================================
  # Handle Info - Media
  # ============================================================================

  def handle_info({:media_selected, file_uuids}, socket) do
    socket = maybe_reclaim_lock(socket)

    if socket.assigns.readonly? or socket.assigns.translation_locked? do
      {:noreply,
       socket
       |> assign(:show_media_selector, false)
       |> assign(:media_selector_target, "featured_image_uuid")}
    else
      handle_media_selected(socket, file_uuids)
    end
  end

  def handle_info({:media_selector_closed}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, false)
     |> assign(:inserting_image_component, false)
     |> assign(:media_selector_target, "featured_image_uuid")}
  end

  def handle_info({:leaf_changed, %{markdown: content}}, socket) do
    # Ignore local editor changes for read-only spectators: their content arrives
    # via remote sync, and marking pending / scheduling autosave here is a write
    # path that would let a spectator's stale buffer overwrite the lock owner.
    #
    # Typing body text is EDITING, so this has to do the same lock work
    # `update_meta` does. It previously did none of it, which meant a writer
    # working only in the body never refreshed `last_activity_at`: the lock
    # lapsed under them mid-sentence, `readonly?` flipped, and from then on
    # every keystroke was dropped here while "Save" persisted the stale
    # pre-lapse buffer. The lapsed banner even says "Start typing … to resume
    # editing" — the reclaim it promises lives in `maybe_reclaim_lock/1`.
    socket = maybe_reclaim_lock(socket)

    if socket.assigns[:readonly?] or socket.assigns[:translation_locked?] do
      {:noreply, socket}
    else
      has_changes = Forms.dirty?(socket.assigns.post, socket.assigns.form, content)

      socket =
        socket
        |> assign(:content, content)
        |> assign(:has_pending_changes, has_changes)
        |> push_event("changes-status", %{has_changes: has_changes})

      socket = if has_changes, do: schedule_autosave(socket), else: socket

      Collaborative.broadcast_form_change(socket, :content, %{
        content: content,
        form: socket.assigns.form
      })

      socket = Collaborative.touch_activity(socket)

      {:noreply, socket}
    end
  end

  def handle_info({:leaf_insert_request, %{type: :image}}, socket)
      when socket.assigns.readonly? == true,
      do: {:noreply, socket}

  def handle_info({:leaf_insert_request, %{type: :image}}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:inserting_image_component, true)}
  end

  def handle_info({:leaf_insert_request, %{type: :video}}, socket)
      when socket.assigns.readonly? == true,
      do: {:noreply, socket}

  def handle_info({:leaf_insert_request, %{type: :video}}, socket) do
    # Insert the renderer-supported `<Video>` component (the markdown renderer
    # only embeds `<Video ...>`; a bare `![Video](url)` becomes a broken <img>).
    # Matches the image toolbar path and the insert_component/insert_video_component
    # handlers, all of which use component markup.
    # Leaf has no prompt-and-insert command, so ask here and insert the result.
    # (A prompt-less path is better UX and is tracked separately.)
    send_update(Leaf,
      id: "content-editor",
      action: :insert_markdown,
      text: "\n<Video url=\"\">\n  Optional caption text\n</Video>\n"
    )

    {:noreply, socket}
  end

  def handle_info({:leaf_insert_request, _}, socket), do: {:noreply, socket}

  # Mode toggles are the component's own business.
  def handle_info({:leaf_mode_changed, _}, socket), do: {:noreply, socket}

  # A PHK component button. The selected text becomes the component's body
  # where that makes sense — select a phrase, press the note button, and the
  # phrase is what carries the note — so the common case is one gesture
  # rather than "insert, then retype what you already had".
  def handle_info({:leaf_toolbar_action, %{id: id, selection: selection}}, socket) do
    if socket.assigns[:readonly?] or socket.assigns[:translation_locked?] do
      {:noreply, socket}
    else
      selected = Map.get(selection || %{}, :text, "") |> to_string()

      case component_snippet(id, selected) do
        # A gallery with no pictures renders as nothing at all, so a skeleton
        # would look like the button had failed. It opens the picker instead,
        # in multi-select, and arrives already full.
        :pick_audio ->
          {:noreply,
           socket
           |> assign(:media_selection_mode, :single)
           |> assign(:media_selected_uuids, [])
           |> assign(:media_selector_target, "audio_component")
           |> assign(:inserting_audio, true)
           |> assign(:show_media_selector, true)}

        :pick_images ->
          {:noreply,
           socket
           |> assign(:media_selection_mode, :multiple)
           |> assign(:media_selected_uuids, [])
           |> assign(:media_selector_target, "gallery")
           |> assign(:inserting_gallery, true)
           |> assign(:show_media_selector, true)}

        nil ->
          {:noreply, socket}

        text ->
          send_update(Leaf, id: "content-editor", action: :insert_markdown, text: text)
          {:noreply, socket}
      end
    end
  end

  def handle_info({:leaf_toolbar_action, _}, socket), do: {:noreply, socket}

  # The category picker changed the selection. It's a LiveComponent, so it
  # can't write the parent's form itself — and the form is where this has to
  # land, because that is what makes it dirty-tracked, autosaved, broadcast
  # to watchers and written by the same save as everything else on the
  # version. Same pipeline as `update_meta`, minus the slug/title machinery
  # that doesn't apply.
  def handle_info({:categories_changed, uuids}, socket) do
    socket = maybe_reclaim_lock(socket)

    if socket.assigns.readonly? or socket.assigns.translation_locked? do
      {:noreply, socket}
    else
      new_form =
        socket.assigns.form
        |> Map.put("category_uuids", uuids)
        |> Forms.normalize_form()

      has_changes = Forms.dirty?(socket.assigns.post, new_form, socket.assigns.content)

      socket =
        socket
        |> Forms.assign_form_with_tracking(new_form)
        |> assign(:has_pending_changes, has_changes)
        |> assign(:autosave_blocked, blocked_reason(socket, new_form))
        |> push_event("changes-status", %{has_changes: has_changes})

      socket = if has_changes, do: schedule_autosave(socket), else: socket

      Collaborative.broadcast_form_change(socket, :meta, new_form)
      socket = Collaborative.touch_activity(socket)

      {:noreply, socket}
    end
  end

  # `#` in the body opens the tag popup. Answering is optional by contract —
  # a host that stays silent just gets a spinner that closes itself — so this
  # degrades rather than blocking the writer.
  def handle_info({:leaf_suggest, %{trigger: "#", query: query, seq: seq}}, socket) do
    results =
      socket.assigns.group_slug
      |> Hashtags.suggest(query, limit: 10)
      |> Enum.map(fn %{tag: tag, count: count} ->
        %{
          value: tag,
          label: "#" <> tag,
          sublabel: ngettext("%{count} post", "%{count} posts", count),
          icon: "hero-hashtag"
        }
      end)

    # trigger/query/seq echo back unchanged: the client drops replies a later
    # keystroke already superseded.
    send_update(Leaf,
      id: "content-editor",
      action: :suggestions,
      trigger: "#",
      query: query,
      seq: seq,
      results: results
    )

    {:noreply, socket}
  end

  def handle_info({:leaf_suggest, _}, socket), do: {:noreply, socket}
  # The editor component's own Save button. Publishing hides it today
  # (show_save_button defaults false), so this was a no-op — meaning the day
  # anyone enables that button they'd ship a Save that does nothing. Wire it to
  # the same path the toolbar Save uses.
  def handle_info({:leaf_save_requested, _}, socket) do
    if socket.assigns[:readonly?] or socket.assigns[:translation_locked?] do
      {:noreply, socket}
    else
      Persistence.perform_save(socket)
    end
  end

  # ============================================================================
  # Handle Info - Collaborative Editing
  # ============================================================================

  def handle_info({:editor_saved, form_key, source}, socket) do
    cond do
      socket.assigns.form_key == nil ->
        {:noreply, socket}

      source == socket.id ->
        {:noreply, socket}

      form_key == socket.assigns.form_key ->
        {:noreply, Persistence.reload_post(socket)}

      true ->
        {:noreply, socket}
    end
  end

  # A SIBLING language of the same post+version saved (mirrored onto the post's
  # translations topic). The version-level fields (categories/featured/
  # published_at/audio/…) are SHARED across languages and written wholesale on
  # every save — without this reload, this tab's stale copies silently reverted
  # the sibling editor's changes on its next autosave (categories dropped,
  # published_at — and so a timestamp post's public URL — snapped back).
  # reload_post is pending-work-safe: it keeps local edits and warns instead of
  # clobbering.
  def handle_info({:sibling_editor_saved, form_key, source}, socket) do
    if socket.assigns[:form_key] != nil and source != socket.id and
         form_key != socket.assigns.form_key and
         same_post_and_version?(form_key, socket.assigns.form_key) do
      {:noreply, Persistence.reload_post(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    if socket.assigns[:form_key] do
      form_key = socket.assigns.form_key
      was_owner = socket.assigns[:lock_owner?]

      socket = Collaborative.assign_editing_role(socket, form_key)

      if !was_owner && socket.assigns[:lock_owner?] do
        socket = reload_post_on_lock_acquired(socket)
        Collaborative.broadcast_editor_activity(socket, :joined)

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:editor_sync_request, form_key, requester_socket_id}, socket) do
    if socket.assigns[:form_key] == form_key && socket.assigns[:lock_owner?] do
      state = %{
        form: socket.assigns.form,
        content: socket.assigns.content
      }

      PublishingPubSub.broadcast_editor_sync_response(form_key, requester_socket_id, state)
    end

    {:noreply, socket}
  end

  def handle_info({:editor_sync_response, form_key, requester_socket_id, state}, socket) do
    if socket.assigns[:form_key] == form_key &&
         requester_socket_id == socket.id &&
         socket.assigns.readonly? do
      socket = Collaborative.apply_remote_form_state(socket, state)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:editor_form_change, form_key, payload, source}, socket) do
    cond do
      socket.assigns[:form_key] != form_key ->
        {:noreply, socket}

      source == socket.id ->
        {:noreply, socket}

      socket.assigns[:readonly?] != true ->
        {:noreply, socket}

      true ->
        socket = Collaborative.apply_remote_form_change(socket, payload)
        {:noreply, socket}
    end
  end

  # ============================================================================
  # Handle Info - Translation Events
  # ============================================================================

  def handle_info(
        {:translation_started, group_slug, post_identifier, target_languages, scope},
        socket
      ) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) &&
         scope == current_version_scope(socket) do
      current_lang = socket.assigns[:current_language]
      source_lang = source_language_for_translation(socket)
      should_lock = current_lang == source_lang or current_lang in target_languages

      {:noreply,
       socket
       |> assign(:ai_translation_status, :in_progress)
       |> assign(:ai_translation_progress, 0)
       |> assign(:ai_translation_total, length(target_languages))
       |> assign(:ai_translation_languages, target_languages)
       |> assign(:ai_translation_failures, 0)
       |> assign(:translation_locked?, should_lock)
       |> track_translation_in_flight(should_lock)}
    else
      {:noreply, socket}
    end
  end

  # Per-language success from PhoenixKitAI's generic pipeline. Each parallel job
  # broadcasts on this post's translations topic (AITranslatable.pubsub_topics/1),
  # so we count completions toward the progress bar the :translation_started
  # event primed.
  def handle_info(
        {:ai_translation, :translation_completed, %{resource_uuid: resource_uuid} = payload},
        socket
      ) do
    if ai_event_for_this_post?(socket, resource_uuid, Map.get(payload, :resource_scope)) do
      {:noreply, socket |> bump_translation_progress() |> maybe_finalize_translation()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:ai_translation, :translation_failed, %{resource_uuid: resource_uuid} = payload},
        socket
      ) do
    if ai_event_for_this_post?(socket, resource_uuid, Map.get(payload, :resource_scope)) do
      socket =
        socket
        |> bump_translation_progress()
        |> bump_translation_failures()
        |> maybe_finalize_translation()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Other generic lifecycle events (per-language :translation_started, etc.)
  # need no handling — :translation_started above already primed the UI, and
  # the per-language content row refresh rides publishing's :translation_created.
  def handle_info({:ai_translation, _event, _payload}, socket), do: {:noreply, socket}

  def handle_info({:translation_created, group_slug, post_identifier, language, version}, socket) do
    # Only refresh when the new language landed on the version this editor is
    # viewing — a different version's per-language content is independent.
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) &&
         version == current_version_scope(socket) do
      {:noreply, handle_translation_created_update(socket, language)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:translation_deleted, group_slug, post_identifier, language, version}, socket) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) &&
         (is_nil(version) or version == current_version_scope(socket)) do
      available = socket.assigns[:available_languages] || []
      updated_available = List.delete(available, language)

      socket =
        socket
        |> assign(:available_languages, updated_available)
        |> assign(:post, Map.put(socket.assigns.post, :available_languages, updated_available))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Handle Info - Version Events
  # ============================================================================

  def handle_info({:post_version_created, group_slug, post_identifier, version_info}, socket) do
    is_our_post =
      socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier)

    we_just_created = socket.assigns[:just_created_version] == true

    cond do
      !is_our_post ->
        {:noreply, socket}

      we_just_created ->
        # Clear the flag and don't show flash for our own action
        {:noreply, assign(socket, :just_created_version, nil)}

      true ->
        available_versions =
          version_info[:available_versions] || socket.assigns[:available_versions]

        socket =
          socket
          |> assign(:available_versions, available_versions)
          |> assign(:post, Map.put(socket.assigns.post, :available_versions, available_versions))
          |> put_flash(:info, gettext("A new version was created by another editor"))

        {:noreply, socket}
    end
  end

  def handle_info({:post_version_deleted, group_slug, post_identifier, deleted_version}, socket) do
    is_our_post =
      socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier)

    if is_our_post do
      {:noreply, Versions.handle_version_deleted(socket, deleted_version)}
    else
      {:noreply, socket}
    end
  end

  # Handle version published with source_id (user UUID)
  def handle_info(
        {:post_version_published, group_slug, post_identifier, published_version,
         source_user_uuid},
        socket
      ) do
    is_our_post =
      socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier)

    # Ignore if same user published (works across all their tabs)
    our_user_uuid =
      get_in(socket.assigns, [:phoenix_kit_current_scope, Access.key(:user), Access.key(:uuid)])

    from_us = source_user_uuid != nil && source_user_uuid == our_user_uuid

    cond do
      !is_our_post ->
        {:noreply, socket}

      from_us ->
        {:noreply, socket}

      true ->
        socket =
          socket
          |> put_flash(
            :info,
            gettext("Version %{version} was published by another editor",
              version: published_version
            )
          )

        {:noreply, socket}
    end
  end

  # Handle version published without source_id (legacy format, treat as from another editor)
  def handle_info({:post_version_published, group_slug, post_slug, published_version}, socket) do
    handle_info({:post_version_published, group_slug, post_slug, published_version, nil}, socket)
  end

  # ============================================================================
  # Handle Info - Lock Expiration
  # ============================================================================

  def handle_info(:check_lock_expiration, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      socket = Collaborative.check_lock_expiration(socket)
      {:noreply, socket}
    end
  end

  # Catch-all — log unknown PubSub messages at :debug instead of crashing
  # the LV. Matches the workspace precedent
  # (`phoenix_kit_sync/lib/phoenix_kit_sync/web/connections_live.ex:1042`).
  def handle_info(msg, socket) do
    require Logger
    Logger.debug("[Publishing.Editor] unhandled handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp source_language_for_translation(socket) do
    Translation.source_language_for_translation(socket)
  end

  # Matches a broadcast identifier (UUID) against the current post.
  defp handle_translation_created_update(socket, language) do
    case re_read_post(socket, socket.assigns[:current_language]) do
      {:ok, updated_post} ->
        socket
        |> assign(:available_languages, updated_post.available_languages)
        |> assign(
          :post,
          socket.assigns.post
          |> Map.put(:available_languages, updated_post.available_languages)
          |> Map.put(:language_statuses, updated_post.language_statuses)
        )

      {:error, _} ->
        available = socket.assigns[:available_languages] || []

        if language in available,
          do: socket,
          else: assign(socket, :available_languages, available ++ [language])
    end
  end

  defp post_matches?(socket, broadcast_id) do
    post = socket.assigns[:post]
    post != nil && post[:uuid] == broadcast_id
  end

  # Generic-pipeline events carry the post uuid as resource_uuid and the
  # targeted version as resource_scope. Match BOTH so an editor viewing a
  # different version of the same post ignores events for the other version.
  defp ai_event_for_this_post?(socket, resource_uuid, resource_scope) do
    post = socket.assigns[:post]

    is_binary(resource_uuid) and post != nil and post[:uuid] == resource_uuid and
      resource_scope == current_version_scope(socket)
  end

  # The version the editor is on, as the string the pipeline carries in
  # `resource_scope` (nil → active version). Mirrors
  # `Editor.Translation`'s enqueue scope so events match what was enqueued.
  defp current_version_scope(socket) do
    case socket.assigns[:current_version] do
      nil -> nil
      version -> to_string(version)
    end
  end

  # Which versions have a translation running, so a switch away and back can
  # restore the lock instead of dropping it mid-write.
  defp track_translation_in_flight(socket, false), do: socket

  defp track_translation_in_flight(socket, true) do
    scope = current_version_scope(socket)
    in_flight = socket.assigns[:translations_in_flight] || MapSet.new()

    assign(socket, :translations_in_flight, MapSet.put(in_flight, scope))
  end

  defp release_translation_in_flight(socket) do
    scope = current_version_scope(socket)
    in_flight = socket.assigns[:translations_in_flight] || MapSet.new()

    assign(socket, :translations_in_flight, MapSet.delete(in_flight, scope))
  end

  defp bump_translation_progress(socket) do
    assign(socket, :ai_translation_progress, (socket.assigns[:ai_translation_progress] || 0) + 1)
  end

  defp bump_translation_failures(socket) do
    assign(socket, :ai_translation_failures, (socket.assigns[:ai_translation_failures] || 0) + 1)
  end

  # When every enqueued language has reported back (success or failure), close
  # out: flash a summary, unlock, and reload the current language's content if
  # it was one of the translated targets.
  defp maybe_finalize_translation(socket) do
    total = socket.assigns[:ai_translation_total] || 0
    progress = socket.assigns[:ai_translation_progress] || 0

    if total > 0 and progress >= total do
      failures = socket.assigns[:ai_translation_failures] || 0
      success = max(total - failures, 0)
      translated = socket.assigns[:ai_translation_languages] || []
      current_language = socket.assigns[:current_language]
      {level, msg} = translation_summary(success, failures)

      socket =
        socket
        |> assign(:ai_translation_status, :completed)
        |> assign(:ai_translation_languages, [])
        |> assign(:translation_locked?, false)
        |> release_translation_in_flight()
        # Auto-close the translation modal/confirm on completion (was left open,
        # forcing a manual close).
        |> assign(:show_ai_translation, false)
        |> assign(:show_translation_confirm, false)

      if current_language in translated do
        Persistence.reload_translated_content(socket, msg, level)
      else
        socket
        |> Persistence.refresh_available_languages()
        |> put_flash(level, msg)
      end
    else
      socket
    end
  end

  defp translation_summary(success, 0) do
    {:info, gettext("Translation completed successfully for %{count} languages", count: success)}
  end

  defp translation_summary(success, failures) do
    {:warning,
     gettext("Translation completed with %{success} succeeded, %{failed} failed",
       success: success,
       failed: failures
     )}
  end

  # Presence has just promoted this socket from spectator to owner, which
  # normally means "load the current row and start editing". It must not mean
  # that when the socket is holding the previous owner's unsaved buffer: a
  # spectator mirrors the owner keystroke by keystroke, so if the owner's tab
  # died between autosaves, everything they typed since exists only here. A
  # re-read would hand back the older saved copy and quietly delete it — the
  # one failure mode where the writer never even learns there was something to
  # recover.
  defp reload_post_on_lock_acquired(socket) do
    if socket.assigns[:synced_from_owner?] do
      adopt_synced_buffer(socket)
    else
      reload_saved_copy_on_lock_acquired(socket)
    end
  end

  # Keep what is on screen and get it written down. Nothing is re-read: the
  # whole point is that the row is behind this buffer, and pulling any of it
  # back in would reintroduce the loss in a smaller shape. Autosave is armed
  # rather than saving inline so a promotion storm — several spectators, one
  # dying owner — collapses into one write per socket instead of a thundering
  # herd, and so a failed write surfaces through the usual autosave banner.
  defp adopt_synced_buffer(socket) do
    socket
    |> assign(:has_pending_changes, true)
    |> Collaborative.clear_synced_from_owner()
    |> push_event("changes-status", %{has_changes: true})
    # Re-asserted because the editor is re-rendering out of read-only right
    # now, and this is the moment the text stops being someone else's and
    # becomes editable. There is no caret to disturb — this session has been
    # watching, not typing — and the client applies it without echoing a
    # change back, so it cannot start a broadcast loop.
    |> push_event("set-content", %{content: socket.assigns.content})
    |> schedule_autosave()
    |> Collaborative.maybe_start_lock_expiration_timer()
    |> put_flash(
      :info,
      gettext("You're the editor now. The previous editor's unsaved changes were kept.")
    )
  end

  defp reload_saved_copy_on_lock_acquired(socket) do
    case re_read_post(socket, socket.assigns[:current_language]) do
      {:ok, post} ->
        form = Forms.post_form(post)

        socket
        |> assign(:post, %{post | group: socket.assigns.group_slug})
        |> Forms.assign_form_with_tracking(form)
        |> assign(:content, post.content)
        |> Helpers.mark_clean()
        |> push_event("changes-status", %{has_changes: false})
        |> push_event("set-content", %{content: post.content})
        |> Collaborative.maybe_start_lock_expiration_timer()

      {:error, _} ->
        # Still start the lock expiration timer even if re-read fails,
        # since this user is now the owner
        Collaborative.maybe_start_lock_expiration_timer(socket)
    end
  end

  defp detect_slug_manual_set(params, form, socket) do
    if Map.has_key?(params, "slug") do
      slug_value = Map.get(form, "slug", "")
      slug_value != "" && slug_value != socket.assigns.last_auto_slug
    else
      socket.assigns.slug_manually_set
    end
  end

  defp detect_url_slug_manual_set(params, form, socket) do
    if Map.has_key?(params, "url_slug") do
      url_slug_value = Map.get(form, "url_slug", "")
      url_slug_value != "" && url_slug_value != socket.assigns.last_auto_url_slug
    else
      socket.assigns.url_slug_manually_set
    end
  end

  defp maybe_generate_slug_from_title(
         socket,
         params,
         form,
         slug_manually_set,
         url_slug_manually_set
       ) do
    if Map.has_key?(params, "title") do
      socket
      |> assign(:form, form)
      |> assign(:slug_manually_set, slug_manually_set)
      |> assign(:url_slug_manually_set, url_slug_manually_set)
      |> Forms.maybe_update_slug_from_title(form["title"])
    else
      {socket, form, []}
    end
  end

  defp maybe_reclaim_lock(socket) do
    if socket.assigns[:lock_released_by_timeout] do
      Collaborative.try_reclaim_lock(socket)
    else
      socket
    end
  end

  # Mirrors update_meta's wiring (lock reclaim, translation lock guard,
  # immediate Collaborative.broadcast_form_change + touch_activity) so a
  # cleared image lands on other editors' screens before autosave fires.
  defp clear_image_field(socket, form_key, flash_message) do
    socket = maybe_reclaim_lock(socket)

    if socket.assigns.readonly? or socket.assigns.translation_locked? do
      {:noreply, socket}
    else
      new_form = Map.put(socket.assigns.form, form_key, "")

      socket =
        socket
        |> assign(:form, new_form)
        |> assign(:has_pending_changes, true)
        |> put_flash(:info, flash_message)
        |> push_event("changes-status", %{has_changes: true})
        |> schedule_autosave()

      Collaborative.broadcast_form_change(socket, :meta, new_form)
      socket = Collaborative.touch_activity(socket)

      {:noreply, socket}
    end
  end

  # A queued autosave carries edits that a context switch (version/language) is
  # about to replace, so it must be dropped rather than left to fire into the
  # new context as a no-op.
  # Mirrors Persistence.perform_save/1's own guards — the single source of
  # "why can't this be saved right now".
  defp blocked_reason(socket, form) do
    title = (form["title"] || "") |> to_string() |> String.trim()
    slug = (form["slug"] || "") |> to_string() |> String.trim()

    cond do
      title == "" -> gettext("Title is required to save.")
      socket.assigns.group_mode == "slug" and slug == "" -> gettext("Slug is required to save.")
      true -> nil
    end
  end

  defp do_switch_version(socket, version) do
    socket = cancel_autosave_timer(socket)

    case Versions.read_version_post(socket, version) do
      {:ok, version_post} ->
        {socket, old_form_key, old_post_slug, new_form_key, actual_language} =
          Versions.apply_version_switch(
            socket,
            version,
            version_post,
            &Forms.post_form_with_primary_status/3
          )

        socket =
          socket
          |> Helpers.assign_current_language(actual_language)
          |> Collaborative.cleanup_and_setup_collaborative_editing(old_form_key, new_form_key,
            old_post_slug: old_post_slug
          )

        post = socket.assigns.post

        url =
          Helpers.build_edit_url(socket.assigns.group_slug, post,
            version: version,
            lang: actual_language
          )

        {:noreply, push_patch(socket, to: url, replace: true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Version not found"))}
    end
  end

  # Saves outstanding work before a navigation that swaps the editor's buffer.
  # A read-only spectator never saves — they read has_pending_changes: true
  # after a remote sync, so saving would clobber the owner.
  defp flush_before_switch(socket) do
    if socket.assigns.has_pending_changes and not socket.assigns[:readonly?] do
      {:noreply, saved} = Persistence.perform_save(socket)

      if saved.assigns.has_pending_changes do
        {:blocked, saved}
      else
        {:ok, saved}
      end
    else
      {:ok, socket}
    end
  end

  defp cancel_autosave_timer(socket) do
    if timer = socket.assigns[:autosave_timer] do
      Process.cancel_timer(timer)
    end

    assign(socket, :autosave_timer, nil)
  end

  defp schedule_autosave(socket) do
    if socket.assigns.autosave_timer do
      Process.cancel_timer(socket.assigns.autosave_timer)
    end

    timer_ref = Process.send_after(self(), :autosave, @autosave_debounce_ms)
    assign(socket, :autosave_timer, timer_ref)
  end

  defp navigate_to_preview(socket) do
    group_slug = socket.assigns.group_slug
    post_uuid = socket.assigns.post[:uuid]
    language = socket.assigns.current_language
    version = socket.assigns[:current_version]

    query_params = %{"lang" => language}
    query_params = if version, do: Map.put(query_params, "v", version), else: query_params
    query = URI.encode_query(query_params)

    push_navigate(socket,
      to: Routes.path("/admin/publishing/#{group_slug}/#{post_uuid}/preview?#{query}")
    )
  end

  defp re_read_post(socket, language, version \\ nil) do
    case socket.assigns[:post] do
      nil ->
        {:error, :no_post}

      %{uuid: nil} ->
        {:error, :no_uuid}

      post ->
        # Default to the version the editor is pinned to, not the latest — reloads
        # (lock acquisition, translation-created updates) run while pinned to an
        # older version, and reading the latest would load the wrong version's
        # content under a URL claiming the pinned one and misdirect the next save.
        version = version || socket.assigns[:current_version]
        Publishing.read_post_by_uuid(post.uuid, language, version)
    end
  end

  defp do_switch_language(socket, new_language) do
    socket = cancel_autosave_timer(socket)
    post = socket.assigns.post
    group_slug = socket.assigns.group_slug
    content_exists = new_language in post.available_languages

    if content_exists do
      switch_to_existing_language(socket, group_slug, new_language)
    else
      switch_to_new_translation(socket, post, group_slug, new_language)
    end
  end

  defp switch_to_existing_language(socket, group_slug, target_language) do
    # Set loading state first, then defer the actual patch so LiveView
    # sends the skeleton-visible diff before starting the patch round-trip.
    send(self(), {:deferred_language_switch, group_slug, target_language})

    {:noreply, assign(socket, :editor_loading, true)}
  end

  defp switch_to_new_translation(socket, post, group_slug, new_language) do
    current_version = socket.assigns.current_version || 1

    virtual_post =
      Helpers.build_virtual_translation(post, group_slug, new_language, socket)

    available_versions = socket.assigns.available_versions || []
    new_form_key = PublishingPubSub.generate_form_key(group_slug, virtual_post, :edit)
    old_form_key = socket.assigns[:form_key]
    old_post_slug = socket.assigns[:post] && PublishingPubSub.broadcast_id(socket.assigns.post)

    form = Forms.post_form_with_primary_status(group_slug, virtual_post, current_version)

    socket =
      socket
      |> assign(:post, virtual_post)
      |> Forms.assign_form_with_tracking(form, slug_manually_set: false)
      |> assign(:content, "")
      |> Helpers.assign_current_language(new_language)
      |> assign(
        :viewing_older_version,
        Versions.viewing_older_version?(current_version, available_versions, new_language)
      )
      |> Helpers.mark_clean()
      |> assign(:is_new_translation, true)
      |> assign(:form_key, new_form_key)
      |> push_event("changes-status", %{has_changes: false})

    socket =
      Collaborative.cleanup_and_setup_collaborative_editing(socket, old_form_key, new_form_key,
        old_post_slug: old_post_slug
      )

    url =
      Helpers.build_edit_url(group_slug, post, lang: new_language, version: current_version)

    {:noreply,
     socket
     |> assign(:editor_loading, true)
     |> push_patch(to: url, replace: true)}
  end

  # Only the audio slot is type-checked: the image slots already point at an
  # image-filtered selector, and a wrong image is visible at a glance whereas a
  # wrong audio file is silent.
  defp media_allowed_for_target?(file_uuid, target)
       when target in ["audio_uuid", "audio_component"] do
    case Storage.get_file(file_uuid) do
      %{file_type: "audio"} -> true
      %{mime_type: mime} when is_binary(mime) -> String.starts_with?(mime, "audio/")
      _ -> false
    end
  rescue
    # Storage unreachable — don't block the editor over a type check.
    _ -> true
  end

  defp media_allowed_for_target?(_file_uuid, _target), do: true

  # The PHK block components, as toolbar buttons.
  #
  # Leaf's built-in image and video buttons already exist and route through
  # the media picker (`{:leaf_insert_request, …}`), so they are not repeated
  # here. These are the ones that had no affordance at all: the only way to
  # reach a Showcase band or an author note was to know the tag and type it,
  # which means the features may as well not exist for anyone who hasn't read
  # the format doc.
  #
  # `icon` is raw SVG rather than a heroicon class because Leaf renders these
  # in its own toolbar, outside this app's CSS: a `hero-*` class only works
  # where that stylesheet reached, and Leaf's toolbar sits in its own markup.
  # The version that saving would take down, or nil when saving changes
  # nothing about what is published.
  #
  # This used to warn whenever the status select read "published" and the post
  # had more than one version, counting every other version as about to be
  # archived. Both halves were wrong. `archive_other_published_versions!` only
  # touches versions whose own status is "published", and only one can be — so
  # a post with five versions loses ONE, not four. And on the version that is
  # already live there is nothing to take down at all: it is its own target,
  # so the warning fired on exactly the save that changes nothing.
  defp version_to_be_archived(assigns) do
    statuses = assigns[:version_statuses] || %{}
    current = assigns[:current_version]

    if Constants.published?(assigns[:form]["status"]) and
         not Constants.published?(Map.get(statuses, current)) do
      statuses
      |> Enum.find(fn {number, status} -> Constants.published?(status) and number != current end)
      |> case do
        {number, _status} -> number
        nil -> nil
      end
    end
  end

  defp component_toolbar_buttons do
    [
      %{
        id: "phk-headline",
        title: gettext("Headline (wide)"),
        icon: toolbar_glyph("H")
      },
      %{
        id: "phk-showcase",
        title: gettext("Showcase band"),
        icon: toolbar_glyph("▤")
      },
      %{
        id: "phk-gallery",
        title: gettext("Gallery (helix)"),
        icon: toolbar_glyph("◍")
      },
      %{
        id: "phk-audio",
        title: gettext("Audio player"),
        icon: toolbar_glyph("♪")
      },
      %{
        id: "phk-note",
        title: gettext("Author note"),
        icon: toolbar_glyph("†")
      },
      %{
        id: "phk-cta",
        title: gettext("Call to action"),
        icon: toolbar_glyph("▭")
      }
    ]
  end

  defp toolbar_glyph(char) do
    ~s(<span class="text-xs font-semibold leading-none">#{char}</span>)
  end

  # The markup each button inserts. Placeholder text is deliberate: an empty
  # component renders as nothing, which reads as "the button is broken", so
  # each one arrives with something visible to edit over.
  defp component_snippet("phk-headline", selected) do
    body = fallback(selected, gettext("Headline text"))
    ~s(<Headline stretch="30">#{body}</Headline>\n\n)
  end

  defp component_snippet("phk-showcase", selected) do
    body = fallback(selected, gettext("Words beside the picture."))

    """
    <Showcase src="" side="left" overlap="18" height="medium" alt="">
    ### #{gettext("Heading")}

    #{body}
    </Showcase>

    """
  end

  # Wraps the selection rather than replacing it: a note is an annotation ON
  # a phrase, so the phrase has to survive.
  defp component_snippet("phk-note", selected) do
    phrase = fallback(selected, gettext("the phrase"))
    ~s(<Note note="#{gettext("Your note here")}">#{phrase}</Note>)
  end

  defp component_snippet("phk-gallery", _selected), do: :pick_images
  defp component_snippet("phk-audio", _selected), do: :pick_audio

  defp component_snippet("phk-cta", selected) do
    body = fallback(selected, gettext("What should the reader do next?"))
    ~s(<CTA>#{body}</CTA>\n\n)
  end

  defp component_snippet(_unknown, _selected), do: nil

  defp fallback(selected, default) do
    case String.trim(selected) do
      "" -> default
      text -> text
    end
  end

  # What the picker should contain for a given slot. Only audio is narrowed:
  # `media_allowed_for_target?/2` refuses nothing else, and the image fields
  # are legitimately used for more than one kind of file — narrowing those
  # would take away a choice rather than prevent a mistake.
  defp media_filter_for_target("audio_uuid"), do: :audio
  defp media_filter_for_target("audio_component"), do: :audio
  defp media_filter_for_target("gallery"), do: :image
  defp media_filter_for_target(_target), do: :all

  defp handle_media_selected(socket, file_ids) do
    socket = maybe_reclaim_lock(socket)

    if socket.assigns.readonly? or socket.assigns.translation_locked? do
      # Every other write path checks this; the media picker didn't. A
      # session whose lock had lapsed could still open the picker, choose a
      # file, and have it assigned, broadcast to the real editor and
      # autosaved — the one hole through which a spectator could overwrite
      # the owner's featured image, OG image or audio.
      {:noreply,
       socket
       |> assign(:show_media_selector, false)
       |> assign(:media_selector_target, "featured_image_uuid")
       |> assign(:inserting_image_component, false)
       |> put_flash(:warning, gettext("Someone else is editing this post — nothing was changed."))}
    else
      do_handle_media_selected(socket, file_ids)
    end
  end

  defp do_handle_media_selected(socket, file_ids) do
    {socket, autosave?} =
      apply_media_selection(socket, media_selection_kind(socket, file_ids), file_ids)

    socket = if autosave?, do: schedule_autosave(socket), else: socket

    {:noreply, socket}
  end

  # Which of the five things a Choose click can mean. Named up front so each
  # outcome is its own clause below — the branch order is load-bearing (an
  # in-flight insertion mode wins over the plain slot assignment).
  defp media_selection_kind(socket, file_ids) do
    case insertion_mode(socket, file_ids) do
      nil -> slot_selection_kind(socket, List.first(file_ids))
      mode -> mode
    end
  end

  # A body-insertion mode that a toolbar button armed, if one is in flight and
  # the selection can satisfy it. Gallery is the only multi-file one.
  defp insertion_mode(socket, file_ids) do
    armed = fn key -> Map.get(socket.assigns, key, false) end
    picked_one? = List.first(file_ids) != nil

    cond do
      armed.(:inserting_audio) and picked_one? -> :audio_component
      armed.(:inserting_gallery) and file_ids != [] -> :gallery
      armed.(:inserting_image_component) and picked_one? -> :image_component
      true -> nil
    end
  end

  defp slot_selection_kind(_socket, nil), do: :nothing

  defp slot_selection_kind(socket, file_uuid) do
    if media_allowed_for_target?(file_uuid, socket.assigns[:media_selector_target]),
      do: :slot,
      else: :wrong_type
  end

  defp apply_media_selection(socket, :audio_component, file_ids) do
    send_update(Leaf,
      id: "content-editor",
      action: :insert_markdown,
      text: Helpers.audio_component_markup(List.first(file_ids))
    )

    {socket
     |> close_media_selector()
     |> assign(:inserting_audio, false)
     |> put_flash(:info, gettext("Audio player inserted")), false}
  end

  defp apply_media_selection(socket, :gallery, file_ids) do
    send_update(Leaf,
      id: "content-editor",
      action: :insert_markdown,
      text: Helpers.gallery_markup(file_ids)
    )

    {socket
     |> close_media_selector()
     |> assign(:media_selection_mode, :single)
     |> assign(:inserting_gallery, false)
     |> put_flash(:info, gettext("Gallery inserted")), false}
  end

  defp apply_media_selection(socket, :image_component, file_ids) do
    # Insert through Leaf's own command (CSP-safe, survives navigation)
    # instead of a bespoke inline-script listener.
    send_update(Leaf,
      id: "content-editor",
      action: :insert_markdown,
      text: Helpers.image_component_markup(List.first(file_ids))
    )

    {socket
     |> assign(:show_media_selector, false)
     |> assign(:inserting_image_component, false)
     |> put_flash(:info, gettext("Image component inserted")), false}
  end

  # The shared selector has no audio filter, so a Choose click could attach a
  # PNG to the audio slot: the post page would render a dead <audio> and the
  # feed an <enclosure type="audio/mpeg"> pointing at an image. Refuse rather
  # than store it.
  defp apply_media_selection(socket, :wrong_type, _file_ids) do
    {socket
     |> close_media_selector()
     |> put_flash(:error, gettext("That file isn't audio — pick an audio file.")), false}
  end

  defp apply_media_selection(socket, :slot, file_ids) do
    target = socket.assigns[:media_selector_target] || "featured_image_uuid"
    new_form = Forms.update_form_with_media(socket.assigns.form, List.first(file_ids), target)

    socket =
      socket
      |> assign(:form, new_form)
      |> assign(:has_pending_changes, true)
      |> close_media_selector()
      |> put_flash(:info, media_slot_flash(target))
      |> push_event("changes-status", %{has_changes: true})

    # Immediate live-collab broadcast — without this, spectators only see
    # the new image after the 500ms autosave fires + an editor_saved
    # round-trip. Mirrors the wiring update_meta does for text fields.
    Collaborative.broadcast_form_change(socket, :meta, new_form)
    socket = Collaborative.touch_activity(socket)

    {socket, true}
  end

  defp apply_media_selection(socket, :nothing, _file_ids),
    do: {close_media_selector(socket), false}

  defp close_media_selector(socket) do
    socket
    |> assign(:show_media_selector, false)
    |> assign(:media_selector_target, "featured_image_uuid")
  end

  defp media_slot_flash("og_image_uuid"), do: gettext("OG image selected")
  defp media_slot_flash("audio_uuid"), do: gettext("Audio version selected")
  defp media_slot_flash(_target), do: gettext("Featured image selected")

  @impl true
  def render(assigns) do
    ~H"""
    <% edit_disabled? = @readonly? or @translation_locked? %>


    <div class="w-full px-4 py-6 space-y-6">
    <div class="flex flex-wrap items-center justify-between gap-2">
      <button type="button" class="btn btn-ghost btn-sm pl-0" phx-click="back_to_list">
        <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> {gettext("Back to %{group}",
          group: @group_name || gettext("Group")
        )}
      </button>
      <div class="flex items-center gap-2">
        <%= unless @is_new_post do %>
          <%!-- Preview SAVES before it navigates, so the gap between click
                and anything happening is a database write, not a repaint.
                Unmarked, a writer with a slow connection clicks it twice. --%>
          <button
            type="button"
            class="btn btn-outline btn-xs sm:btn-sm shadow-none [&.phx-click-loading]:pointer-events-none"
            phx-click="preview"
          >
            <.icon name="hero-eye" class="w-4 h-4 sm:mr-1 [.phx-click-loading_&]:hidden" />
            <span class="hidden loading loading-spinner loading-xs sm:mr-1 [.phx-click-loading_&]:inline-block">
            </span>
            <span class="hidden sm:inline">{gettext("Preview")}</span>
          </button>
        <% end %>
        <%= if Constants.published?(@form["status"]) && @public_url do %>
          <a
            href={if @has_pending_changes, do: "#", else: @public_url}
            target="_blank"
            class={[
              "btn btn-outline btn-xs sm:btn-sm shadow-none",
              !@has_pending_changes && "btn-success",
              @has_pending_changes && "btn-disabled pointer-events-none opacity-60"
            ]}
            aria-disabled={@has_pending_changes}
            tabindex={if @has_pending_changes, do: "-1", else: "0"}
            title={
              if(@has_pending_changes,
                do: "Save the post before viewing the public page",
                else: "View this post on the public site"
              )
            }
          >
            <.icon name="hero-globe-alt" class="w-4 h-4 sm:mr-1" />
            <span class="hidden sm:inline">{gettext("View Public")}</span>
          </a>
        <% end %>
      </div>
    </div>

    <%!-- Public URL (shown for published posts, mirrors the post listing) --%>
    <%= if Constants.published?(@form["status"]) && @public_url do %>
      <% full_public_url = (assigns[:endpoint_url] || "") <> @public_url %>
      <p class="text-xs text-base-content/50 break-all">
        <span class="font-medium text-base-content">{gettext("Public URL")}:</span>
        <a
          href={full_public_url}
          target="_blank"
          class="link link-hover font-mono text-xs"
        >
          {full_public_url}
        </a>
      </p>
    <% end %>

    <%!-- Version Switcher and Actions --%>
    <div class="flex flex-col gap-2">
      <%!-- Version Switcher (for versioned posts in both slug and timestamp modes) --%>
      <%= if !@is_new_post && @post do %>
        <div class="flex items-center gap-1.5 flex-wrap">
          <%= if length(@available_versions) > 1 do %>
            <span class="text-xs font-medium text-base-content/60">{gettext("Version:")}</span>
            <.publishing_version_switcher
              versions={@available_versions}
              version_statuses={@version_statuses}
              version_dates={@version_dates}
              current_version={@current_version}
              on_click="switch_version"
              size={:sm}
            />
          <% else %>
            <span class="text-xs font-medium text-base-content/60">
              {gettext("Version:")} v{@current_version}
            </span>
          <% end %>
          <%!-- New Version Button --%>
          <button
            type="button"
            class={"btn btn-ghost btn-xs gap-1 #{if edit_disabled?, do: "btn-disabled opacity-60"}"}
            phx-click="open_new_version_modal"
            disabled={edit_disabled?}
          >
            <.icon name="hero-plus" class="w-3 h-3" />
            {gettext("New Version")}
          </button>
          <%!-- AI Translation Button --%>
          <%= if @ai_enabled do %>
            <button
              type="button"
              class="btn btn-ghost btn-xs gap-1"
              phx-click="toggle_ai_translation"
            >
              <.icon name="hero-language" class="w-3 h-3" />
              {gettext("AI Translate")}
            </button>
          <% end %>
        </div>
      <% end %>
    </div>

    <%!-- Version locking banner removed - with variant versioning all versions are editable --%>

    <%!-- Spectator mode banner - someone else is editing or lock expired --%>
    <%= if @readonly? do %>
      <div class="alert alert-warning shadow-sm">
        <.icon name="hero-eye" class="w-5 h-5" />
        <div class="flex-1">
          <%= if assigns[:lock_released_by_timeout] do %>
            <span class="font-medium">{gettext("Session paused:")}</span>
            <span>
              {gettext("Your editing lock expired due to inactivity.")}
            </span>
            <%!-- An explicit control, because the promise of "just start typing"
                  can't be kept: readonly? disables the very fields whose input
                  would trigger the reclaim. --%>
            <button
              type="button"
              phx-click="resume_editing"
              phx-disable-with={gettext("Resuming…")}
              class="btn btn-warning btn-sm ml-2"
            >
              <.icon name="hero-play" class="w-4 h-4" />
              {gettext("Resume editing")}
            </button>
          <% else %>
            <span class="font-medium">{gettext("View only mode:")}</span>
            <span>
              <%= if @lock_owner_user do %>
                {gettext(
                  "%{email} is currently editing this post. You can view but not make changes.",
                  email: @lock_owner_user.email
                )}
              <% else %>
                {gettext(
                  "Another user is currently editing this post. You can view but not make changes."
                )}
              <% end %>
            </span>
          <% end %>
        </div>
      </div>
    <% end %>

    <%!-- Auto-version creation banner removed - users now explicitly create new versions via the "New Version" button --%>

    <%!-- Warning for disabled or unknown language --%>
    <%= if not @current_language_enabled or not @current_language_known do %>
      <div class="alert alert-warning shadow-sm">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div>
          <%= if not @current_language_known do %>
            <span class="font-medium">{gettext("Unknown language:")}</span>
            <span>
              {gettext(
                "This language (%{code}) doesn't match a recognized language code. The publishing status will still be respected.",
                code: @current_language
              )}
            </span>
          <% else %>
            <span class="font-medium">{gettext("Disabled language:")}</span>
            <span>
              {gettext(
                "This language (%{code}) is no longer enabled in the Languages module. The publishing status will still be respected for legacy content.",
                code: @current_language
              )}
            </span>
          <% end %>
        </div>
      </div>
    <% end %>

    <%!-- Translation in progress lock banner --%>
    <%= if @translation_locked? do %>
      <div class="alert shadow-sm border border-primary/30 bg-primary/5">
        <span class="loading loading-spinner loading-sm text-primary"></span>
        <div>
          <span class="font-medium">{gettext("Translation in progress")}</span>
          <span class="text-sm text-base-content/70">
            {gettext(
              "Editing is paused while AI translates this content. It will unlock automatically when finished."
            )}
          </span>
        </div>
      </div>
    <% end %>

    <%!-- AI Translation Modal --%>
    <%= if @ai_enabled and not @is_new_post do %>
      <dialog id="ai-translation-modal" class={["modal", @show_ai_translation && "modal-open"]}>
        <div class="modal-box max-w-lg">
          <div class="flex items-center justify-between mb-4">
            <h3 class="font-bold text-lg flex items-center gap-2">
              <.icon name="hero-language" class="w-5 h-5 text-primary" />
              {gettext("AI Translation")}
            </h3>
            <button
              type="button"
              class="btn btn-sm btn-circle btn-ghost"
              phx-click="toggle_ai_translation"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <div class="space-y-4">
            <p class="text-sm text-base-content/70">
              <%= if @current_language == @default_language do %>
                {gettext(
                  "Automatically translate this post to other languages using AI. Each translation runs as a background job — you can keep editing while it finishes, or safely leave this page."
                )}
              <% else %>
                {gettext(
                  "Translate the %{source} post to %{target} using AI. It runs as a background job — you can keep editing while it finishes, or safely leave this page.",
                  source: @default_language_name,
                  target: @current_language_name
                )}
              <% end %>
            </p>

            <%!-- Endpoint Selection --%>
            <div class="space-y-1">
              <form id="ai-endpoint-form" phx-change="select_ai_endpoint">
                <label class="select select-sm w-full">
                  <select name="endpoint_uuid">
                    <option value="">{gettext("Select an endpoint...")}</option>
                    <%= for {id, name} <- @ai_endpoints do %>
                      <option value={id} selected={@ai_selected_endpoint_uuid == id}>
                        {name}
                      </option>
                    <% end %>
                  </select>
                </label>
              </form>
              <.link
                navigate={PhoenixKit.Utils.Routes.path("/admin/ai/endpoints")}
                class="text-xs link link-primary"
              >
                {gettext("Manage Endpoints")}
              </.link>
              <p class="flex items-start gap-1 text-xs text-base-content/60">
                <.icon name="hero-information-circle" class="w-3.5 h-3.5 shrink-0 mt-px" />
                <span>
                  {gettext(
                    "Reasoning (\"thinking\") models are slower and may return unstructured output — a standard model is recommended for translation."
                  )}
                </span>
              </p>
            </div>

            <%!-- Prompt Selection --%>
            <div class="space-y-1">
              <form id="ai-prompt-form" phx-change="select_ai_prompt">
                <label class="select select-sm w-full">
                  <select name="prompt_uuid">
                    <option value="">{gettext("Select a prompt...")}</option>
                    <%= for {id, name} <- @ai_prompts do %>
                      <option value={id} selected={@ai_selected_prompt_uuid == id}>
                        {name}
                      </option>
                    <% end %>
                  </select>
                </label>
              </form>
              <div class="flex items-center gap-2">
                <.link
                  navigate={PhoenixKit.Utils.Routes.path("/admin/ai/prompts")}
                  class="text-xs link link-primary"
                >
                  {gettext("Manage Prompts")}
                </.link>
                <%= unless @ai_default_prompt_exists do %>
                  <button
                    type="button"
                    class="btn btn-outline btn-xs gap-1 [&.phx-click-loading]:pointer-events-none"
                    phx-click="generate_default_translation_prompt"
                    disabled={edit_disabled?}
                  >
                    <.icon name="hero-sparkles" class="w-3 h-3 [.phx-click-loading_&]:hidden" />
                    <span class="hidden loading loading-spinner loading-xs [.phx-click-loading_&]:inline-block">
                    </span>
                    {gettext("Generate Default Prompt")}
                  </button>
                <% end %>
                <%= if @ai_default_prompt_exists and @ai_default_prompt_stale do %>
                  <button
                    type="button"
                    class="btn btn-warning btn-outline btn-xs gap-1 [&.phx-click-loading]:pointer-events-none"
                    phx-click="regenerate_default_translation_prompt"
                    disabled={edit_disabled?}
                    title={gettext("This prompt predates the current format and may mistranslate. Click to update it.")}
                  >
                    <.icon name="hero-arrow-path" class="w-3 h-3 [.phx-click-loading_&]:hidden" />
                    <span class="hidden loading loading-spinner loading-xs [.phx-click-loading_&]:inline-block">
                    </span>
                    {gettext("Regenerate Default Prompt")}
                  </button>
                <% end %>
              </div>
            </div>

            <%!-- Translation Status --%>
            <%= if @ai_translation_status in [:enqueued, :in_progress, :completed] do %>
              <div class="space-y-2">
                <div class="flex items-center justify-between text-sm">
                  <span class="text-base-content/70 flex items-center gap-2">
                    <%= if @ai_translation_status == :completed do %>
                      <.icon name="hero-check-circle" class="w-4 h-4 text-success" />
                      {gettext("Complete")}
                    <% else %>
                      <span class="loading loading-spinner loading-xs"></span>
                      <%= if @ai_translation_languages != [] do %>
                        {gettext("Translating to %{languages}...",
                          languages: format_language_list(@ai_translation_languages)
                        )}
                      <% else %>
                        {gettext("Translating...")}
                      <% end %>
                    <% end %>
                  </span>
                  <span class="font-medium">
                    <%= if @ai_translation_total && @ai_translation_total > 0 do %>
                      {@ai_translation_progress || 0} / {@ai_translation_total}
                    <% else %>
                      {gettext("Starting...")}
                    <% end %>
                  </span>
                </div>
                <%= if @ai_translation_total && @ai_translation_total > 0 do %>
                  <progress
                    class={[
                      "progress w-full",
                      @ai_translation_status == :completed && "progress-success",
                      @ai_translation_status != :completed && "progress-primary"
                    ]}
                    value={@ai_translation_progress || 0}
                    max={@ai_translation_total}
                  >
                  </progress>
                <% else %>
                  <progress class="progress progress-primary w-full"></progress>
                <% end %>
              </div>
            <% end %>

            <%!-- Action Buttons --%>
            <div class="flex flex-wrap gap-3">
              <%= if @current_language == @default_language do %>
                <button
                  type="button"
                  class={"btn btn-primary btn-sm #{if @ai_selected_endpoint_uuid == nil or @ai_selected_prompt_uuid == nil or @ai_translation_status in [:enqueued, :in_progress], do: "btn-disabled"}"}
                  phx-click="translate_to_all_languages"
                  phx-disable-with={gettext("Enqueueing…")}
                  disabled={
                    edit_disabled? or
                      @ai_selected_endpoint_uuid == nil or
                      @ai_selected_prompt_uuid == nil or
                      @ai_translation_status in [:enqueued, :in_progress]
                  }
                >
                  <.icon name="hero-language" class="w-4 h-4" />
                  {gettext("Translate to All Languages")}
                </button>

                <button
                  type="button"
                  class={"btn btn-outline btn-sm #{if @ai_selected_endpoint_uuid == nil or @ai_selected_prompt_uuid == nil or @ai_translation_status in [:enqueued, :in_progress], do: "btn-disabled"}"}
                  phx-click="translate_missing_languages"
                  phx-disable-with={gettext("Enqueueing…")}
                  disabled={
                    edit_disabled? or
                      @ai_selected_endpoint_uuid == nil or
                      @ai_selected_prompt_uuid == nil or
                      @ai_translation_status in [:enqueued, :in_progress]
                  }
                >
                  <.icon name="hero-plus" class="w-4 h-4" />
                  {gettext("Translate Missing Only")}
                </button>
              <% else %>
                <button
                  type="button"
                  class={"btn btn-primary btn-sm #{if @ai_selected_endpoint_uuid == nil or @ai_selected_prompt_uuid == nil or @ai_translation_status in [:enqueued, :in_progress], do: "btn-disabled"}"}
                  phx-click="translate_to_this_language"
                  phx-disable-with={gettext("Translating…")}
                  disabled={
                    edit_disabled? or
                      @ai_selected_endpoint_uuid == nil or
                      @ai_selected_prompt_uuid == nil or
                      @ai_translation_status in [:enqueued, :in_progress]
                  }
                >
                  <.icon name="hero-language" class="w-4 h-4" />
                  {gettext("Translate to This Language")}
                </button>
              <% end %>
            </div>

            <%!-- Info --%>
            <div class="text-xs text-base-content/50 space-y-1">
              <%= if @current_language == @default_language do %>
                <p>
                  <.icon name="hero-information-circle" class="w-3 h-3 inline" />
                  {gettext(
                    "\"Translate to All\" will create or overwrite translations for all enabled languages."
                  )}
                </p>
                <p>
                  <.icon name="hero-information-circle" class="w-3 h-3 inline" />
                  {gettext(
                    "\"Translate Missing\" will only create translations for languages that don't have one yet."
                  )}
                </p>
              <% else %>
                <p>
                  <.icon name="hero-information-circle" class="w-3 h-3 inline" />
                  {gettext(
                    "This will translate the %{source} content to %{target}, overwriting any existing content.",
                    source: @default_language_name,
                    target: @current_language_name
                  )}
                </p>
              <% end %>
            </div>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="toggle_ai_translation"></div>
      </dialog>
    <% end %>

    <%!-- Skeleton placeholders for language switching.
         NOT hidden by default — the fields div hides them on mount via phx-mounted.
         IDs include @current_language so morphdom treats them as new elements,
         ensuring a fresh visible skeleton appears during each language switch.
         Uses bg-base-content/10 instead of DaisyUI skeleton class because
         the skeleton class depends on --color-base-300 which resolves to white
         in some PhoenixKit themes. --%>
    <div
      id={"editor-skeletons-#{@current_language}"}
      data-translatable="skeletons"
      class={unless @editor_loading, do: "hidden"}
    >
      <div class="flex flex-col lg:flex-row gap-6 animate-pulse">
        <div class="flex-1 space-y-4 p-6">
          <div class="bg-base-200 h-12 w-full rounded-lg"></div>
          <div class="flex items-center justify-between">
            <div class="bg-base-200 h-6 w-32 rounded"></div>
            <div class="bg-base-200 h-6 w-24 rounded"></div>
          </div>
          <div class="bg-base-200 h-[480px] w-full rounded-lg"></div>
        </div>
        <div class="lg:w-80 space-y-4 p-6">
          <div class="space-y-2">
            <div class="bg-base-200 h-4 w-20 rounded"></div>
            <div class="bg-base-200 h-10 w-full rounded-lg"></div>
            <div class="bg-base-200 h-3 w-48 rounded"></div>
          </div>
          <div class="space-y-2">
            <div class="bg-base-200 h-4 w-32 rounded"></div>
            <div class="bg-base-200 h-40 w-full rounded-lg"></div>
          </div>
          <div class="space-y-2">
            <div class="bg-base-200 h-4 w-16 rounded"></div>
            <div class="bg-base-200 h-10 w-full rounded-lg"></div>
          </div>
          <div class="space-y-2">
            <div class="bg-base-200 h-4 w-40 rounded"></div>
            <div class="bg-base-200 h-10 w-full rounded-lg"></div>
          </div>
        </div>
      </div>
    </div>

    <div
      id={"editor-fields-#{@current_language}"}
      data-translatable="fields"
      class={if @editor_loading, do: "hidden"}
    >
      <.form for={@form} id="publishing-meta" phx-change="update_meta" phx-submit="noop">
        <div class="flex flex-col lg:flex-row gap-6">
          <%!-- Left column: Language switcher + Title + Content --%>
          <div class="flex-1 space-y-4">
            <%!-- Language Switcher (inside content area) --%>
            <%= if length(@all_enabled_languages) > 1 or not @current_language_enabled or not @current_language_known do %>
              <% all_languages =
                build_editor_languages(
                  @post,
                  @all_enabled_languages,
                  @current_language
                ) %>
              <div class="flex items-center gap-2 flex-wrap">
                <span class="text-xs font-medium text-base-content/60 shrink-0">
                  {gettext("Language:")}
                </span>
                <.language_switcher
                  languages={all_languages}
                  current_language={@current_language}
                  show_status={true}
                  show_add={true}
                  on_click_js={&switch_lang_js(&1, @current_language)}
                  size={:sm}
                />
              </div>
            <% end %>

            <div>
              <div class="space-y-4">
                <%!-- Save status and button --%>
                <div class="flex flex-wrap items-center justify-end gap-1.5">
                  <%!-- Other viewers indicator --%>
                  <%= if @other_viewers != [] do %>
                    <div
                      class="tooltip tooltip-bottom"
                      data-tip={Enum.map_join(@other_viewers, ", ", & &1.user_email)}
                    >
                      <span class="badge badge-info badge-sm gap-1">
                        <.icon name="hero-eye" class="w-3 h-3" />
                        {ngettext(
                          "1 other viewing",
                          "%{count} others viewing",
                          length(@other_viewers),
                          count: length(@other_viewers)
                        )}
                      </span>
                    </div>
                  <% end %>
                  <%= cond do %>
                    <% @is_autosaving -> %>
                      <span class="badge badge-info badge-sm gap-1">
                        <span class="loading loading-spinner loading-xs"></span>
                        {gettext("Saving...")}
                      </span>
                    <% @autosave_blocked -> %>
                      <span class="badge badge-error badge-sm h-auto gap-1">
                        <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
                        {@autosave_blocked}
                      </span>
                    <% @has_pending_changes -> %>
                      <span class="badge badge-warning badge-sm h-auto">
                        {gettext("Unsaved changes")}
                      </span>
                    <% @is_new_post -> %>
                      <span class="badge badge-ghost badge-sm h-auto">{gettext("New")}</span>
                    <% true -> %>
                      <span class="badge badge-success badge-sm gap-1">
                        <.icon name="hero-check" class="w-3 h-3" />
                        {gettext("Saved")}
                      </span>
                  <% end %>
                  <% save_disabled = edit_disabled? || @is_autosaving %>
                  <button
                    type="button"
                    phx-click="save"
                    phx-disable-with={gettext("Saving…")}
                    class={[
                      "btn btn-primary btn-xs shadow-none gap-1",
                      save_disabled && "btn-disabled pointer-events-none opacity-60"
                    ]}
                    disabled={save_disabled}
                  >
                    <span class="hidden phx-click-loading:inline-flex items-center gap-1">
                      <span class="loading loading-spinner loading-2xs"></span>
                      {gettext("Saving...")}
                    </span>
                    <span class="inline-flex items-center gap-1 phx-click-loading:hidden">
                      <.icon name="hero-arrow-down-tray" class="w-3 h-3" /> {gettext("Save now")}
                    </span>
                  </button>
                </div>
                <%!-- Title field --%>
                <input
                  type="text"
                  name="title"
                  id="title-input"
                  value={@form["title"] || ""}
                  maxlength="500"
                  phx-debounce="300"
                  class={"input input-bordered w-full text-2xl font-semibold #{if edit_disabled? or @viewing_older_version, do: "input-disabled bg-base-200"}"}
                  placeholder={gettext("Post title")}
                  readonly={edit_disabled? or @viewing_older_version}
                />
                <%!-- Content editor (Leaf), opened in markdown mode, plus the
                      `#` trigger that turns body hashtags into an autocomplete.
                      Tags come from the group's existing ones — see
                      handle_info({:leaf_suggest, …}).

                      `mode` is set deliberately, not left at Leaf's default of
                      :hybrid. The hybrid and visual surfaces round-trip the
                      body through HTML, which is fine for prose but makes PHK
                      components second-class: `preserve_tags` keeps them
                      intact, but only as opaque blocks nobody can edit without
                      dropping to markdown anyway. Posts here are written with
                      <Showcase>, <Note>, <Audio> and friends, so markdown is
                      the mode that can actually edit them. The toolbar still
                      offers the other modes — Leaf has no supported way to
                      remove them — but nothing depends on anyone using one.

                      `protect_navigation` predates the move to Leaf and was
                      dropped in the swap — it warns before leaving with
                      unsaved work, which nothing else here does.

                      `save_status` was dropped in the same swap and is NOT
                      coming back. Leaf's badge only knows saved/saving/
                      unsaved, while the badge above says WHY a save is
                      blocked ("Title is required to save."). Restoring it
                      put two status indicators on screen disagreeing with
                      each other.

                      `toolbar_extra` adds the PHK components to the toolbar.
                      Leaf's own image and video buttons already route into
                      the media picker; these are the block components that
                      previously had to be typed out by hand. --%>
                <.leaf_editor
                  id="content-editor"
                  content={@content}
                  placeholder={gettext("Write your content here...")}
                  height="480px"
                  debounce={400}
                  toolbar={[:image, :video]}
                  readonly={edit_disabled? or @viewing_older_version}
                  mode={:markdown}
                  preserve_tags={Renderer.component_tags()}
                  gettext_backend={PhoenixKitPublishing.Gettext}
                  protect_navigation={true}
                  toolbar_extra={component_toolbar_buttons()}
                  suggestions={[
                    %{
                      trigger: "#",
                      boundary: :word_start,
                      first_char: ~r/\p{L}/u,
                      token: ~r/[\p{L}\p{N}_-]/u,
                      max_length: 30,
                      # 1, not 0: a lone "#" at the start of a line is a
                      # heading, and popping a tag list open on that keystroke
                      # interrupts someone who is only writing a title.
                      min_chars: 1,
                      debounce: 150,
                      max_results: 10,
                      allow_create: true,
                      exclude: [:code, :link]
                    }
                  ]}
                />
              </div>
            </div>
          </div>

          <%!-- Right column: Version Settings (global, shared across all languages) --%>
          <div class="lg:w-80 space-y-4">
            <div>
              <div class="space-y-4">
                <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  {gettext("Version Settings")}
                </h3>

                <%!-- Slug (slug-mode groups only) --%>
                <%= if @group_mode == "slug" do %>
                  <%= if @is_primary_language do %>
                    <%!-- Primary language: editable slug used in the post URL --%>
                    <div>
                      <label class="label">
                        <span class="label-text text-sm font-semibold text-base-content">
                          {gettext("Slug")}
                        </span>
                      </label>
                      <input
                        type="text"
                        name="slug"
                        id="slug-input"
                        value={@form["slug"]}
                        pattern="[a-z0-9]+(-[a-z0-9]+)*"
                        class={"input input-bordered w-full lowercase #{if edit_disabled? or @viewing_older_version, do: "input-disabled bg-base-200"}"}
                        placeholder={gettext("auto-generated from title")}
                        title={
                          gettext(
                            "Use lowercase letters, numbers, and hyphens only. No spaces or special characters."
                          )
                        }
                        readonly={edit_disabled? or @viewing_older_version}
                      />
                      <div class="mt-1 flex items-start justify-between gap-2">
                        <p class="text-xs text-base-content/60">
                          {gettext("Use lowercase letters, numbers, and hyphens only.")}
                          {gettext("This will be the default URL for all languages.")}
                        </p>
                        <%!-- The handler existed with no control, so a slug that
                              drifted from a retitled post could only be fixed by
                              hand. --%>
                        <button
                          :if={not (edit_disabled? or @viewing_older_version)}
                          type="button"
                          phx-click="regenerate_slug"
                          phx-disable-with={gettext("Working…")}
                          class="btn btn-ghost btn-xs shrink-0"
                          title={gettext("Re-derive the slug from the current title")}
                        >
                          <.icon name="hero-arrow-path" class="w-3 h-3" />
                          {gettext("From title")}
                        </button>
                      </div>
                    </div>
                  <% else %>
                    <%!-- Translation: per-language URL slug for SEO-friendly localized URLs --%>
                    <div>
                      <label class="label">
                        <span class="label-text text-sm font-semibold text-base-content">
                          {gettext("URL Slug")}
                          <span class="text-base-content/60 font-normal ml-1">
                            ({gettext("optional")})
                          </span>
                        </span>
                      </label>
                      <input
                        type="text"
                        name="url_slug"
                        id="url-slug-input"
                        value={@form["url_slug"] || ""}
                        maxlength="200"
                        pattern={SlugHelpers.html_input_pattern()}
                        class={"input input-bordered w-full lowercase #{if edit_disabled? or @viewing_older_version, do: "input-disabled bg-base-200"}"}
                        placeholder={@form["slug"] || ""}
                        title={
                          gettext(
                            "Use lowercase letters, numbers, and hyphens only. Leave empty to use the default slug."
                          )
                        }
                        readonly={edit_disabled? or @viewing_older_version}
                      />
                      <p class="text-xs text-base-content/60 mt-1">
                        {gettext(
                          "Custom URL for this language. Leave empty to use default: %{slug}",
                          slug: @form["slug"]
                        )}
                      </p>
                      <p class="text-xs text-base-content/50 mt-0.5">
                        {gettext("Preview: /%{language}/%{group}/%{slug}",
                          language: @current_language,
                          group: @group_slug,
                          slug:
                            if(@form["url_slug"] != "",
                              do: @form["url_slug"],
                              else: @form["slug"]
                            )
                        )}
                      </p>
                    </div>
                  <% end %>
                <% end %>

                <div>
                  <label class="label">
                    <span class="label-text text-sm font-semibold text-base-content">
                      {gettext("Featured Image")}
                    </span>
                  </label>

                  <%= if preview_url = featured_image_preview_url(@form["featured_image_uuid"]) do %>
                    <%!-- Image Preview with Actions --%>
                    <div class="space-y-3">
                      <div class="relative group">
                        <img
                          src={preview_url}
                          alt={
                            Map.get(@post.metadata, :title) ||
                              Map.get(@post.metadata, "title") ||
                              gettext("Featured image")
                          }
                          class="w-full rounded-lg border-2 border-base-300 object-cover max-h-56"
                          loading="lazy"
                        />
                        <%!-- Desktop: Hover overlay (hidden when readonly or viewing older version) --%>
                        <%= if not (edit_disabled? or @viewing_older_version) do %>
                          <div class="hidden md:flex absolute inset-0 bg-base-content/0 group-hover:bg-base-content/60 transition-all rounded-lg items-center justify-center gap-3 opacity-0 group-hover:opacity-100">
                            <button
                              type="button"
                              phx-click="open_media_selector"
                              disabled={edit_disabled? or @viewing_older_version}
                              class="btn btn-primary btn-sm shadow-lg"
                            >
                              <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" />
                              {gettext("Change")}
                            </button>
                            <button
                              type="button"
                              phx-click="clear_featured_image"
                              disabled={edit_disabled? or @viewing_older_version}
                              phx-disable-with={gettext("Removing…")}
                              class="btn btn-error btn-sm shadow-lg"
                            >
                              <.icon name="hero-trash" class="w-4 h-4 mr-1" />
                              {gettext("Remove")}
                            </button>
                          </div>
                        <% end %>
                      </div>
                      <%!-- Mobile: Always visible buttons (hidden when readonly or viewing older version) --%>
                      <%= if not (edit_disabled? or @viewing_older_version) do %>
                        <div class="flex md:hidden gap-2">
                          <button
                            type="button"
                            phx-click="open_media_selector"
                            disabled={edit_disabled? or @viewing_older_version}
                            class="btn btn-primary btn-sm flex-1"
                          >
                            <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" />
                            {gettext("Change")}
                          </button>
                          <button
                            type="button"
                            phx-click="clear_featured_image"
                            disabled={edit_disabled? or @viewing_older_version}
                            phx-disable-with={gettext("Removing…")}
                            class="btn btn-error btn-sm flex-1"
                          >
                            <.icon name="hero-trash" class="w-4 h-4 mr-1" />
                            {gettext("Remove")}
                          </button>
                        </div>
                      <% end %>
                    </div>
                  <% else %>
                    <%!-- No Image Selected - Show Upload Area --%>
                    <button
                      type="button"
                      phx-click="open_media_selector"
                      disabled={edit_disabled? or @viewing_older_version}
                      class={"w-full border-2 border-dashed border-base-300 rounded-lg p-8 transition-all group #{if edit_disabled? or @viewing_older_version, do: "opacity-50 cursor-not-allowed", else: "hover:border-primary hover:bg-primary/5"}"}
                    >
                      <div class="flex flex-col items-center gap-3 text-base-content/60 group-hover:text-primary transition-colors">
                        <.icon name="hero-photo" class="w-12 h-12" />
                        <div class="text-center">
                          <p class="font-semibold text-sm">
                            {gettext("Select Featured Image")}
                          </p>
                          <p class="text-xs mt-1">
                            {gettext("Click to choose from media library")}
                          </p>
                        </div>
                      </div>
                    </button>
                  <% end %>

                  <%!-- Advanced: Manual ID Entry. `open` is server-state because
                       LV diffs would otherwise snap a browser-toggled `open` back
                       to false on every re-render. `phx-click` on the summary
                       prevents the native toggle so it stays in sync. --%>
                  <details
                    class="bg-base-200/50 mt-3 rounded-lg border border-base-300"
                    open={@featured_image_advanced_open}
                  >
                    <summary
                      phx-click="toggle_featured_image_advanced"
                      class="cursor-pointer select-none px-3 py-2 rounded-lg hover:bg-base-300/50 transition-colors list-none [&::-webkit-details-marker]:hidden"
                    >
                      <div class="flex items-center gap-1.5">
                        <.icon
                          name="hero-chevron-right"
                          class="w-3 h-3 transition-transform [[open]>&]:rotate-90"
                        />
                        <span class="text-xs font-medium text-base-content/70">
                          {gettext("Advanced: Manual Media ID")}
                        </span>
                      </div>
                    </summary>
                    <div class="px-3 pb-3 pt-2">
                      <input
                        type="text"
                        name="featured_image_uuid"
                        value={@form["featured_image_uuid"]}
                        class={"input input-bordered input-sm w-full font-mono text-xs #{if edit_disabled? or @viewing_older_version, do: "input-disabled bg-base-200"}"}
                        placeholder="018e3c4a-9f6b-7890-abcd-ef1234567890"
                        readonly={edit_disabled? or @viewing_older_version}
                      />
                      <p class="text-xs text-base-content/60 mt-2">
                        {gettext("Paste a Phoenix Kit Media ID if you know it.")}
                      </p>
                    </div>
                  </details>
                </div>

                <%!-- Featured post: pins to the top of the public listing and
                     renders larger. Whether featured posts show at all (and how
                     they look) is controlled per-group from the group's settings. --%>
                <div>
                  <label class="label cursor-pointer justify-start gap-3 py-1">
                    <%!-- The hidden "false" must be disabled in lockstep with the
                         checkbox: a disabled checkbox is excluded from form
                         serialization while an enabled hidden input is not, so a
                         still-enabled sibling control (e.g. the status select
                         while viewing an older version) would submit
                         featured=false and silently clobber the stored flag. --%>
                    <input
                      type="hidden"
                      name="featured"
                      value="false"
                      disabled={edit_disabled? or @viewing_older_version}
                    />
                    <input
                      type="checkbox"
                      id="post-featured-checkbox"
                      name="featured"
                      value="true"
                      checked={@form["featured"] in [true, "true"]}
                      disabled={edit_disabled? or @viewing_older_version}
                      class="checkbox checkbox-primary checkbox-sm"
                    />
                    <span class="label-text text-sm font-semibold text-base-content">
                      {gettext("Feature this post")}
                    </span>
                  </label>
                  <p class="text-xs text-base-content/60 mt-1 ml-1">
                    {gettext(
                      "Pins this post to the top of its listing and shows it larger. The group's settings control whether featured posts appear and how they're displayed."
                    )}
                  </p>
                </div>

                <%!-- Public version browsing. The public side already honours
                      this (post_rendering gates `?v=N` on it) and the mapper
                      reads it, but nothing ever WROTE it and no control existed.
                      Rides the form exactly like `featured`: a phx-click toggle
                      inside this form would fire the form's own change event,
                      and update_meta rebuilds :post from the form — clobbering
                      the value the click had just persisted. --%>
                <div>
                  <label class="label cursor-pointer justify-start gap-2 py-1">
                    <input
                      type="hidden"
                      name="allow_version_access"
                      value="false"
                      disabled={edit_disabled? or @viewing_older_version}
                    />
                    <input
                      type="checkbox"
                      id="post-version-access-checkbox"
                      name="allow_version_access"
                      value="true"
                      checked={@form["allow_version_access"] in [true, "true"]}
                      disabled={edit_disabled? or @viewing_older_version}
                      class="checkbox checkbox-primary checkbox-sm"
                    />
                    <span class="label-text text-sm font-semibold text-base-content">
                      {gettext("Let readers browse older versions")}
                    </span>
                  </label>
                  <p class="text-xs text-base-content/60 mt-1 ml-1">
                    {gettext(
                      "Adds ?v=N access to this post's published versions. Off by default — only the live version is public."
                    )}
                  </p>
                </div>

                <%!-- Categories — version-level, edited through the form and
                     written by the ordinary save (see the component doc). --%>
                <.live_component
                  module={PhoenixKit.Modules.Publishing.Web.Components.CategoriesPicker}
                  id="post-categories-picker"
                  group_slug={@group_slug}
                  selected={@form["category_uuids"] || []}
                  language={@current_language}
                  disabled={edit_disabled? or @viewing_older_version}
                />

                <%!-- Audio version — a player renders above the post content
                     when set; the RSS feed carries it as an enclosure. --%>
                <div>
                  <label class="label py-1" for="post-audio-input">
                    <span class="label-text text-sm font-semibold text-base-content">
                      {gettext("Audio version")}
                    </span>
                  </label>
                  <div class="flex items-center gap-2">
                    <input
                      type="text"
                      id="post-audio-input"
                      name="audio_uuid"
                      value={@form["audio_uuid"]}
                      class={"input input-bordered input-sm w-full font-mono text-xs #{if edit_disabled? or @viewing_older_version, do: "input-disabled bg-base-200"}"}
                      placeholder="018e3c4a-9f6b-7890-abcd-ef1234567890"
                      readonly={edit_disabled? or @viewing_older_version}
                    />
                    <%!-- Browsing beats hunting a uuid in the media library:
                          the selector is the same one the featured image uses,
                          targeted at this field. --%>
                    <button
                      :if={not (edit_disabled? or @viewing_older_version)}
                      type="button"
                      phx-click="open_media_selector"
                      disabled={edit_disabled? or @viewing_older_version}
                      phx-value-field="audio_uuid"
                      class="btn btn-outline btn-sm shrink-0"
                    >
                      <.icon name="hero-musical-note" class="w-4 h-4" />
                      {gettext("Choose")}
                    </button>
                    <button
                      :if={
                        not (edit_disabled? or @viewing_older_version) and
                          @form["audio_uuid"] not in [nil, ""]
                      }
                      type="button"
                      phx-click="clear_audio"
                      phx-disable-with={gettext("Removing…")}
                      disabled={edit_disabled? or @viewing_older_version}
                      class="btn btn-ghost btn-sm shrink-0"
                      title={gettext("Remove the audio version")}
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                  <p class="text-xs text-base-content/60 mt-1">
                    {gettext(
                      "An audio file (e.g. a narration). Shows a player above the post and rides the RSS feed as a podcast enclosure."
                    )}
                  </p>
                </div>

                <%!-- Social / OpenGraph overrides (per-language). See the comment
                     on the Manual Media ID details above — `open` is server-state. --%>
                <details
                  class="bg-base-200/50 rounded-lg border border-base-300"
                  open={@og_overrides_open}
                >
                  <summary
                    phx-click="toggle_og_overrides"
                    class="cursor-pointer select-none px-3 py-2 rounded-lg hover:bg-base-300/50 transition-colors list-none [&::-webkit-details-marker]:hidden"
                  >
                    <div class="flex items-center gap-1.5">
                      <.icon
                        name="hero-chevron-right"
                        class="w-3 h-3 transition-transform [[open]>&]:rotate-90"
                      />
                      <.icon name="hero-share" class="w-3.5 h-3.5 text-base-content/70" />
                      <span class="text-xs font-medium text-base-content/70">
                        {gettext("Social / OpenGraph")}
                      </span>
                    </div>
                  </summary>
                  <div class="px-3 pb-3 pt-2 space-y-3">
                    <p class="text-xs text-base-content/60">
                      {gettext(
                        "Override how this post looks when shared on social media. Leave a field blank to use the post's own title, description, or featured image."
                      )}
                    </p>
                    <div
                      :if={@og_module_active?}
                      class="rounded-md border border-info/30 bg-info/5 px-2.5 py-2 text-xs text-info-content flex items-start gap-2"
                    >
                      <.icon name="hero-share" class="w-3.5 h-3.5 mt-0.5 shrink-0 text-info" />
                      <span>
                        {gettext(
                          "The OpenGraph plugin is enabled — the final image is generated from a template. Values you set below feed into that template (title, description, image) in place of the post's own; leave a field blank to use the post default."
                        )}
                      </span>
                    </div>

                    <div>
                      <label class="label py-1">
                        <span class="label-text text-xs font-medium">{gettext("OG title")}</span>
                      </label>
                      <input
                        type="text"
                        name="og_title"
                        value={@form["og_title"]}
                        class={"input input-bordered input-sm w-full #{if edit_disabled? or @viewing_older_version, do: "input-disabled bg-base-200"}"}
                        placeholder={
                          Map.get(@post.metadata, :title) || gettext("Defaults to post title")
                        }
                        readonly={edit_disabled? or @viewing_older_version}
                      />
                    </div>

                    <div>
                      <label class="label py-1">
                        <span class="label-text text-xs font-medium">
                          {gettext("OG description")}
                        </span>
                      </label>
                      <textarea
                        name="og_description"
                        rows="2"
                        class={"textarea textarea-bordered textarea-sm w-full #{if edit_disabled? or @viewing_older_version, do: "textarea-disabled bg-base-200"}"}
                        placeholder={
                          Map.get(@post.metadata, :description) ||
                            gettext("Defaults to post description")
                        }
                        readonly={edit_disabled? or @viewing_older_version}
                      >{@form["og_description"]}</textarea>
                    </div>

                    <div>
                      <label class="label py-1">
                        <span class="label-text text-xs font-medium">{gettext("OG image")}</span>
                      </label>
                      <%!-- Hidden field carries the UUID; the picker writes it. --%>
                      <input type="hidden" name="og_image_uuid" value={@form["og_image_uuid"]} />
                      <%= if preview_url = featured_image_preview_url(@form["og_image_uuid"]) do %>
                        <div class="space-y-2">
                          <img
                            src={preview_url}
                            alt={gettext("OG image preview")}
                            class="w-full rounded-lg border-2 border-base-300 object-cover max-h-40"
                            loading="lazy"
                          />
                          <%= if not (edit_disabled? or @viewing_older_version) do %>
                            <div class="flex gap-2">
                              <button
                                type="button"
                                phx-click="open_media_selector"
                                disabled={edit_disabled? or @viewing_older_version}
                                phx-value-field="og_image_uuid"
                                class="btn btn-outline btn-xs flex-1"
                              >
                                <.icon name="hero-arrow-path" class="w-3 h-3 mr-1" />
                                {gettext("Change")}
                              </button>
                              <button
                                type="button"
                                phx-click="clear_og_image"
                                disabled={edit_disabled? or @viewing_older_version}
                                phx-disable-with={gettext("Removing…")}
                                class="btn btn-outline btn-error btn-xs flex-1"
                              >
                                <.icon name="hero-trash" class="w-3 h-3 mr-1" />
                                {gettext("Remove")}
                              </button>
                            </div>
                          <% end %>
                        </div>
                      <% else %>
                        <%= if edit_disabled? or @viewing_older_version do %>
                          <p class="text-xs text-base-content/60">
                            {gettext("No OG image set.")}
                          </p>
                        <% else %>
                          <button
                            type="button"
                            phx-click="open_media_selector"
                            disabled={edit_disabled? or @viewing_older_version}
                            phx-value-field="og_image_uuid"
                            class="btn btn-outline btn-xs w-full"
                          >
                            <.icon name="hero-photo" class="w-3 h-3 mr-1" />
                            {gettext("Choose OG image")}
                          </button>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                </details>

                <%!-- OpenGraph plugin preview — only visible when the
                     plugin is enabled AND a template resolves for this
                     post. Sits below the manual override so the two
                     surfaces line up visually. --%>
                <details
                  :if={@og_module_active? and og_preview_url(@post, @current_language)}
                  class="bg-base-200/50 rounded-lg border border-base-300"
                  open
                >
                  <summary class="cursor-pointer select-none px-3 py-2 rounded-lg hover:bg-base-300/50 transition-colors list-none [&::-webkit-details-marker]:hidden">
                    <div class="flex items-center gap-1.5">
                      <.icon
                        name="hero-chevron-right"
                        class="w-3 h-3 transition-transform [[open]>&]:rotate-90"
                      />
                      <.icon
                        name="hero-photo"
                        class="w-3.5 h-3.5 text-base-content/70"
                      />
                      <span class="text-xs font-medium text-base-content/70">
                        {gettext("Generated OG image")}
                      </span>
                    </div>
                  </summary>
                  <div class="px-3 pb-3 pt-2 space-y-2">
                    <p class="text-xs text-base-content/60">
                      {gettext(
                        "This is the image the OG plugin will show on social shares for this post — rendered from the assigned template using the values set above."
                      )}
                    </p>
                    <img
                      src={og_preview_url(@post, @current_language)}
                      alt={gettext("Generated OG image preview")}
                      class="w-full rounded-lg border-2 border-base-300"
                      loading="lazy"
                    />
                  </div>
                </details>

                <%!-- Status (version-level, applies to all languages) --%>
                <div>
                  <label class="label">
                    <span class="label-text text-sm font-semibold text-base-content">
                      {gettext("Status")}
                    </span>
                  </label>
                  <label class={"select w-full #{if edit_disabled?, do: "select-disabled bg-base-200"}"}>
                    <select
                      name="status"
                      disabled={edit_disabled?}
                    >
                      <%= if @viewing_older_version do %>
                        <option
                          value="published"
                          selected={@form["status"] in [Constants.status_draft(), Constants.status_published()]}
                        >
                          {gettext("Published")}
                        </option>
                        <option value="archived" selected={@form["status"] == "archived"}>
                          {gettext("Archived")}
                        </option>
                      <% else %>
                        <option value="draft" selected={@form["status"] == "draft"}>
                          {gettext("Draft")}
                        </option>
                        <option value="published" selected={Constants.published?(@form["status"])}>
                          {gettext("Published")}
                        </option>
                        <option value="archived" selected={@form["status"] == "archived"}>
                          {gettext("Archived")}
                        </option>
                      <% end %>
                    </select>
                  </label>
                  <p class="text-xs text-base-content/50 mt-1">
                    {gettext("Applies to all languages in this version.")}
                  </p>
                  <%!-- Publishing archives the version that is live now
                        (Persistence calls publish_version, which does that
                        atomically). A select can't carry a data-confirm, so
                        say it plainly before the writer saves rather than
                        after — but only when it is actually true. --%>
                  <p
                    :if={version_to_be_archived(assigns)}
                    class="text-xs text-warning mt-1 flex items-start gap-1"
                  >
                    <.icon name="hero-exclamation-triangle" class="w-3 h-3 mt-0.5 shrink-0" />
                    {gettext(
                      "Saving will publish this version and archive v%{version}, which is live now.",
                      version: version_to_be_archived(assigns)
                    )}
                  </p>
                </div>

                <%!-- Publication date (version-level) --%>
                <div>
                  <label class="label">
                    <span class="label-text text-sm font-semibold text-base-content">
                      {gettext("Publication Date & Time (UTC)")}
                    </span>
                  </label>
                  <input
                    type="datetime-local"
                    name="published_at"
                    value={datetime_local_value(@form["published_at"])}
                    class={"input input-bordered w-full #{if edit_disabled? or @viewing_older_version, do: "input-disabled bg-base-200"}"}
                    readonly={edit_disabled? or @viewing_older_version}
                  />
                </div>

                <%!-- Clear translation button (for any language with existing content) --%>
                <% translation_exists = @current_language in (@post[:available_languages] || []) %>
                <%= if translation_exists do %>
                  <button
                    type="button"
                    phx-click="clear_translation"
                    phx-disable-with={gettext("Clearing…")}
                    disabled={edit_disabled?}
                    class="btn btn-outline btn-error btn-sm w-full gap-2"
                    data-confirm={
                      gettext(
                        "Clear the %{language} translation content? You can always add a new translation for this language later.",
                        language: @current_language_name
                      )
                    }
                  >
                    <.icon name="hero-trash" class="w-4 h-4" />
                    {gettext("Clear translation")}
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </.form>
    </div>
    </div>

    <%!-- New Version Modal --%>
    <%= if @show_new_version_modal do %>
    <div class="modal modal-open">
      <div class="modal-box max-w-md max-h-[80vh] flex flex-col">
        <h3 class="font-bold text-lg mb-4">{gettext("Create New Version")}</h3>

        <p class="text-sm text-base-content/70 mb-4">
          {gettext("Choose how to create the new version:")}
        </p>

        <div class="space-y-2 overflow-y-auto flex-1 pr-1">
          <%!-- Blank option --%>
          <label class="flex items-center gap-3 p-3 rounded-lg border border-base-300 hover:bg-base-200 cursor-pointer">
            <input
              type="radio"
              name="version_source"
              class="radio radio-primary"
              checked={@new_version_source == nil}
              phx-click="set_new_version_source"
              phx-value-source="blank"
            />
            <div class="flex-1">
              <div class="font-medium">{gettext("Start blank")}</div>
              <div class="text-xs text-base-content/60">
                {gettext("Create an empty version with no content")}
              </div>
            </div>
          </label>

          <%!-- Existing versions --%>
          <%= for version <- Enum.sort(@available_versions, :desc) do %>
            <% status = Map.get(@version_statuses, version, "draft") %>
            <label class="flex items-center gap-3 p-3 rounded-lg border border-base-300 hover:bg-base-200 cursor-pointer">
              <input
                type="radio"
                name="version_source"
                class="radio radio-primary"
                checked={@new_version_source == version}
                phx-click="set_new_version_source"
                phx-value-source={version}
              />
              <div class="flex-1">
                <div class="flex items-center gap-1.5">
                  <span class="font-medium">
                    {gettext("Copy from v%{version}", version: version)}
                  </span>
                  <span class={[
                    "badge badge-xs h-auto",
                    Constants.published?(status) && "badge-success",
                    status == "draft" && "badge-warning",
                    status == "archived" && "badge-ghost"
                  ]}>
                    {status}
                  </span>
                </div>
                <div class="text-xs text-base-content/60">
                  {gettext("Duplicate all content and translations from version %{version}",
                    version: version
                  )}
                </div>
              </div>
            </label>
          <% end %>
        </div>

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-ghost"
            phx-click="close_new_version_modal"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            class="btn btn-primary"
            phx-click="create_version_from_source"
            phx-disable-with={gettext("Creating…")}
            disabled={edit_disabled?}
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {gettext("Create Version")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop bg-base-content/50" phx-click="close_new_version_modal"></div>
    </div>
    <% end %>

    <%!-- URL Slug Conflict Modal --%>
    <%= if @show_slug_conflict_modal and @slug_conflict_info do %>
    <div class="modal modal-open">
      <div class="modal-box max-w-md">
        <h3 class="font-bold text-lg mb-2 flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-warning" />
          {gettext("URL slug already in use")}
        </h3>

        <p class="text-sm text-base-content/80 mb-3">
          {gettext("The URL slug %{slug} is already used by another post in this group:",
            slug: "“#{@slug_conflict_info.slug}”"
          )}
        </p>

        <div class="rounded-lg border border-base-300 bg-base-200 p-3 mb-4">
          <p class="font-medium">
            {@slug_conflict_info.title || gettext("Another post")}
          </p>
          <%= if @slug_conflict_info.edit_url do %>
          <.link
            navigate={@slug_conflict_info.edit_url}
            class="link link-primary text-sm inline-flex items-center gap-1 mt-1"
          >
            <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
            {gettext("Open that post")}
          </.link>
          <% end %>
        </div>

        <p class="text-sm text-base-content/70 mb-4">
          {gettext("Choose a different URL slug for this post, or change the other post's slug.")}
        </p>

        <div class="modal-action">
          <button type="button" class="btn btn-primary" phx-click="close_slug_conflict_modal">
            {gettext("OK")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop bg-base-content/50" phx-click="close_slug_conflict_modal"></div>
    </div>
    <% end %>

    <%!-- Translation Confirmation Modal --%>
    <.confirm_modal
    show={@show_translation_confirm}
    on_confirm="confirm_translation"
    on_cancel="cancel_translation"
    title={gettext("Confirm Translation")}
    title_icon="hero-language"
    messages={@translation_warnings}
    prompt={gettext("Do you want to continue with the translation?")}
    confirm_text={gettext("Translate")}
    cancel_text={gettext("Cancel")}
    confirm_icon="hero-language"
    />

    <%!-- Unsaved-changes confirmation (server-rendered; replaces the old JS confirm()) --%>
    <.confirm_modal
    show={@show_cancel_confirm}
    on_confirm="cancel"
    on_cancel="dismiss_cancel_confirm"
    title={gettext("Unsaved changes")}
    title_icon="hero-exclamation-triangle"
    prompt={gettext("You have unsaved changes. Leave without saving?")}
    confirm_text={gettext("Leave")}
    cancel_text={gettext("Keep editing")}
    danger={true}
    />

    <%!-- Media Selector Modal.

         The audio slot gets a picker that only contains audio. It used to
         show the whole library and refuse a wrong pick afterwards, which
         put the mistake after the effort — you browse, choose a file, and
         only then find out that kind isn't allowed. The server-side check
         stays as the backstop for anything that reaches the handler by
         another route. --%>
    <.live_component
    module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
    id="media-selector-modal"
    show={@show_media_selector}
    mode={@media_selection_mode}
    selected_uuids={@media_selected_uuids}
    file_type_filter={media_filter_for_target(@media_selector_target)}
    lock_file_type={@media_selector_target in ["audio_uuid", "audio_component", "gallery"]}
    phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
    />
    """
  end
end
