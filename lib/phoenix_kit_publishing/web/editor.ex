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
  use Gettext, backend: PhoenixKitWeb.Gettext

  # Suppress dialyzer warnings for pattern matches
  @dialyzer {:nowarn_function, handle_event: 3}

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI, as: AI

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

  # ============================================================================
  # Mount
  # ============================================================================

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"] || params["category"] || params["type"]

    live_source =
      socket.id ||
        "publishing-editor-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, "Publishing Editor")
      |> assign(:group_slug, group_slug)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> assign(:show_media_selector, false)
      |> assign(:media_selection_mode, :single)
      |> assign(:media_selected_uuids, MapSet.new())
      |> assign(:is_autosaving, false)
      |> assign(:autosave_timer, nil)
      |> assign(:slug_manually_set, false)
      |> assign(:last_auto_slug, "")
      |> assign(:url_slug_manually_set, false)
      |> assign(:last_auto_url_slug, "")
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
      |> assign(:default_language, nil)
      |> assign(:default_language_name, nil)
      |> assign(:available_languages, [])
      |> assign(:all_enabled_languages, [])
      |> assign(:has_pending_changes, false)
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
      |> assign(:show_ai_translation, false)
      |> assign(:ai_enabled, Code.ensure_loaded?(PhoenixKitAI) and AI.enabled?())
      |> assign(:ai_endpoints, Translation.list_ai_endpoints())
      |> assign(:ai_selected_endpoint_uuid, Translation.get_default_ai_endpoint_uuid())
      |> assign(:ai_prompts, Translation.list_ai_prompts())
      |> assign(:ai_selected_prompt_uuid, Translation.get_default_ai_prompt_uuid())
      |> assign(:ai_default_prompt_exists, Translation.default_translation_prompt_exists?())
      |> assign(:ai_translation_status, nil)
      |> assign(:ai_translation_progress, nil)
      |> assign(:ai_translation_total, nil)
      |> assign(:ai_translation_languages, [])
      |> assign(:translation_locked?, false)
      |> assign(:show_translation_confirm, false)
      |> assign(:pending_translation_languages, [])
      |> assign(:translation_warnings, [])
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
  def handle_params(%{"post_uuid" => post_uuid} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    handle_uuid_post_params(socket, post_uuid, params)
  end

  def handle_params(%{"path" => path} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    handle_path_post_params(socket, path, params)
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  defp handle_uuid_post_params(socket, post_uuid, params) do
    group_slug = socket.assigns.group_slug
    group_mode = Publishing.get_group_mode(group_slug)

    version = parse_version_param(params["v"])
    language = params["lang"]

    case Publishing.read_post_by_uuid(post_uuid, language, version) do
      {:ok, post} ->
        all_enabled_languages = Publishing.enabled_language_codes()

        old_form_key = socket.assigns[:form_key]

        old_post_slug =
          socket.assigns[:post] && PublishingPubSub.broadcast_id(socket.assigns.post)

        {socket, form_key} =
          if language && language not in post.available_languages do
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
          if requested_lang && requested_lang not in post.available_languages do
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
    form_key = PublishingPubSub.generate_form_key(group_slug, virtual_post, :new)

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
      |> assign(:has_pending_changes, false)
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
      |> assign(:has_pending_changes, false)
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

    is_published = form["status"] == "published"

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
      |> assign(:has_pending_changes, false)
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
      target = Map.get(params, "_target", [])
      params = prepare_meta_params(params, target, socket)

      new_form =
        socket.assigns.form
        |> Map.merge(params)
        |> Forms.normalize_form()

      {socket_with_slug, new_form, slug_events} =
        process_slug_updates(socket, params, target, new_form)

      has_changes = Forms.dirty?(socket_with_slug.assigns.post, new_form, socket.assigns.content)
      language = Helpers.editor_language(socket.assigns)

      {updated_post, public_url} =
        update_post_from_form(socket.assigns.post, new_form, language)

      socket =
        assign_meta_updates(
          socket_with_slug,
          new_form,
          updated_post,
          public_url,
          has_changes,
          slug_events
        )

      socket = if has_changes, do: schedule_autosave(socket), else: socket

      Collaborative.broadcast_form_change(socket, :meta, new_form)
      socket = Collaborative.touch_activity(socket)

      {:noreply, socket}
    end
  end

  def handle_event("update_content", %{"content" => content}, socket) do
    socket = maybe_reclaim_lock(socket)

    if socket.assigns.readonly? or socket.assigns.translation_locked? do
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

  def handle_event("regenerate_slug", _params, socket) do
    if socket.assigns.group_mode == "slug" do
      title = socket.assigns.form["title"] || ""

      {socket, new_form, slug_events} =
        Forms.maybe_update_slug_from_title(socket, title, force: true)

      has_changes = Forms.dirty?(socket.assigns.post, new_form, socket.assigns.content)

      {:noreply,
       socket
       |> assign(:form, new_form)
       |> assign(:has_pending_changes, has_changes)
       |> push_event("changes-status", %{has_changes: has_changes})
       |> Forms.push_slug_events(slug_events)}
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
      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("clear_translation", _params, socket) do
    group_slug = socket.assigns.group_slug
    post = socket.assigns.post
    language = socket.assigns.current_language
    post_uuid = post[:uuid]

    result = Publishing.clear_translation(group_slug, post_uuid, language)

    case result do
      :ok ->
        primary_lang = LanguageHelpers.get_primary_language()
        url = Helpers.build_edit_url(group_slug, post, lang: primary_lang)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Translation cleared"))
         |> push_navigate(to: url)}

      {:error, :last_language} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot remove the last language from a post"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to clear translation"))}
    end
  end

  # ============================================================================
  # Handle Events - Media
  # ============================================================================

  def handle_event("open_media_selector", _params, socket) do
    {:noreply, assign(socket, :show_media_selector, true)}
  end

  def handle_event("open_image_component_selector", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:inserting_image_component, true)}
  end

  def handle_event("insert_component", %{"component" => "video"}, socket) do
    {:noreply,
     push_event(socket, "phx:prompt-and-insert", %{
       component: "video",
       prompt: "Enter YouTube URL:",
       placeholder: "https://youtu.be/dQw4w9WgXcQ"
     })}
  end

  def handle_event("insert_component", %{"component" => "cta"}, socket) do
    template = """
    <CTA primary="true" action="/your-link">Button Text</CTA>
    """

    {:noreply, push_event(socket, "phx:insert-at-cursor", %{text: template})}
  end

  def handle_event("insert_video_component", %{"url" => url}, socket) do
    template = """

    <Video url="#{url}">
      Optional caption text
    </Video>

    """

    {:noreply, push_event(socket, "phx:insert-at-cursor", %{text: template})}
  end

  def handle_event("clear_featured_image", _params, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      updated_form = Map.put(socket.assigns.form, "featured_image_uuid", "")

      socket =
        socket
        |> assign(:form, updated_form)
        |> assign(:has_pending_changes, true)
        |> put_flash(:info, gettext("Featured image cleared"))
        |> push_event("changes-status", %{has_changes: true})
        |> schedule_autosave()

      {:noreply, socket}
    end
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

  def handle_event("generate_default_translation_prompt", _params, socket) do
    case Translation.generate_default_translation_prompt() do
      {:ok, prompt} ->
        {:noreply,
         socket
         |> assign(:ai_prompts, Translation.list_ai_prompts())
         |> assign(:ai_selected_prompt_uuid, prompt.uuid)
         |> assign(:ai_default_prompt_exists, true)
         |> Phoenix.LiveView.put_flash(:info, gettext("Default translation prompt created"))}

      {:error, _changeset} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Failed to create prompt. It may already exist.")
         )}
    end
  end

  def handle_event("translate_to_all_languages", _params, socket) do
    target_languages = Translation.get_all_target_languages(socket)
    empty_opts = {:warning, gettext("No other languages enabled to translate to")}
    Translation.enqueue_translation(socket, target_languages, empty_opts)
  end

  def handle_event("translate_missing_languages", _params, socket) do
    target_languages = Translation.get_target_languages_for_translation(socket)
    empty_opts = {:info, gettext("All languages already have translations")}
    Translation.enqueue_translation(socket, target_languages, empty_opts)
  end

  def handle_event("translate_to_this_language", _params, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      Translation.start_translation_to_current(socket)
    end
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

  def handle_event("toggle_version_access", %{"enabled" => enabled_str}, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      do_toggle_version_access(socket, enabled_str == "true")
    end
  end

  def handle_event("switch_version", %{"version" => version_str}, socket) do
    version = String.to_integer(version_str)

    if version == socket.assigns.current_version do
      {:noreply, socket}
    else
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

  def handle_event("set_new_version_source", %{"source" => "blank"}, socket) do
    {:noreply, assign(socket, :new_version_source, nil)}
  end

  def handle_event("set_new_version_source", %{"source" => version_str}, socket) do
    case Integer.parse(version_str) do
      {version, _} -> {:noreply, assign(socket, :new_version_source, version)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("create_version_from_source", _params, socket) do
    case Versions.create_version_from_source(socket) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  # ============================================================================
  # Handle Events - Language Switching
  # ============================================================================

  def handle_event("switch_language", %{"language" => new_language}, socket) do
    if socket.assigns[:is_new_post] do
      {:noreply,
       put_flash(socket, :warning, gettext("Save the post to enable language switching"))}
    else
      do_switch_language(socket, new_language)
    end
  end

  # ============================================================================
  # Handle Events - Navigation
  # ============================================================================

  def handle_event("preview", _params, socket) do
    # Save first if there are pending changes (autosave is 500ms but user might click fast)
    socket =
      if socket.assigns.has_pending_changes do
        {:noreply, saved} = Persistence.perform_save(socket)
        saved
      else
        socket
      end

    group_slug = socket.assigns.group_slug
    post = socket.assigns.post
    post_uuid = post[:uuid]
    language = socket.assigns.current_language
    version = socket.assigns[:current_version]

    query_params = %{"lang" => language}
    query_params = if version, do: Map.put(query_params, "v", version), else: query_params
    query = URI.encode_query(query_params)

    {:noreply,
     push_navigate(socket,
       to: Routes.path("/admin/publishing/#{group_slug}/#{post_uuid}/preview?#{query}")
     )}
  end

  def handle_event("attempt_cancel", _params, %{assigns: %{has_pending_changes: false}} = socket) do
    handle_event("cancel", %{}, socket)
  end

  def handle_event("attempt_cancel", _params, socket) do
    {:noreply, push_event(socket, "confirm-navigation", %{})}
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

  defp do_toggle_version_access(socket, enabled) do
    post = socket.assigns.post
    group_slug = socket.assigns.group_slug

    updated_metadata = Map.put(post.metadata, :allow_version_access, enabled)
    updated_post = %{post | metadata: updated_metadata}

    scope = socket.assigns[:phoenix_kit_current_scope]
    params = %{"allow_version_access" => enabled}

    case Publishing.update_post(group_slug, updated_post, params, %{scope: scope}) do
      {:ok, saved_post} ->
        flash_msg = version_access_flash(enabled)

        {:noreply,
         socket
         |> assign(:post, saved_post)
         |> put_flash(:info, flash_msg)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update version access setting"))}
    end
  end

  defp version_access_flash(true),
    do: gettext("Version access enabled - older versions are now publicly accessible")

  defp version_access_flash(false),
    do: gettext("Version access disabled - only live version is publicly accessible")

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
      |> then(fn p ->
        if form_url_slug && form_url_slug != "",
          do: Map.put(p, :url_slug, form_url_slug),
          else: p
      end)

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

  defp assign_meta_updates(socket, new_form, updated_post, public_url, has_changes, slug_events) do
    socket
    |> assign(:form, new_form)
    |> assign(:post, updated_post)
    |> assign(:slug_manually_set, socket.assigns.slug_manually_set)
    |> assign(:url_slug_manually_set, socket.assigns.url_slug_manually_set)
    |> assign(:has_pending_changes, has_changes)
    |> assign(:public_url, public_url)
    |> clear_flash()
    |> push_event("changes-status", %{has_changes: has_changes})
    |> Forms.push_slug_events(slug_events)
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
    if socket.assigns.has_pending_changes and not socket.assigns.translation_locked? do
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
    if socket.assigns[:readonly?] do
      {:noreply, assign(socket, :show_media_selector, false)}
    else
      handle_media_selected(socket, file_uuids)
    end
  end

  def handle_info({:media_selector_closed}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, false)
     |> assign(:inserting_image_component, false)}
  end

  def handle_info({:editor_content_changed, %{content: content}}, socket) do
    has_changes = Forms.dirty?(socket.assigns.post, socket.assigns.form, content)

    socket =
      socket
      |> assign(:content, content)
      |> assign(:has_pending_changes, has_changes)
      |> push_event("changes-status", %{has_changes: has_changes})

    socket = if has_changes, do: schedule_autosave(socket), else: socket

    {:noreply, socket}
  end

  def handle_info({:editor_insert_component, %{type: :image}}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:inserting_image_component, true)}
  end

  def handle_info({:editor_insert_component, %{type: :video}}, socket) do
    {:noreply, push_event(socket, "prompt-and-insert", %{type: "video"})}
  end

  def handle_info({:editor_insert_component, _}, socket), do: {:noreply, socket}
  def handle_info({:editor_save_requested, _}, socket), do: {:noreply, socket}

  # ============================================================================
  # Handle Info - Collaborative Editing
  # ============================================================================

  def handle_info({:editor_saved, form_key, source}, socket) do
    cond do
      socket.assigns.form_key == nil ->
        {:noreply, socket}

      form_key != socket.assigns.form_key ->
        {:noreply, socket}

      source == socket.id ->
        {:noreply, socket}

      true ->
        socket = Persistence.reload_post(socket)
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

  def handle_info({:translation_started, group_slug, post_identifier, target_languages}, socket) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) do
      current_lang = socket.assigns[:current_language]
      source_lang = source_language_for_translation(socket)
      should_lock = current_lang == source_lang or current_lang in target_languages

      {:noreply,
       socket
       |> assign(:ai_translation_status, :in_progress)
       |> assign(:ai_translation_progress, 0)
       |> assign(:ai_translation_total, length(target_languages))
       |> assign(:ai_translation_languages, target_languages)
       |> assign(:translation_locked?, should_lock)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:translation_progress, group_slug, post_identifier, completed, total, _last_language},
        socket
      ) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) do
      socket =
        socket
        |> assign(:ai_translation_status, :in_progress)
        |> assign(:ai_translation_progress, completed)
        |> assign(:ai_translation_total, total)
        |> Persistence.refresh_available_languages()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:translation_completed, group_slug, post_identifier, results}, socket) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) do
      flash_msg =
        if results.failure_count > 0 do
          gettext("Translation completed with %{success} succeeded, %{failed} failed",
            success: results.success_count,
            failed: results.failure_count
          )
        else
          gettext("Translation completed successfully for %{count} languages",
            count: results.success_count
          )
        end

      flash_level = if results.failure_count > 0, do: :warning, else: :info

      current_language = socket.assigns[:current_language]
      succeeded_languages = results[:succeeded] || []

      socket =
        socket
        |> assign(:ai_translation_status, :completed)
        |> assign(:ai_translation_languages, [])
        |> assign(:translation_locked?, false)

      socket =
        if current_language in succeeded_languages do
          Persistence.reload_translated_content(socket, flash_msg, flash_level)
        else
          # Reload source language content too (worker reads from DB, no conflict)
          socket
          |> Persistence.refresh_available_languages()
          |> put_flash(flash_level, flash_msg)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:translation_created, group_slug, post_identifier, language}, socket) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) do
      case re_read_post(socket, socket.assigns[:current_language]) do
        {:ok, updated_post} ->
          socket =
            socket
            |> assign(:available_languages, updated_post.available_languages)
            |> assign(
              :post,
              socket.assigns.post
              |> Map.put(:available_languages, updated_post.available_languages)
              |> Map.put(:language_statuses, updated_post.language_statuses)
            )

          {:noreply, socket}

        {:error, _} ->
          available = socket.assigns[:available_languages] || []

          if language in available do
            {:noreply, socket}
          else
            {:noreply, assign(socket, :available_languages, available ++ [language])}
          end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:translation_deleted, group_slug, post_identifier, language}, socket) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) do
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

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp source_language_for_translation(socket) do
    Translation.source_language_for_translation(socket)
  end

  # Matches a broadcast identifier (UUID) against the current post.
  defp post_matches?(socket, broadcast_id) do
    post = socket.assigns[:post]
    post != nil && post[:uuid] == broadcast_id
  end

  defp reload_post_on_lock_acquired(socket) do
    case re_read_post(socket, socket.assigns[:current_language]) do
      {:ok, post} ->
        form = Forms.post_form(post)

        socket
        |> assign(:post, %{post | group: socket.assigns.group_slug})
        |> Forms.assign_form_with_tracking(form)
        |> assign(:content, post.content)
        |> assign(:has_pending_changes, false)
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

  defp schedule_autosave(socket) do
    if socket.assigns.autosave_timer do
      Process.cancel_timer(socket.assigns.autosave_timer)
    end

    # Save quickly — DB writes are ~5ms, no reason to delay
    timer_ref = Process.send_after(self(), :autosave, 500)
    assign(socket, :autosave_timer, timer_ref)
  end

  defp re_read_post(socket, language) do
    case socket.assigns[:post] do
      nil -> {:error, :no_post}
      %{uuid: nil} -> {:error, :no_uuid}
      post -> Publishing.read_post_by_uuid(post.uuid, language)
    end
  end

  defp do_switch_language(socket, new_language) do
    # Cancel any pending autosave before switching language context
    if timer = socket.assigns[:autosave_timer] do
      Process.cancel_timer(timer)
    end

    socket = assign(socket, :autosave_timer, nil)
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
      |> assign(:has_pending_changes, false)
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

  defp handle_media_selected(socket, file_ids) do
    file_uuid = List.first(file_ids)
    inserting_image_component = Map.get(socket.assigns, :inserting_image_component, false)

    {socket, autosave?} =
      cond do
        file_uuid && inserting_image_component ->
          file_url = Helpers.get_file_url(file_uuid)

          js_code =
            "window.publishingEditorInsertMedia && window.publishingEditorInsertMedia(#{Jason.encode!(file_url)}, 'image')"

          {
            socket
            |> assign(:show_media_selector, false)
            |> assign(:inserting_image_component, false)
            |> put_flash(:info, gettext("Image component inserted"))
            |> push_event("exec-js", %{js: js_code}),
            false
          }

        file_uuid ->
          {
            socket
            |> assign(:form, Forms.update_form_with_media(socket.assigns.form, file_uuid))
            |> assign(:has_pending_changes, true)
            |> assign(:show_media_selector, false)
            |> put_flash(:info, gettext("Featured image selected"))
            |> push_event("changes-status", %{has_changes: true}),
            true
          }

        true ->
          {socket |> assign(:show_media_selector, false), false}
      end

    socket = if autosave?, do: schedule_autosave(socket), else: socket

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <% nonce = assigns[:script_csp_nonce] || assigns[:csp_nonce] || "" %>
    <% edit_disabled? = @readonly? or @translation_locked? %>

    <%!-- Unsaved changes tracking and navigation protection --%>
    <script nonce={nonce}>
    (function() {
      // Track unsaved changes state
      window.editorUnsavedChanges = false;

      // Save immediately when user switches tabs or minimizes
      document.addEventListener("visibilitychange", function() {
        if (document.hidden && window.editorUnsavedChanges) {
          // Trigger LiveView save event via hidden button
          const saveBtn = document.querySelector("[phx-click='save']");
          if (saveBtn) saveBtn.click();
        }
      });

      // Browser exit protection — save before leaving
      window.addEventListener("beforeunload", function(e) {
        if (window.editorUnsavedChanges) {
          // Try to trigger save (may not complete before page unloads)
          const saveBtn = document.querySelector("[phx-click='save']");
          if (saveBtn) saveBtn.click();
          e.preventDefault();
          e.returnValue = "";
          return "";
        }
      });

      // Intercept navigation links — save first, then navigate
      document.addEventListener("click", function(e) {
        if (window.editorUnsavedChanges) {
          const link = e.target.closest("a[href], a[data-phx-link]");
          if (link && !link.hasAttribute("data-confirm")) {
            const href = link.getAttribute("href") || link.getAttribute("data-phx-link");
            if (href && !href.startsWith("http") && !href.startsWith("#")) {
              e.preventDefault();
              e.stopPropagation();
              // Save first, then ask to confirm navigation
              const saveBtn = document.querySelector("[phx-click='save']");
              if (saveBtn) saveBtn.click();
              // Small delay to let save complete, then confirm
              setTimeout(function() {
                document.getElementById("confirm-cancel-btn").click();
              }, 100);
            }
          }
        }
      }, true);

      // Listen for changes status from LiveView
      window.addEventListener("phx:changes-status", function(e) {
        window.editorUnsavedChanges = e.detail.has_changes;
      });

      // Listen for confirm navigation event
      window.addEventListener("phx:confirm-navigation", function(_e) {
        if (confirm("You have unsaved changes. Are you sure you want to leave?")) {
          document.getElementById("confirm-cancel-btn").click();
        }
      });

      // Listen for slug update event from LiveView
      window.addEventListener("phx:update-slug", function(e) {
        const slugInput = document.getElementById("slug-input");
        if (slugInput && e.detail.slug) {
          slugInput.value = e.detail.slug;
        }
      });

      // Listen for url_slug update event from LiveView (for translations)
      window.addEventListener("phx:update-url-slug", function(e) {
        const urlSlugInput = document.getElementById("url-slug-input");
        if (urlSlugInput && e.detail.url_slug) {
          urlSlugInput.value = e.detail.url_slug;
        }
      });

      // Listen for exec-js events from LiveView (for media insertion)
      window.addEventListener("phx:exec-js", (e) => {
        try {
          eval(e.detail.js);
        } catch (err) {
          console.error("[ContentEditor] Error executing JS:", err);
        }
      });

      // Listen for video prompt event
      window.addEventListener("phx:prompt-and-insert", (e) => {
        const url = window.prompt("Enter YouTube URL:", "https://youtu.be/dQw4w9WgXcQ");
        if (url && url.trim()) {
          window.publishingEditorInsertMedia(null, 'video', url.trim());
        }
      });

      // Function to insert standard markdown media syntax at cursor position
      window.publishingEditorInsertMedia = function(fileUrl, mediaType, videoUrl) {
        const textarea = document.getElementById('content-editor-textarea');
        if (!textarea) return;

        // Build standard markdown syntax: ![alt](url)
        let template;
        if (mediaType === 'image' && fileUrl) {
          template = '\n![Image description](' + fileUrl + ')\n';
        } else if (mediaType === 'video') {
          const url = videoUrl || fileUrl || '';
          template = '\n![Video](' + url + ')\n';
        } else {
          return;
        }

        const start = textarea.selectionStart || 0;
        const currentValue = textarea.value;
        const newValue = currentValue.substring(0, start) + template + currentValue.substring(start);
        textarea.value = newValue;

        // Move cursor after inserted text
        const newPos = start + template.length;
        textarea.selectionStart = textarea.selectionEnd = newPos;
        textarea.focus();

        // Trigger keyup event to update LiveView (matches phx-keyup binding on textarea)
        textarea.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true }));
      };
    })();
    </script>
    <%!-- Hidden confirmation button for JavaScript --%>
    <button
    id="confirm-cancel-btn"
    type="button"
    phx-click="cancel"
    class="hidden"
    aria-hidden="true"
    >
    </button>

    <div class="container mx-auto px-4 py-6 space-y-6">
    <div class="flex flex-wrap items-center justify-between gap-2">
      <button type="button" class="btn btn-ghost btn-sm" phx-click="back_to_list">
        <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> {gettext("Back to %{group}",
          group: @group_name || gettext("Group")
        )}
      </button>
      <div class="flex items-center gap-2">
        <%= unless @is_new_post do %>
          <button
            type="button"
            class="btn btn-outline btn-xs sm:btn-sm shadow-none"
            phx-click="preview"
          >
            <.icon name="hero-eye" class="w-4 h-4 sm:mr-1" />
            <span class="hidden sm:inline">{gettext("Preview")}</span>
          </button>
        <% end %>
        <%= if @form["status"] == "published" && @public_url do %>
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
            <span class="hidden sm:inline">View Public</span>
          </a>
        <% end %>
      </div>
    </div>

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
              {gettext(
                "Your editing lock expired due to inactivity. Start typing or click Save to resume editing."
              )}
            </span>
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
                  "Automatically translate this post to other languages using AI. The translation will be queued as a background job."
                )}
              <% else %>
                {gettext(
                  "Translate the %{source} post to %{target} using AI. The translation will be queued as a background job.",
                  source: @default_language_name,
                  target: @current_language_name
                )}
              <% end %>
            </p>

            <%!-- Endpoint Selection --%>
            <div class="space-y-1">
              <form phx-change="select_ai_endpoint">
                <select
                  class="select select-bordered select-sm w-full"
                  name="endpoint_uuid"
                >
                  <option value="">{gettext("Select an endpoint...")}</option>
                  <%= for {id, name} <- @ai_endpoints do %>
                    <option value={id} selected={@ai_selected_endpoint_uuid == id}>
                      {name}
                    </option>
                  <% end %>
                </select>
              </form>
              <.link
                navigate={PhoenixKit.Utils.Routes.path("/admin/ai/endpoints")}
                class="text-xs link link-primary"
              >
                {gettext("Manage Endpoints")}
              </.link>
            </div>

            <%!-- Prompt Selection --%>
            <div class="space-y-1">
              <form phx-change="select_ai_prompt">
                <select
                  class="select select-bordered select-sm w-full"
                  name="prompt_uuid"
                >
                  <option value="">{gettext("Select a prompt...")}</option>
                  <%= for {id, name} <- @ai_prompts do %>
                    <option value={id} selected={@ai_selected_prompt_uuid == id}>
                      {name}
                    </option>
                  <% end %>
                </select>
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
                    class="btn btn-outline btn-xs gap-1"
                    phx-click="generate_default_translation_prompt"
                  >
                    <.icon name="hero-sparkles" class="w-3 h-3" />
                    {gettext("Generate Default Prompt")}
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
                  disabled={
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
                  disabled={
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
                  disabled={
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

            <div class="card bg-base-100 shadow-xl border border-base-200">
              <div class="card-body space-y-4">
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
                  class={"input input-bordered w-full text-2xl font-semibold #{if edit_disabled? or @viewing_older_version, do: "input-disabled bg-base-200"}"}
                  placeholder={gettext("Post title")}
                  readonly={edit_disabled? or @viewing_older_version}
                />
                <%!-- Markdown Editor Component --%>
                <.live_component
                  module={PhoenixKitWeb.Components.Core.MarkdownEditor}
                  id="content-editor"
                  content={@content}
                  placeholder={gettext("Write your content here...")}
                  height="480px"
                  debounce={400}
                  toolbar={[:image, :video]}
                  show_formatting_toolbar={not (edit_disabled? or @viewing_older_version)}
                  protect_navigation={false}
                  script_nonce={nonce}
                  readonly={edit_disabled? or @viewing_older_version}
                />
              </div>
            </div>
          </div>

          <%!-- Right column: Version Settings (global, shared across all languages) --%>
          <div class="lg:w-80 space-y-4">
            <div class="card bg-base-100 shadow-xl border border-base-200">
              <div class="card-body space-y-4">
                <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                  {gettext("Version Settings")}
                </h3>

                <%!-- Slug (slug-mode groups only) --%>
                <%= if @group_mode == "slug" do %>
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
                    <p class="text-xs text-base-content/60 mt-1">
                      {gettext("Use lowercase letters, numbers, and hyphens only.")}
                    </p>
                  </div>
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
                              class="btn btn-primary btn-sm shadow-lg"
                            >
                              <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" />
                              {gettext("Change")}
                            </button>
                            <button
                              type="button"
                              phx-click="clear_featured_image"
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
                            class="btn btn-primary btn-sm flex-1"
                          >
                            <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" />
                            {gettext("Change")}
                          </button>
                          <button
                            type="button"
                            phx-click="clear_featured_image"
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
                      class={"w-full border-2 border-dashed border-base-300 rounded-lg p-8 transition-all group #{if edit_disabled? or @viewing_older_version, do: "opacity-50 cursor-not-allowed", else: "hover:border-primary hover:bg-primary/5"}"}
                      disabled={edit_disabled? or @viewing_older_version}
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

                  <%!-- Advanced: Manual ID Entry (Collapsed by default) --%>
                  <details
                    class="bg-base-200/50 mt-3 rounded-lg border border-base-300"
                    open={false}
                  >
                    <summary class="cursor-pointer select-none px-3 py-2 rounded-lg hover:bg-base-300/50 transition-colors list-none [&::-webkit-details-marker]:hidden">
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

                <%!-- Status (version-level, applies to all languages) --%>
                <div>
                  <label class="label">
                    <span class="label-text text-sm font-semibold text-base-content">
                      {gettext("Status")}
                    </span>
                  </label>
                  <select
                    class={"select select-bordered w-full #{if edit_disabled?, do: "select-disabled bg-base-200"}"}
                    name="status"
                    disabled={edit_disabled?}
                  >
                    <%= if @viewing_older_version do %>
                      <option
                        value="published"
                        selected={@form["status"] in ["draft", "published"]}
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
                      <option value="published" selected={@form["status"] == "published"}>
                        {gettext("Published")}
                      </option>
                      <option value="archived" selected={@form["status"] == "archived"}>
                        {gettext("Archived")}
                      </option>
                    <% end %>
                  </select>
                  <p class="text-xs text-base-content/50 mt-1">
                    {gettext("Applies to all languages in this version.")}
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
                    status == "published" && "badge-success",
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
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {gettext("Create Version")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop bg-base-content/50" phx-click="close_new_version_modal"></div>
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

    <%!-- Media Selector Modal --%>
    <.live_component
    module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
    id="media-selector-modal"
    show={@show_media_selector}
    mode={@media_selection_mode}
    selected_uuids={@media_selected_uuids}
    phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
    />
    """
  end
end
