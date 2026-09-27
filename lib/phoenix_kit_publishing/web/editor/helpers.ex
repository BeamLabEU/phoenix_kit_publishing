defmodule PhoenixKit.Modules.Publishing.Web.Editor.Helpers do
  @moduledoc """
  Shared helper functions for the publishing editor.

  Contains utilities for URL building, language handling,
  virtual post creation, and other common operations.
  """

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.Web.Editor.Translation
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Utils.Routes

  @handover_timeout_ms 1_500

  # ============================================================================
  # Language Helpers
  # ============================================================================

  @doc """
  Assigns current language with enabled/known status.
  """
  @spec assign_current_language(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_current_language(socket, language_code) do
    enabled_languages = socket.assigns[:all_enabled_languages] || []
    lang_info = Publishing.get_language_info(language_code)
    default_language = LanguageHelpers.get_primary_language()

    # Get language names for display
    current_language_name = if lang_info, do: lang_info.name, else: String.upcase(language_code)
    default_language_name = get_language_name(default_language)

    socket
    |> Phoenix.Component.assign(:current_language, language_code)
    |> Phoenix.Component.assign(:current_language_name, current_language_name)
    |> Phoenix.Component.assign(:default_language, default_language)
    |> Phoenix.Component.assign(:default_language_name, default_language_name)
    |> Phoenix.Component.assign(:is_primary_language, language_code == default_language)
    |> Phoenix.Component.assign(
      :current_language_enabled,
      Publishing.language_enabled?(language_code, enabled_languages)
    )
    |> Phoenix.Component.assign(:current_language_known, lang_info != nil)
    |> Translation.maybe_clear_completed_translation_status()
  end

  @doc """
  Gets the language name for a language code.
  """
  @spec get_language_name(String.t()) :: String.t()
  def get_language_name(language_code) do
    case Publishing.get_language_info(language_code) do
      %{name: name} -> name
      _ -> String.upcase(language_code)
    end
  end

  @doc """
  Formats a list of language codes for display.
  """
  @spec format_language_list(term()) :: String.t()
  def format_language_list(language_codes) when is_list(language_codes) do
    count = length(language_codes)

    cond do
      count == 0 ->
        ""

      count <= 3 ->
        Enum.map_join(language_codes, ", ", &get_language_name/1)

      true ->
        "#{count} languages"
    end
  end

  def format_language_list(_), do: ""

  @doc """
  Gets the editor language from assigns.
  """
  @spec editor_language(map()) :: String.t()
  def editor_language(assigns) do
    assigns[:current_language] ||
      assigns |> Map.get(:post, %{}) |> Map.get(:language) ||
      hd(Publishing.enabled_language_codes())
  end

  @doc """
  Builds language data for the publishing_language_switcher component.
  """
  @spec build_editor_languages(map(), [String.t()], String.t()) :: [map()]
  def build_editor_languages(post, enabled_languages, current_language) do
    post_primary = LanguageHelpers.get_primary_language()

    all_languages =
      Publishing.order_languages_for_display(
        post.available_languages || [],
        enabled_languages,
        post_primary
      )

    language_statuses = Map.get(post, :language_statuses) || %{}

    Enum.map(all_languages, fn lang_code ->
      lang_info = Publishing.get_language_info(lang_code)
      content_exists = lang_code in (post.available_languages || [])
      is_current = lang_code == current_language
      is_enabled = Publishing.language_enabled?(lang_code, enabled_languages)
      is_known = lang_info != nil
      status = Map.get(language_statuses, lang_code)
      display_code = Publishing.get_display_code(lang_code, enabled_languages)

      %{
        code: lang_code,
        display_code: display_code,
        name: if(lang_info, do: lang_info.name, else: lang_code),
        flag: if(lang_info, do: lang_info.flag, else: ""),
        status: status,
        exists: content_exists,
        is_current: is_current,
        enabled: is_enabled,
        known: is_known,
        # is_default is used for ordering only, not for special UI treatment
        is_default: lang_code == post_primary,
        uuid: post[:uuid]
      }
    end)
  end

  # ============================================================================
  # URL Helpers
  # ============================================================================

  @doc """
  Builds the public URL for a post.
  """
  @spec build_public_url(map(), String.t() | nil) :: String.t() | nil
  def build_public_url(post, language) do
    if Constants.published?(Map.get(post.metadata, :status)) do
      build_url_for_mode(post, language)
    else
      nil
    end
  end

  defp build_url_for_mode(post, language) do
    group_slug = post.group || "group"

    mode = Map.get(post, :mode)

    cond do
      Constants.slug_mode?(mode) -> build_slug_mode_url(group_slug, post, language)
      Constants.timestamp_mode?(mode) -> build_timestamp_mode_url(group_slug, post, language)
      true -> nil
    end
  end

  defp build_slug_mode_url(group_slug, post, language) do
    if post.slug do
      PublishingHTML.build_post_url(group_slug, post, language)
    else
      nil
    end
  end

  defp build_timestamp_mode_url(group_slug, post, language) do
    if post.metadata.published_at do
      case DateTime.from_iso8601(post.metadata.published_at) do
        {:ok, _datetime, _} -> PublishingHTML.build_post_url(group_slug, post, language)
        _ -> nil
      end
    else
      nil
    end
  end

  @doc """
  Builds the inline `<Image>` PHK component markup for a storage file.

  The component carries the **file UUID**, not a resolved URL — the renderer
  (`PhoenixKit.Modules.Shared.Components.Image`) resolves it to a URL at render
  time via `Storage.get_public_url_by_uuid/2`. Storing the UUID instead of a
  signed URL keeps the reference stable across `url_prefix` changes,
  `secret_key_base` rotation, and content moved between environments — the same
  late-resolution the featured image already uses.

  Alt text is derived from the file's original name (falling back to `"Image"`),
  sanitised so it can't break out of the XML attribute.
  """
  @spec image_component_markup(String.t()) :: String.t()
  def image_component_markup(file_uuid) when is_binary(file_uuid) do
    # The uuid comes from the server-side media picker, so it's a real UUID in
    # practice — but strip anything outside the UUID charset before interpolating
    # into markup that flows through the `escape: false` renderer, so the insert
    # path stays safe even if it ever accepts a less-trusted id. (alt text is
    # already sanitised in alt_from_filename/1.)
    safe_uuid = String.replace(file_uuid, ~r/[^0-9a-fA-F-]/, "")
    ~s(\n<Image file_uuid="#{safe_uuid}" alt="#{alt_from_file(file_uuid)}"/>\n)
  end

  @doc """
  Marks the editor clean — to us AND to Leaf.

  "The content is saved now" has to be said twice, because two things track
  it independently: `has_pending_changes`, which drives the badge and arms
  autosave, and Leaf's own snapshot, which drives its navigation guard. Only
  the first was ever set, so the guard believed every saved post still had
  unsaved work and challenged the reader on every refresh and every attempt
  to leave.

  One function rather than a line at each of the dozen places that go clean,
  because that is exactly the shape that drifted the first time.

  `send_update` messages are processed after the current handler returns,
  in order, so a `set_editor_content/2` in the same pipeline — which carries
  its own `mark_saved` — never races this one.
  """
  @spec mark_clean(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def mark_clean(socket) do
    Phoenix.LiveView.send_update(Leaf, id: "content-editor", action: :mark_saved)
    Phoenix.Component.assign(socket, :has_pending_changes, false)
  end

  @doc """
  Replaces the text in the editor — ours AND Leaf's.

  `@content` reaches Leaf once, on its first render: the surface is
  `phx-update="ignore"`, so assigning a new value afterwards changes nothing
  on screen. A new document reaches the client through `action: :set_content`
  alone. Every place that swapped the buffer — a language or version switch,
  a lock takeover, a reload after someone else saved, a spectator sync — used
  to push a `"set-content"` event instead, which core's MarkdownEditor hook
  listened for and Leaf never did; so since the move to Leaf each of them
  left the previous text in the editor until the page was reloaded.

  `mark_saved` follows `has_pending_changes` as it stands when this is
  called, so the two clean-state trackers (`mark_clean/1`) keep agreeing:
  a buffer adopted with pending work stays dirty, a reload reads clean.

  The document is also asked straight back, through a flush with a
  correlation ref. Leaf runs its commands in order, so the `{:leaf_flushed,
  ref}` reply can only arrive once the surface holds `content`; anything
  the surface says before it — Leaf flushes on blur, and the click that
  switches language or version blurs the editor first — was typed into or
  flushed out of the document just replaced. The editor drops those until
  the ref is back (`awaiting_buffer_ref`), which is what stopped a switch
  from autosaving the English body into the Russian row.
  """
  @spec set_editor_content(Phoenix.LiveView.Socket.t(), String.t() | nil, keyword()) ::
          Phoenix.LiveView.Socket.t()
  def set_editor_content(socket, content, opts \\ []) do
    content = content || ""
    ref = "buffer-#{System.unique_integer([:positive])}"

    Phoenix.LiveView.send_update(Leaf,
      id: "content-editor",
      action: :set_content,
      content: content,
      mark_saved: !socket.assigns[:has_pending_changes]
    )

    Phoenix.LiveView.send_update(Leaf, id: "content-editor", action: :flush, ref: ref)
    # An unanswered hand-over is retried once, then abandoned (`Web.Editor`).
    Process.send_after(self(), {:handover_check, ref}, @handover_timeout_ms)

    socket
    |> Phoenix.Component.assign(:content, content)
    |> Phoenix.Component.assign(:awaiting_buffer_ref, ref)
    |> then(fn socket ->
      if Keyword.get(opts, :retry, false),
        do: socket,
        else: Phoenix.Component.assign(socket, :handover_retried?, false)
    end)
  end

  @doc """
  A `<Gallery>` block wrapping one `<Image>` line per chosen file.

  Uuids rather than signed URLs: the URL is then resolved at render time, so
  the post survives a change of storage prefix or signing secret instead of
  carrying a frozen link that quietly rots.
  """
  @spec gallery_markup(list()) :: String.t()
  def gallery_markup(file_uuids) when is_list(file_uuids) do
    lines =
      file_uuids
      |> Enum.filter(&is_binary/1)
      |> Enum.map_join("\n", fn uuid ->
        safe = String.replace(uuid, ~r/[^0-9a-fA-F-]/, "")
        ~s(<Image file_uuid="#{safe}" alt="#{alt_from_file(uuid)}"/>)
      end)

    ~s(\n<Gallery height="520" radius="420" turns="2">\n#{lines}\n</Gallery>\n)
  end

  @doc """
  An inline `<Audio>` player for a chosen file. Distinct from the sidebar's
  "Audio version", which is the whole post read aloud — this one drops a
  player at the cursor.
  """
  @spec audio_component_markup(String.t()) :: String.t()
  def audio_component_markup(file_uuid) when is_binary(file_uuid) do
    safe = String.replace(file_uuid, ~r/[^0-9a-fA-F-]/, "")
    ~s(\n<Audio file_uuid="#{safe}" title="#{alt_from_file(file_uuid)}"/>\n)
  end

  defp alt_from_file(file_uuid) do
    case safe_get_file(file_uuid) do
      %{original_file_name: name} when is_binary(name) and name != "" ->
        alt_from_filename(name)

      _ ->
        "Image"
    end
  end

  # Turn a stored filename into human-ish alt text, stripped of any characters
  # that would terminate the `alt="..."` attribute or the component tag.
  defp alt_from_filename(name) do
    name
    |> Path.rootname()
    |> String.replace(~r/[_-]+/u, " ")
    |> String.replace(~r/["'<>\r\n]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 100)
    |> case do
      "" -> "Image"
      alt -> alt
    end
  end

  # Best-effort: a storage/repo hiccup must never block inserting an image —
  # we just fall back to a generic alt. Logged at debug so a persistent failure
  # (every image degrading to alt="Image") is still diagnosable.
  defp safe_get_file(file_uuid) do
    Storage.get_file(file_uuid)
  rescue
    error ->
      Logger.debug(
        "Publishing: failed to resolve file #{file_uuid} for alt text: #{inspect(error)}"
      )

      nil
  end

  # ============================================================================
  # Virtual Post Building
  # ============================================================================

  @doc """
  Builds a virtual post for new post creation.
  """
  @spec build_virtual_post(String.t(), term(), String.t(), DateTime.t()) :: map()
  def build_virtual_post(group_slug, "slug", primary_language, now) do
    %{
      group: group_slug,
      date: nil,
      time: nil,
      metadata: %{
        title: "",
        status: "draft",
        published_at: DateTime.to_iso8601(now),
        slug: "",
        featured_image_uuid: nil
      },
      content: "",
      language: primary_language,
      available_languages: [],
      mode: :slug,
      slug: nil
    }
  end

  def build_virtual_post(group_slug, _mode, primary_language, now) do
    date = DateTime.to_date(now)
    time = DateTime.to_time(now)

    %{
      group: group_slug,
      date: date,
      time: time,
      metadata: %{
        title: "",
        status: "draft",
        published_at: DateTime.to_iso8601(now),
        featured_image_uuid: nil
      },
      content: "",
      language: primary_language,
      available_languages: [],
      mode: :timestamp
    }
  end

  @doc """
  Builds a virtual translation for a new language.
  """
  @spec build_virtual_translation(
          map(),
          String.t() | nil,
          String.t(),
          Phoenix.LiveView.Socket.t()
        ) :: map()
  def build_virtual_translation(post, group_slug, new_language, socket) do
    post
    |> Map.put(:language, new_language)
    |> Map.put(:group, group_slug || "group")
    |> Map.put(:content, "")
    |> Map.put(:metadata, Map.put(post.metadata, :title, ""))
    |> Map.put(:mode, post.mode)
    |> Map.put(:slug, post.slug || Map.get(socket.assigns.form, "slug"))
  end

  # ============================================================================
  # Featured Image Helpers
  # ============================================================================

  @doc """
  Gets the preview URL for a featured image.
  """
  @spec featured_image_preview_url(term()) :: String.t() | nil
  def featured_image_preview_url(value) do
    case sanitize_featured_image_uuid(value) do
      nil ->
        nil

      file_uuid ->
        PublishingHTML.featured_image_url(
          %{metadata: %{featured_image_uuid: file_uuid}},
          "medium"
        )
    end
  end

  @doc """
  Sanitizes a featured image ID value.
  """
  @spec sanitize_featured_image_uuid(term()) :: String.t() | nil
  def sanitize_featured_image_uuid(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def sanitize_featured_image_uuid(_), do: nil

  # ============================================================================
  # URL Construction Helpers
  # ============================================================================

  @doc """
  Builds the URL for a post overview page.
  """
  @spec build_post_url(String.t(), map()) :: String.t()
  def build_post_url(group_slug, post) do
    Routes.path("/admin/publishing/#{group_slug}/#{require_uuid!(post)}")
  end

  @doc """
  Builds the URL for the post editor.

  Options: `:version`, `:lang`
  """
  @spec build_edit_url(String.t(), map(), keyword()) :: String.t()
  def build_edit_url(group_slug, post, opts \\ []) do
    uuid = require_uuid!(post)
    base = "/admin/publishing/#{group_slug}/#{uuid}/edit"
    params = build_query_params(opts)

    if params == "" do
      Routes.path(base)
    else
      Routes.path("#{base}?#{params}")
    end
  end

  @doc """
  Builds the URL for the post preview.
  """
  @spec build_preview_url(String.t(), map()) :: String.t()
  def build_preview_url(group_slug, post) do
    Routes.path("/admin/publishing/#{group_slug}/#{require_uuid!(post)}/preview")
  end

  @doc """
  Builds the URL for creating a new post.
  """
  @spec build_new_post_url(String.t()) :: String.t()
  def build_new_post_url(group_slug) do
    Routes.path("/admin/publishing/#{group_slug}/new")
  end

  defp build_query_params(opts) do
    params =
      []
      |> maybe_add_param("v", opts[:version])
      |> maybe_add_param("lang", opts[:lang])

    URI.encode_query(params)
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: [{key, value} | params]

  defp require_uuid!(post) do
    case post[:uuid] do
      nil -> raise ArgumentError, "post UUID is required for URL construction, got nil"
      uuid -> uuid
    end
  end
end
