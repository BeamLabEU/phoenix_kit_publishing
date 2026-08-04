defmodule PhoenixKit.Modules.Publishing.TranslationManager do
  @moduledoc """
  Language and translation management for the Publishing module.

  Handles adding/removing languages and AI-powered translation.
  """

  require Logger

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Modules.Publishing.StaleFixer
  alias PhoenixKit.Settings
  alias PhoenixKitAI.Translations
  alias PhoenixKitPublishing.AITranslatable

  # Slug of the publishing-specific default translation prompt. Canonical here
  # (domain) so the editor LiveView and the programmatic bulk API resolve the
  # default endpoint/prompt the same way — the editor delegates to these.
  @translation_prompt_slug "translate-publishing-posts"

  @doc """
  Resolves the default AI endpoint UUID for publishing translation.

  Prefers the `publishing_translation_endpoint_uuid` setting (an admin override);
  otherwise defers to core's smart default — the last endpoint used in the AI
  request history, else the first enabled non-reasoning chat endpoint.
  """
  @spec default_endpoint_uuid() :: String.t() | nil
  def default_endpoint_uuid do
    case Settings.get_setting("publishing_translation_endpoint_uuid") do
      nil -> ai_default_endpoint_uuid()
      "" -> ai_default_endpoint_uuid()
      id -> id
    end
  end

  defp ai_default_endpoint_uuid do
    if ai_available?(), do: Translations.default_endpoint_uuid(), else: nil
  end

  @doc """
  Resolves the default AI prompt UUID for publishing translation.

  Prefers the `publishing_translation_prompt_uuid` setting, then falls back to
  the prompt with slug `#{@translation_prompt_slug}`. Both the editor and the
  bulk API use this so they can't drift (the bulk API previously skipped the
  slug fallback and could enqueue a `nil` prompt).
  """
  @spec default_prompt_uuid() :: String.t() | nil
  def default_prompt_uuid do
    case Settings.get_setting("publishing_translation_prompt_uuid") do
      nil -> prompt_uuid_by_slug()
      "" -> prompt_uuid_by_slug()
      id -> id
    end
  end

  @doc "Whether the publishing default translation prompt exists (by slug)."
  @spec default_prompt_exists?() :: boolean()
  def default_prompt_exists? do
    ai_available?() and PhoenixKitAI.get_prompt_by_slug(@translation_prompt_slug) != nil
  end

  @doc "The slug of the publishing default translation prompt."
  @spec translation_prompt_slug() :: String.t()
  def translation_prompt_slug, do: @translation_prompt_slug

  defp prompt_uuid_by_slug do
    if ai_available?() do
      case PhoenixKitAI.get_prompt_by_slug(@translation_prompt_slug) do
        nil -> nil
        prompt -> prompt.uuid
      end
    else
      nil
    end
  end

  # Guard the AI facade so callers degrade cleanly when the AI runtime is not
  # installed, disabled, or not fully started.
  defp ai_available? do
    Code.ensure_loaded?(PhoenixKitAI) and PhoenixKitAI.enabled?()
  end

  @doc """
  Adds a new language translation to an existing post.

  Accepts an optional version parameter to specify which version to add
  the translation to. If not specified, defaults to the latest version.
  """
  @spec add_language_to_post(
          String.t(),
          String.t(),
          String.t(),
          integer() | nil,
          keyword() | map()
        ) :: {:ok, map()} | {:error, any()}
  def add_language_to_post(group_slug, post_uuid, language_code, version \\ nil, opts \\ []) do
    result = add_language_to_db(group_slug, post_uuid, language_code, version)

    with {:ok, new_post} <- result do
      ListingCache.regenerate(group_slug)

      broadcast_id = new_post.uuid

      if broadcast_id do
        PublishingPubSub.broadcast_translation_created(
          group_slug,
          broadcast_id,
          language_code,
          content_version_scope(new_post)
        )
      end

      ActivityLog.log_manual(
        "publishing.translation.added",
        ActivityLog.actor_uuid(opts),
        "publishing_content",
        new_post.uuid,
        %{
          "group_slug" => group_slug,
          "post_uuid" => post_uuid,
          "language" => language_code,
          "version" => version
        }
      )
    end

    case result do
      {:error, reason} ->
        ActivityLog.log_failed_mutation(
          "publishing.translation.added",
          ActivityLog.actor_uuid(opts),
          "publishing_content",
          nil,
          %{
            "group_slug" => group_slug,
            "post_uuid" => post_uuid,
            "language" => language_code,
            "reason" => ActivityLog.reason_string(reason)
          }
        )

      _ ->
        :ok
    end

    result
  end

  # Adds a language to a post.
  # Creates a new content row when needed, but also treats an existing row as
  # success so legacy base-code content can be promoted in place (for example
  # "en" -> "en-US") without surfacing a false duplicate-language error.
  @doc false
  @spec add_language_to_db(String.t(), String.t(), String.t(), integer() | nil) ::
          {:ok, any()} | {:error, any()}
  def add_language_to_db(group_slug, post_uuid, language_code, version_number) do
    with raw_db_post when not is_nil(raw_db_post) <-
           DBStorage.get_group_post_by_uuid(group_slug, post_uuid, [:group]),
         db_post = StaleFixer.fix_stale_post(raw_db_post),
         version when not is_nil(version) <-
           if(version_number,
             do: DBStorage.get_version(db_post.uuid, version_number),
             else: DBStorage.get_latest_version(db_post.uuid)
           ),
         {:ok, _content} <- ensure_language_content(version.uuid, language_code) do
      # Read the post back from DB to return a proper post map
      Shared.read_back_post(group_slug, post_uuid, db_post, language_code, version.version_number)
    else
      nil ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning(
        "[Publishing] add_language_to_db failed for #{group_slug}/#{post_uuid}/#{language_code}: #{inspect(e)}"
      )

      {:error, :not_found}
  end

  defp ensure_language_content(version_uuid, language_code) do
    case DBStorage.get_content(version_uuid, language_code) do
      nil -> maybe_promote_legacy_base_content(version_uuid, language_code)
      %PublishingContent{} = existing -> {:ok, existing}
    end
  end

  defp maybe_promote_legacy_base_content(version_uuid, language_code) do
    base_language = DialectMapper.extract_base(language_code)

    cond do
      base_language == language_code ->
        create_language_content(version_uuid, language_code)

      legacy_content = DBStorage.get_content(version_uuid, base_language) ->
        Logger.info(
          "[Publishing] Promoting legacy base language #{base_language} to #{language_code} " <>
            "for version #{version_uuid}"
        )

        case DBStorage.update_content(legacy_content, %{language: language_code}) do
          {:ok, updated} = ok ->
            ActivityLog.log(%{
              action: "publishing.content.promoted",
              mode: "auto",
              resource_type: "publishing_content",
              resource_uuid: updated.uuid,
              metadata: %{
                "from_language" => base_language,
                "to_language" => language_code,
                "version_uuid" => version_uuid
              }
            })

            ok

          error ->
            error
        end

      true ->
        create_language_content(version_uuid, language_code)
    end
  end

  defp create_language_content(version_uuid, language_code) do
    DBStorage.create_content(%{
      version_uuid: version_uuid,
      language: language_code,
      title: Constants.default_title(),
      content: "",
      status: "draft"
    })
  end

  @doc """
  Hard-deletes a language's content row from a post.

  Unlike `delete_language` (which archives), this permanently removes the content.
  Refuses to delete the last remaining language.
  """
  @spec clear_translation(
          String.t(),
          String.t(),
          String.t(),
          pos_integer() | nil,
          keyword() | map()
        ) :: :ok | {:error, term()}
  def clear_translation(group_slug, post_uuid, language_code, version \\ nil, opts \\ [])
      when is_nil(version) or is_integer(version) do
    repo = PhoenixKit.RepoHelper.repo()

    with db_post when not is_nil(db_post) <-
           DBStorage.get_group_post_by_uuid(group_slug, post_uuid, [:group]),
         db_version when not is_nil(db_version) <- Shared.resolve_db_version(db_post, version),
         content when not is_nil(content) <-
           DBStorage.get_content(db_version.uuid, language_code),
         :ok <- validate_not_primary_language(language_code),
         {:ok, :ok} <- delete_content_row_locked(repo, db_post, db_version, content) do
      ListingCache.regenerate(group_slug)

      PublishingPubSub.broadcast_translation_deleted(
        group_slug,
        db_post.uuid,
        language_code,
        version_row_scope(db_version)
      )

      # Match `delete_language/5`'s audit pattern so the destructive
      # branch is auditable. Distinct `action` ("cleared" vs "deleted")
      # keeps the two entry points tellable apart in the activity feed —
      # both hard-delete the row since 2026-08 (archiving was reader-dead).
      ActivityLog.log_manual(
        "publishing.translation.cleared",
        ActivityLog.actor_uuid(opts),
        "publishing_content",
        content.uuid,
        %{
          "group_slug" => group_slug,
          "post_uuid" => db_post.uuid,
          "language" => language_code,
          "version_uuid" => db_version.uuid
        }
      )

      :ok
    else
      nil ->
        log_translation_failure(
          {:error, :not_found},
          "publishing.translation.cleared",
          opts,
          group_slug,
          post_uuid,
          language_code
        )

      {:error, _} = err ->
        log_translation_failure(
          err,
          "publishing.translation.cleared",
          opts,
          group_slug,
          post_uuid,
          language_code
        )
    end
  end

  # Post lock + fresh re-check inside one transaction: two concurrent
  # deletions of the two remaining languages both passed the lockless count
  # and left the version with ZERO content rows (public :not_found, then
  # auto-trashed as "empty"). The lock serializes them; the loser re-counts
  # and refuses. Shared by clear_translation/5 and delete_language/5.
  defp delete_content_row_locked(repo, db_post, db_version, content) do
    repo.transaction(fn ->
      DBStorage.lock_post_row!(repo, db_post.uuid)

      with :ok <- validate_not_last_content(db_version, content.language),
           {:ok, _} <- repo.delete(content) do
        :ok
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp validate_not_last_content(db_version, language_code) do
    remaining =
      DBStorage.list_contents(db_version.uuid)
      |> Enum.reject(&(&1.language == language_code))

    if remaining == [], do: {:error, :last_language}, else: :ok
  end

  # The primary-language row anchors the post: publish requires its title
  # (validate_primary_title!), its url_slug carries the post's public
  # identity + 301 history, and the public primary URL would silently serve
  # another language's body through the fallback chain. Deleting it is never
  # the right tool — edit the content instead. A legacy BASE-code row ("en"
  # while primary is "en-US") counts as the primary; an enabled sibling
  # dialect ("en-GB") does not.
  defp validate_not_primary_language(language_code) do
    primary = LanguageHelpers.get_primary_language()
    down = String.downcase(language_code)

    primary_base =
      String.downcase(LanguageHelpers.url_language_code(primary) || primary)

    if down == String.downcase(primary) or down == primary_base do
      {:error, :cannot_delete_primary_language}
    else
      :ok
    end
  end

  @doc """
  Deletes a specific language translation from a post.

  For versioned posts, specify the version. For unversioned posts, version is ignored.
  Refuses to delete the last remaining language content or the primary
  language's row.

  Hard-deletes the content row (same as `clear_translation/5`). The old
  behavior set `status: "archived"` — but NO read path anywhere filtered
  archived content rows, so a "deleted" translation kept serving publicly,
  kept its url_slug claimed, stayed in `available_languages`, and
  `create_version_from` resurrected it as a draft in every new version.
  Dead semantics; the delete now does what its name, log line, and
  broadcast have always claimed.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_language(String.t(), String.t(), String.t(), integer() | nil, keyword() | map()) ::
          :ok | {:error, term()}
  def delete_language(group_slug, post_uuid, language_code, version \\ nil, opts \\ [])
      when is_nil(version) or is_integer(version) do
    repo = PhoenixKit.RepoHelper.repo()

    with db_post when not is_nil(db_post) <-
           DBStorage.get_group_post_by_uuid(group_slug, post_uuid, [:group]),
         db_version when not is_nil(db_version) <- Shared.resolve_db_version(db_post, version),
         content when not is_nil(content) <-
           DBStorage.get_content(db_version.uuid, language_code),
         :ok <- validate_not_primary_language(language_code),
         {:ok, :ok} <- delete_content_row_locked(repo, db_post, db_version, content) do
      ListingCache.regenerate(group_slug)

      PublishingPubSub.broadcast_translation_deleted(
        group_slug,
        db_post.uuid,
        language_code,
        version_row_scope(db_version)
      )

      ActivityLog.log_manual(
        "publishing.translation.deleted",
        ActivityLog.actor_uuid(opts),
        "publishing_content",
        content.uuid,
        %{
          "group_slug" => group_slug,
          "post_uuid" => db_post.uuid,
          "language" => language_code,
          "version_uuid" => db_version.uuid
        }
      )

      :ok
    else
      nil ->
        log_translation_failure(
          {:error, :not_found},
          "publishing.translation.deleted",
          opts,
          group_slug,
          post_uuid,
          language_code
        )

      {:error, _} = err ->
        log_translation_failure(
          err,
          "publishing.translation.deleted",
          opts,
          group_slug,
          post_uuid,
          language_code
        )
    end
  end

  # Failure chokepoint for the destructive translation paths — a failed
  # user-driven clear/delete still leaves an audit row (db_pending),
  # matching the groups/posts/versions convention.
  defp log_translation_failure({:error, reason} = err, action, opts, group_slug, post_uuid, lang) do
    ActivityLog.log_failed_mutation(
      action,
      ActivityLog.actor_uuid(opts),
      "publishing_content",
      nil,
      %{
        "group_slug" => group_slug,
        "post_uuid" => post_uuid,
        "language" => lang,
        "reason" => ActivityLog.reason_string(reason)
      }
    )

    err
  end

  @doc """
  Deprecated no-op. Status is now version-level. Use `Versions.publish_version/3` instead.
  """
  @spec set_translation_status(String.t(), String.t(), integer(), String.t(), String.t()) ::
          :ok | {:error, any()}
  def set_translation_status(_group_slug, _post_identifier, _version, _language, _status) do
    Logger.warning(
      "[Publishing] set_translation_status/5 is deprecated (no-op). " <>
        "Status is now version-level. Use Versions.publish_version/3 or Publishing.unpublish_post/3 instead."
    )

    :ok
  end

  @doc """
  Enqueues an Oban job to translate a post to all enabled languages using AI.

  This creates a background job that will:
  1. Read the source post in the primary language
  2. Translate the content to each target language using the AI module
  3. Create or update translation content for each language

  ## Options

  - `:endpoint_uuid` - AI endpoint UUID to use for translation (required if not set in settings)
  - `:source_language` - Source language to translate from (defaults to primary language)
  - `:target_languages` - List of target language codes (defaults to all enabled except source)
  - `:version` - Version number to translate (defaults to latest/published)
  - `:user_uuid` - User UUID for audit trail

  ## Configuration

  Set the default AI endpoint for translations:

      PhoenixKit.Settings.update_setting("publishing_translation_endpoint_uuid", "endpoint-uuid")

  ## Examples

      # Translate to all enabled languages using default endpoint
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "019cce93-...")

      # Translate with specific endpoint
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "019cce93-...",
        endpoint_uuid: "endpoint-uuid"
      )

      # Translate to specific languages only
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "019cce93-...",
        endpoint_uuid: "endpoint-uuid",
        target_languages: ["es", "fr", "de"]
      )

  ## Returns

  Delegates to PhoenixKitAI's generic pipeline, enqueuing one job per target language
  (they run in parallel):

  - `{:ok, %{enqueued: n, conflicts: n, errors: [], in_flight: [lang]}}`
  - `{:error, reason}` - malformed params (e.g. missing endpoint/prompt)

  """
  @spec translate_post_to_all_languages(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def translate_post_to_all_languages(_group_slug, post_uuid, opts \\ []) do
    {base_params, targets} = build_bulk_translation_params(post_uuid, opts)
    Translations.enqueue_all_missing(base_params, targets)
  end

  @doc false
  # Public for testing. Assembles PhoenixKitAI translation `base_params` and the
  # target-language list for `translate_post_to_all_languages/3`, resolving
  # defaults: source = primary language; targets = all enabled except source;
  # endpoint/prompt fall back to the publishing settings; actor is included only
  # when a `:user_uuid` is given.
  @spec build_bulk_translation_params(String.t(), keyword()) :: {map(), [String.t()]}
  def build_bulk_translation_params(post_uuid, opts) do
    source_lang = opts[:source_language] || LanguageHelpers.get_primary_language()

    targets =
      opts[:target_languages] ||
        Enum.reject(LanguageHelpers.enabled_language_codes(), &(&1 == source_lang))

    base_params =
      %{
        resource_type: AITranslatable.resource_type(),
        resource_uuid: post_uuid,
        endpoint_uuid: opts[:endpoint_uuid] || default_endpoint_uuid(),
        prompt_uuid: opts[:prompt_uuid] || default_prompt_uuid(),
        source_lang: source_lang,
        # Scope to the active version's number (not nil) so an editor open on
        # that version still matches the lifecycle events — the editor always
        # filters by a concrete version string. `opts[:resource_scope]` lets a
        # caller target a specific version; otherwise the active version, or nil
        # when it can't be resolved (fetch/3 falls back to active either way).
        resource_scope: opts[:resource_scope] || active_version_scope(post_uuid)
      }
      |> maybe_put_actor(opts[:user_uuid])

    {base_params, targets}
  end

  defp maybe_put_actor(params, nil), do: params
  defp maybe_put_actor(params, actor_uuid), do: Map.put(params, :actor_uuid, actor_uuid)

  # The version a read-back post map sits on, as the string the editor matches
  # translation events against (mirrors the editor's current_version scope).
  defp content_version_scope(post) do
    case Map.get(post, :version) do
      nil -> nil
      version -> to_string(version)
    end
  end

  # Same scope convention, from a DB version row. The editor compares the
  # broadcast version against `to_string(socket.assigns.current_version)`, so a
  # raw integer never matches and the event is silently dropped.
  defp version_row_scope(%{version_number: number}) when not is_nil(number),
    do: to_string(number)

  defp version_row_scope(_version), do: nil

  # The post's active version number as a string, matching the editor's scope
  # convention. nil (→ active via fetch/3) when there's no active version or the
  # lookup fails.
  defp active_version_scope(post_uuid) do
    case DBStorage.get_post_by_uuid(post_uuid, [:active_version]) do
      %{active_version: %{version_number: n}} when is_integer(n) -> Integer.to_string(n)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
