defmodule PhoenixKit.Modules.Publishing.TranslationManager do
  @moduledoc """
  Language and translation management for the Publishing module.

  Handles adding/removing languages and AI-powered translation.
  """

  require Logger

  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker

  @doc """
  Adds a new language translation to an existing post.

  Accepts an optional version parameter to specify which version to add
  the translation to. If not specified, defaults to the latest version.
  """
  @spec add_language_to_post(String.t(), String.t(), String.t(), integer() | nil) ::
          {:ok, map()} | {:error, any()}
  def add_language_to_post(group_slug, post_uuid, language_code, version \\ nil) do
    result = add_language_to_db(group_slug, post_uuid, language_code, version)

    with {:ok, new_post} <- result do
      ListingCache.regenerate(group_slug)

      broadcast_id = new_post.uuid

      if broadcast_id do
        PublishingPubSub.broadcast_translation_created(group_slug, broadcast_id, language_code)
      end
    end

    result
  end

  # Adds a language to a post.
  # Creates a new content row in the database and returns the post map.
  @doc false
  def add_language_to_db(group_slug, post_uuid, language_code, version_number) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
         version when not is_nil(version) <-
           if(version_number,
             do: DBStorage.get_version(db_post.uuid, version_number),
             else: DBStorage.get_latest_version(db_post.uuid)
           ),
         # Check if content already exists for this language
         nil <- DBStorage.get_content(version.uuid, language_code),
         {:ok, _content} <-
           DBStorage.create_content(%{
             version_uuid: version.uuid,
             language: language_code,
             title: Constants.default_title(),
             content: "",
             status: "draft"
           }) do
      # Read the post back from DB to return a proper post map
      Shared.read_back_post(group_slug, post_uuid, db_post, language_code, version.version_number)
    else
      nil ->
        {:error, :not_found}

      %PhoenixKit.Modules.Publishing.PublishingContent{} = _existing ->
        # Content already exists for this language - read back the post
        db_post = DBStorage.get_post_by_uuid(post_uuid, [:group])

        resolved_version =
          if version_number do
            version_number
          else
            case db_post && DBStorage.get_latest_version(db_post.uuid) do
              nil -> nil
              v -> v.version_number
            end
          end

        Shared.read_back_post(group_slug, post_uuid, db_post, language_code, resolved_version)

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

  @doc """
  Hard-deletes a language's content row from a post.

  Unlike `delete_language` (which archives), this permanently removes the content.
  Refuses to delete the last remaining language.
  """
  @spec clear_translation(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def clear_translation(group_slug, post_uuid, language_code) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
         db_version when not is_nil(db_version) <- Shared.resolve_db_version(db_post, nil),
         content when not is_nil(content) <-
           DBStorage.get_content(db_version.uuid, language_code),
         :ok <- validate_not_last_content(db_version, language_code) do
      repo = PhoenixKit.RepoHelper.repo()

      case repo.delete(content) do
        {:ok, _} ->
          broadcast_id = db_post.uuid
          ListingCache.regenerate(group_slug)
          PublishingPubSub.broadcast_translation_deleted(group_slug, broadcast_id, language_code)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp validate_not_last_content(db_version, language_code) do
    remaining =
      DBStorage.list_contents(db_version.uuid)
      |> Enum.reject(&(&1.language == language_code))

    if remaining == [], do: {:error, :last_language}, else: :ok
  end

  @doc """
  Deletes a specific language translation from a post.

  For versioned posts, specify the version. For unversioned posts, version is ignored.
  Refuses to delete the last remaining language content.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_language(String.t(), String.t(), String.t(), integer() | nil) ::
          :ok | {:error, term()}
  def delete_language(group_slug, post_uuid, language_code, version \\ nil) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
         db_version when not is_nil(db_version) <- Shared.resolve_db_version(db_post, version),
         content when not is_nil(content) <-
           DBStorage.get_content(db_version.uuid, language_code),
         :ok <- validate_not_last_language(db_version) do
      case DBStorage.update_content(content, %{status: "archived"}) do
        {:ok, _} ->
          broadcast_id = db_post.uuid
          ListingCache.regenerate(group_slug)
          PublishingPubSub.broadcast_translation_deleted(group_slug, broadcast_id, language_code)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp validate_not_last_language(db_version) do
    active =
      DBStorage.list_contents(db_version.uuid)
      |> Enum.reject(&(&1.status == "archived"))

    if length(active) <= 1, do: {:error, :last_language}, else: :ok
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

  - `{:ok, %Oban.Job{}}` - Job was successfully enqueued
  - `{:error, changeset}` - Failed to enqueue job

  """
  @spec translate_post_to_all_languages(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def translate_post_to_all_languages(group_slug, post_uuid, opts \\ []) do
    TranslatePostWorker.enqueue(group_slug, post_uuid, opts)
  end
end
