defmodule PhoenixKit.Modules.Publishing.Web.Editor.Translation do
  @moduledoc """
  AI translation functionality for the publishing editor.

  Handles translation workflow, Oban job enqueuing, and
  translation progress tracking.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Errors
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PresenceHelpers
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.TranslationManager
  alias PhoenixKitAI, as: AI
  alias PhoenixKitAI.Translations
  alias PhoenixKitPublishing.AITranslatable

  # PhoenixKitAI's generic translation worker. Referenced as a module (not a bare
  # string) so the name stays in sync and the coupling is greppable;
  # `Oban.Job.worker` stores `inspect/1` of the worker module.
  @translate_worker PhoenixKitAI.TranslateWorker

  # ============================================================================
  # Availability Checks
  # ============================================================================

  # Availability + endpoint/prompt listing are generic across every
  # AI-translation consumer, so they delegate to
  # `PhoenixKitAI.Translations` — the canonical implementation —
  # rather than re-deriving the same `{uuid, name}` shape here. (Catalogue
  # and projects share the same core helpers.) Publishing keeps its own
  # *default* endpoint/prompt resolution below, since those read
  # publishing-specific setting keys + the publishing-specific prompt slug.

  @doc """
  Checks if AI translation is available (AI module installed + enabled + endpoints configured).
  """
  def ai_translation_available?, do: Translations.available?()

  @doc """
  Lists available AI endpoints for translation as `[{uuid, name}]`.
  """
  def list_ai_endpoints, do: Translations.list_endpoints()

  @doc """
  Lists available AI prompts for translation as `[{uuid, name}]`.
  """
  def list_ai_prompts, do: Translations.list_prompts()

  # Default endpoint/prompt resolution is domain logic shared with the
  # programmatic bulk API — TranslationManager owns it so the two paths can't
  # drift. These stay as the editor's entry points but just delegate.

  @doc """
  Gets the default AI endpoint UUID from settings.
  """
  def get_default_ai_endpoint_uuid, do: TranslationManager.default_endpoint_uuid()

  @doc """
  Gets the default AI prompt UUID for translation (setting, then slug fallback).
  """
  def get_default_ai_prompt_uuid, do: TranslationManager.default_prompt_uuid()

  @doc """
  Checks if the default translation prompt already exists.
  """
  def default_translation_prompt_exists?, do: TranslationManager.default_prompt_exists?()

  @doc """
  Whether the persisted default prompt is **stale** — it exists but predates the
  lowercase-placeholder standardization, so it still references `{{Title}}`/
  `{{Content}}` and would not bind the adapter's `title`/`content` keys (the
  model would hallucinate). Drives a "Regenerate default prompt" affordance so a
  stale row isn't a dead end (the "Generate" button hides once a prompt exists).
  """
  def default_translation_prompt_stale? do
    case persisted_default_prompt() do
      %{content: content} when is_binary(content) ->
        not (String.contains?(content, "{{title}}") and String.contains?(content, "{{content}}"))

      _ ->
        false
    end
  end

  @doc """
  Repairs a stale default prompt by rewriting its content to the current
  template **in place** (preserving its uuid + any endpoint wiring), or creates
  it if absent. Returns `{:ok, prompt}` or `{:error, reason}`.
  """
  def regenerate_default_translation_prompt do
    case persisted_default_prompt() do
      nil -> generate_default_translation_prompt()
      prompt -> AI.update_prompt(prompt, %{content: default_prompt_content()})
    end
  end

  defp persisted_default_prompt do
    if Code.ensure_loaded?(PhoenixKitAI) and AI.enabled?() do
      AI.get_prompt_by_slug(TranslationManager.translation_prompt_slug())
    else
      nil
    end
  end

  @doc """
  Generates the default translation prompt in the AI prompts system.
  Returns {:ok, prompt} or {:error, changeset}.
  """
  def generate_default_translation_prompt do
    AI.create_prompt(%{
      name: "Translate Publishing Posts",
      description: "Default prompt for translating publishing posts between languages",
      content: default_prompt_content()
    })
  end

  @doc """
  The shipped translation prompt template.

  The `{{title}}` / `{{content}}` placeholders are **lowercase on purpose** —
  they must match, byte-for-byte, the keys `AITranslatable.source_fields/2`
  binds (the same lowercase convention as the catalogue and projects prompts),
  because core's prompt-variable substitution (`PhoenixKitAI.Prompt.render`) is
  case-sensitive and silently leaves an unmatched `{{Var}}` literal in the
  prompt. The defensive "skip a value that is still a literal placeholder"
  rule makes a binding mismatch **fail closed** (the field is skipped, the job
  fails cleanly on a missing marker) rather than producing a hallucinated
  translation. `editor_translation_test.exs` pins the placeholder↔key invariant
  so the two can't drift apart again. Exposed (not inlined) so that test can
  read the template without writing a DB row.
  """
  @spec default_prompt_content() :: String.t()
  def default_prompt_content do
    """
    Translate the following content from {{SourceLanguage}} to {{TargetLanguage}}.

    RULES:
    - Preserve the EXACT formatting of the original (headings, line breaks, spacing, etc.)
    - If the original has a # heading, keep it. If it doesn't, don't add one.
    - Preserve all Markdown formatting (bold, italic, links, code blocks, lists)
    - Do NOT translate text inside code blocks or inline code
    - Translate naturally and idiomatically
    - Keep HTML tags and special syntax unchanged

    OUTPUT FORMAT - respond with ONLY this format, nothing else before or after:

    ---TITLE---
    [translated title - just the title text, no # symbol]
    ---SLUG---
    [url-friendly-slug-in-target-language]
    ---CONTENT---
    [translated content - preserve EXACT original formatting]

    Skip any field whose source value below is missing, blank, or still a
    literal placeholder (e.g. a value that looks like `{{title}}` means the
    caller did not bind it) — do NOT emit its marker, and do NOT translate the
    placeholder text itself.

    SLUG RULES:
    - Lowercase letters only (a-z)
    - Numbers allowed (0-9)
    - Use hyphens (-) to separate words
    - No spaces, accents, or special characters
    - Keep it short and SEO-friendly
    - Example: "getting-started" -> "primeros-pasos" (Spanish)

    === SOURCE CONTENT ===

    Title: {{title}}

    {{content}}
    """
  end

  # ============================================================================
  # Target Language Resolution
  # ============================================================================

  @doc """
  Gets target languages for translation (missing languages only).
  """
  def get_target_languages_for_translation(socket) do
    # Core owns the "enabled minus primary minus already-translated" rule
    # (same helper catalogue/projects use) — don't re-derive it here.
    Translations.missing_languages(
      Publishing.enabled_language_codes(),
      LanguageHelpers.get_primary_language(),
      socket.assigns.post.available_languages || []
    )
  end

  @doc """
  Gets all target languages for translation (all except primary).
  """
  def get_all_target_languages(_socket) do
    # "All enabled except primary" is the missing-languages rule with an empty
    # existing-set.
    Translations.missing_languages(
      Publishing.enabled_language_codes(),
      LanguageHelpers.get_primary_language(),
      []
    )
  end

  # ============================================================================
  # Translation Enqueuing
  # ============================================================================

  @doc """
  Enqueues translation job with validation and warnings.
  Returns {:noreply, socket} for use in handle_event.
  """
  def enqueue_translation(socket, target_languages, {empty_level, empty_message}) do
    cond do
      socket.assigns.is_new_post ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Please save the post first before translating")
         )}

      is_nil(socket.assigns.ai_selected_endpoint_uuid) ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, gettext("Please select an AI endpoint"))}

      is_nil(socket.assigns[:ai_selected_prompt_uuid]) ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, gettext("Please select an AI prompt"))}

      target_languages == [] ->
        {:noreply, Phoenix.LiveView.put_flash(socket, empty_level, empty_message)}

      true ->
        # Build list of warnings for the confirmation modal
        warnings = build_translation_warnings(socket, target_languages)

        if warnings == [] do
          # No warnings - proceed directly
          do_enqueue_translation(socket, target_languages)
        else
          # Show confirmation modal with warnings
          {:noreply,
           socket
           |> Phoenix.Component.assign(:show_translation_confirm, true)
           |> Phoenix.Component.assign(:pending_translation_languages, target_languages)
           |> Phoenix.Component.assign(:translation_warnings, warnings)}
        end
    end
  end

  @doc """
  Actually enqueues the translation job (after confirmation if needed).
  """
  def do_enqueue_translation(socket, target_languages) do
    user = socket.assigns[:phoenix_kit_current_scope]
    user_uuid = if user, do: user.user.uuid, else: nil
    post = socket.assigns.post

    # Source is ALWAYS the primary language (the canonical content), never the
    # language the editor happens to be viewing — otherwise "translate this
    # language" on a non-primary page would translate it into itself, and
    # "translate all/missing" would translate from a translation. Matches the
    # source used by build_translation_warnings/2.
    source_language = source_language_for_translation(socket)

    # One Oban job per target language (PhoenixKitAI's generic pipeline) so they run
    # in parallel — replaces the legacy single-job sequential worker.
    base_params = %{
      resource_type: AITranslatable.resource_type(),
      resource_uuid: post.uuid,
      endpoint_uuid: socket.assigns.ai_selected_endpoint_uuid,
      prompt_uuid: socket.assigns[:ai_selected_prompt_uuid],
      source_lang: source_language,
      actor_uuid: user_uuid,
      # Translate the version the editor is on (a draft, not always the active
      # one). Core threads this scope to AITranslatable.fetch/3 and keys job
      # dedup on it, so v1 and v2 translate independently.
      resource_scope: version_scope(socket)
    }

    case Translations.enqueue_all_missing(base_params, target_languages) do
      {:ok, %{in_flight: []}} ->
        {:noreply, translation_error_socket(socket)}

      {:ok, %{in_flight: in_flight}} ->
        # Tell every editor session on THIS version (incl. this one) to show
        # progress + lock; other-version editors ignore it (scope mismatch).
        PublishingPubSub.broadcast_translation_started(
          socket.assigns.group_slug,
          post.uuid,
          in_flight,
          version_scope(socket)
        )

        {:noreply, translation_success_socket(socket, in_flight)}

      {:error, reason} ->
        {:noreply, translation_error_socket(socket, reason)}
    end
  end

  defp translation_success_socket(socket, target_languages) do
    lang_names =
      Enum.map_join(target_languages, ", ", fn code ->
        info = Publishing.get_language_info(code)
        if info, do: info.name, else: code
      end)

    socket
    |> Phoenix.Component.assign(:ai_translation_status, :enqueued)
    |> Phoenix.LiveView.put_flash(
      :info,
      gettext("Translation job enqueued for: %{languages}", languages: lang_names)
    )
  end

  defp translation_error_socket(socket, reason \\ nil) do
    detail = if reason, do: " " <> Errors.message(reason), else: ""

    socket
    |> Phoenix.Component.assign(:ai_translation_status, :error)
    |> Phoenix.LiveView.put_flash(
      :error,
      gettext("Couldn't start the translation job.") <> detail
    )
  end

  # ============================================================================
  # Translation Warnings
  # ============================================================================

  @doc """
  Builds warnings for the translation confirmation modal.
  """
  def build_translation_warnings(socket, target_languages) do
    warnings = []

    # Warn about a blank source, distinguishing which field is missing. The
    # source has two translatable fields (title + body content), so a blanket
    # "content is empty" misleads when only the title is filled — that title
    # still translates fine.
    warnings =
      case source_blank_state(socket) do
        {true, true} ->
          [
            {:warning,
             gettext("The source has no title or content — the translations will be empty.")}
            | warnings
          ]

        {false, true} ->
          [
            {:warning,
             gettext("The source has no body content — only the title will be translated.")}
            | warnings
          ]

        {true, false} ->
          [
            {:warning,
             gettext("The source has no title — only the body content will be translated.")}
            | warnings
          ]

        {false, false} ->
          warnings
      end

    # Check if any target languages have existing content that will be overwritten
    existing_languages = get_existing_translation_languages(socket, target_languages)

    warnings =
      if existing_languages != [] do
        lang_names = format_language_names(existing_languages)

        [
          {:warning,
           gettext("This will overwrite existing content in: %{languages}",
             languages: lang_names
           )}
          | warnings
        ]
      else
        warnings
      end

    # Check if any target languages are currently being edited by other users
    active_editors = get_active_editors_for_languages(socket, target_languages)

    warnings =
      if active_editors != [] do
        editor_warnings =
          Enum.map(active_editors, fn {lang_code, editor_email} ->
            lang_name = get_language_display_name(lang_code)

            {:warning,
             gettext(
               "%{language} is currently being edited by %{user}. They will be locked out and unsaved changes will be discarded.",
               language: lang_name,
               user: editor_email
             )}
          end)

        editor_warnings ++ warnings
      else
        warnings
      end

    # Also check source language
    warnings = check_source_language_editor(socket, warnings)

    Enum.reverse(warnings)
  end

  defp get_active_editors_for_languages(socket, target_languages) do
    post = socket.assigns.post
    group_slug = socket.assigns.group_slug

    Enum.flat_map(target_languages, fn lang_code ->
      form_key =
        PublishingPubSub.generate_form_key(group_slug, %{uuid: post.uuid, language: lang_code})

      form_key
      |> PresenceHelpers.get_lock_owner()
      |> other_editor_for_language(socket, lang_code)
    end)
  end

  @doc """
  Returns the source language for translation based on the post's primary language
  or the system default.
  """
  def source_language_for_translation(_socket) do
    LanguageHelpers.get_primary_language()
  end

  # The version the editor is on, as the string `resource_scope` the core
  # pipeline threads to `AITranslatable.fetch/3` and keys job dedup on. `nil`
  # (no current version) → the post's active version.
  defp version_scope(socket) do
    case socket.assigns[:current_version] do
      nil -> nil
      version -> to_string(version)
    end
  end

  defp check_source_language_editor(socket, warnings) do
    post = socket.assigns.post
    group_slug = socket.assigns.group_slug
    source_language = source_language_for_translation(socket)
    current_language = socket.assigns[:current_language]

    # If we're currently on the source language, we are the editor — no warning needed
    if current_language == source_language do
      warnings
    else
      form_key =
        PublishingPubSub.generate_form_key(group_slug, %{
          uuid: post.uuid,
          language: source_language
        })

      form_key
      |> PresenceHelpers.get_lock_owner()
      |> source_editor_warning(socket, source_language, warnings)
    end
  end

  defp other_editor_for_language(nil, _socket, _lang_code), do: []

  defp other_editor_for_language(owner_meta, socket, lang_code) do
    current_uuid = current_user_uuid(socket)
    if owner_meta.user_uuid != current_uuid, do: [{lang_code, owner_meta.user_email}], else: []
  end

  defp source_editor_warning(nil, _socket, _source_language, warnings), do: warnings

  defp source_editor_warning(owner_meta, socket, source_language, warnings) do
    current_uuid = current_user_uuid(socket)

    if owner_meta.user_uuid != current_uuid do
      lang_name = get_language_display_name(source_language)

      [
        {:warning,
         gettext(
           "%{language} (source) is currently being edited by %{user}. They will be locked out during translation.",
           language: lang_name,
           user: owner_meta.user_email
         )}
        | warnings
      ]
    else
      warnings
    end
  end

  defp current_user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      nil -> nil
      scope -> scope.user.uuid
    end
  end

  defp get_language_display_name(lang_code) do
    case Publishing.get_language_info(lang_code) do
      %{name: name} -> name
      _ -> String.upcase(lang_code)
    end
  end

  defp get_existing_translation_languages(socket, target_languages) do
    post = socket.assigns.post
    available = post.available_languages || []

    Enum.filter(target_languages, fn lang -> lang in available end)
  end

  defp format_language_names(language_codes) do
    Enum.map_join(language_codes, ", ", fn code ->
      info = Publishing.get_language_info(code)
      if info, do: info.name, else: code
    end)
  end

  @doc """
  Checks if the source body content is blank. Kept for callers that only care
  about the body; `source_blank_state/1` is the richer title+content variant.
  """
  def source_content_blank?(socket) do
    {_title_blank, content_blank} = source_blank_state(socket)
    content_blank
  end

  @doc """
  Returns `{title_blank?, content_blank?}` for the translation source.

  The source feeds two translatable fields — the title and the body content —
  so the confirmation modal can warn precisely (nothing, only-title, or
  only-content) instead of a blanket "content is empty". The effective title
  mirrors the adapter's `extract_title/1`: the first `# heading` of the body,
  else the stored/typed title (the default `"Untitled"` counts as no title).
  """
  def source_blank_state(socket) do
    {title, content} = source_title_and_content(socket)
    {blank_title?(title, content), String.trim(content) == ""}
  end

  # Source is ALWAYS the primary language (the content actually fed to the
  # translator), never the language the editor happens to be viewing — same
  # invariant as do_enqueue_translation/2 and build_translation_warnings/2.
  # When viewing the source language the live buffer is authoritative;
  # otherwise read the primary row from the database.
  defp source_title_and_content(socket) do
    post = socket.assigns.post
    source_language = source_language_for_translation(socket)
    current_version = socket.assigns[:current_version]

    if socket.assigns[:current_language] == source_language do
      {live_form_title(socket), socket.assigns.content || ""}
    else
      case Publishing.read_post_by_uuid(post.uuid, source_language, current_version) do
        {:ok, source_post} ->
          {db_metadata_title(source_post), source_post.content || ""}

        # Can't read source - treat as fully blank to be safe.
        _ ->
          {"", ""}
      end
    end
  end

  defp live_form_title(socket) do
    socket.assigns |> Map.get(:form, %{}) |> Map.get("title", "")
  end

  defp db_metadata_title(post) do
    post |> Map.get(:metadata, %{}) |> Map.get(:title, "")
  end

  # Mirrors AITranslatable.extract_title/1: a `# heading` in the body wins,
  # otherwise the metadata/form title; the default "Untitled" is not a title.
  defp blank_title?(title_meta, content) do
    effective =
      case Regex.run(~r/^#\s+(.+)$/m, content || "") do
        [_, heading] -> String.trim(heading)
        nil -> title_meta |> to_string() |> String.trim()
      end

    effective == "" or effective == Constants.default_title()
  end

  # ============================================================================
  # Translation to Current Language
  # ============================================================================

  @doc """
  Starts translation to the current (non-primary) language.
  """
  def start_translation_to_current(socket) do
    cond do
      socket.assigns.is_new_post ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Please save the post first before translating")
         )}

      is_nil(socket.assigns.ai_selected_endpoint_uuid) ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, gettext("Please select an AI endpoint"))}

      is_nil(socket.assigns[:ai_selected_prompt_uuid]) ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, gettext("Please select an AI prompt"))}

      true ->
        target_language = socket.assigns.current_language
        # Enqueue as Oban job with single target language
        enqueue_translation(socket, [target_language], {:info, nil})
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @doc """
  Clears completed translation status when switching languages.
  """
  def maybe_clear_completed_translation_status(socket) do
    if socket.assigns[:ai_translation_status] == :completed do
      socket
      |> Phoenix.Component.assign(:ai_translation_status, nil)
      |> Phoenix.Component.assign(:ai_translation_progress, nil)
      |> Phoenix.Component.assign(:ai_translation_total, nil)
      |> Phoenix.Component.assign(:ai_translation_languages, [])
    else
      socket
    end
  end

  @doc """
  Restores translation status from an active Oban job if one exists for this post.
  Call on mount to survive page refreshes.
  """
  def maybe_restore_translation_status(socket) do
    post = socket.assigns[:post]

    if post && post[:uuid] do
      case in_flight_translation_languages(post.uuid, version_scope(socket)) do
        [] ->
          socket

        target_languages ->
          current_lang = socket.assigns[:current_language]
          source_language = LanguageHelpers.get_primary_language()

          # Lock this editor if the current language is being translated or is the source
          should_lock =
            current_lang != nil and
              (current_lang == source_language or current_lang in target_languages)

          socket
          |> Phoenix.Component.assign(:ai_translation_status, :in_progress)
          |> Phoenix.Component.assign(:ai_translation_progress, 0)
          |> Phoenix.Component.assign(:ai_translation_total, length(target_languages))
          |> Phoenix.Component.assign(:ai_translation_languages, target_languages)
          |> Phoenix.Component.assign(:translation_locked?, should_lock)
      end
    else
      socket
    end
  end

  # Target languages with a non-terminal PhoenixKitAI translation job for
  # THIS post AND THIS version (`scope`). Scoping by version matters now that
  # each version translates independently — otherwise a v2 editor would restore
  # v1's in-progress banner. `scope` is nil (active version) or the version
  # string; a job matches when its stored `resource_scope` equals it (both nil
  # ↔ unscoped/legacy jobs). Lets the editor restore the banner across a page
  # refresh. Fails open (empty) on any query error.
  defp in_flight_translation_languages(post_uuid, scope) do
    repo = PhoenixKit.RepoHelper.repo()

    query =
      from(j in Oban.Job,
        where: j.worker == ^inspect(@translate_worker),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        select: j.args
      )

    query
    |> repo.all()
    |> Enum.filter(fn args ->
      args["resource_type"] == AITranslatable.resource_type() and
        args["resource_uuid"] == post_uuid and
        args["resource_scope"] == scope
    end)
    |> Enum.map(& &1["target_lang"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    _ -> []
  end
end
