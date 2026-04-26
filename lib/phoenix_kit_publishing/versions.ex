defmodule PhoenixKit.Modules.Publishing.Versions do
  @moduledoc """
  Version management functions for the Publishing module.

  Handles listing, creating, publishing, and deleting versions
  of publishing posts.
  """

  require Logger

  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @doc "Lists version numbers for a post."
  def list_versions(group_slug, post_slug) do
    case DBStorage.get_post(group_slug, post_slug) do
      nil ->
        []

      db_post ->
        db_post.uuid
        |> DBStorage.list_versions()
        |> Enum.map(& &1.version_number)
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] list_versions failed for #{group_slug}/#{post_slug}: #{inspect(e)}"
      )

      []
  end

  @doc "Gets the published version number for a post."
  def get_published_version(group_slug, post_slug) do
    case DBStorage.get_post(group_slug, post_slug) do
      nil ->
        {:error, :not_found}

      db_post ->
        db_post.uuid
        |> DBStorage.list_versions()
        |> Enum.find(&(&1.status == "published"))
        |> case do
          nil -> {:error, :no_published_version}
          v -> {:ok, v.version_number}
        end
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] get_published_version failed for #{group_slug}/#{post_slug}: #{inspect(e)}"
      )

      {:error, :not_found}
  end

  @doc "Gets the status of a specific version/language."
  def get_version_status(group_slug, post_slug, version_number, _language) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post(group_slug, post_slug),
         db_version when not is_nil(db_version) <-
           DBStorage.get_version(db_post.uuid, version_number) do
      db_version.status
    else
      _ -> "draft"
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] get_version_status failed for #{group_slug}/#{post_slug}/v#{version_number}: #{inspect(e)}"
      )

      "draft"
  end

  # Version metadata lookup (DB-based)
  def get_version_metadata(group_slug, post_slug, version_number, language) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post(group_slug, post_slug),
         db_version when not is_nil(db_version) <-
           DBStorage.get_version(db_post.uuid, version_number),
         content when not is_nil(content) <- DBStorage.get_content(db_version.uuid, language) do
      %{
        status: db_version.status,
        title: content.title,
        url_slug: content.url_slug,
        version: version_number
      }
    else
      _ -> nil
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] get_version_metadata failed for #{group_slug}/#{post_slug}/v#{version_number}: #{inspect(e)}"
      )

      nil
  end

  @doc """
  Creates a new version of a slug-mode post by copying from the latest version.

  The new version starts as draft with status: "draft".
  Content and metadata updates from params are applied to the new version.

  Note: For more control over which version to branch from, use `create_version_from/5`.
  """
  @spec create_new_version(String.t(), map(), map(), map() | keyword()) ::
          {:ok, map()} | {:error, any()}
  def create_new_version(group_slug, source_post, params \\ %{}, opts \\ %{}) do
    source_version = source_post[:version] || 1
    create_version_in_db(group_slug, source_post[:uuid], source_version, params, opts)
  end

  @doc """
  Publishes a version, making it the live version for the post.

  - Sets the target version status to "published" and `published_at` (if not already set)
  - Archives the previously published version (status -> "archived")
  - Sets `post.active_version_uuid` to the target version's UUID

  ## Options

  - `:source_id` - ID of the source (e.g., socket.id) to include in broadcasts,
    allowing receivers to ignore their own messages

  ## Examples

      iex> Publishing.Versions.publish_version("blog", "my-post", 2)
      :ok

      iex> Publishing.Versions.publish_version("blog", "my-post", 2, source_id: "phx-abc123")
      :ok

      iex> Publishing.Versions.publish_version("blog", "nonexistent", 1)
      {:error, :not_found}
  """
  @spec publish_version(String.t(), String.t(), integer(), keyword()) :: :ok | {:error, any()}
  def publish_version(group_slug, post_uuid, version, opts \\ []) do
    case DBStorage.get_post_by_uuid(post_uuid, [:group]) do
      nil ->
        ActivityLog.log_failed_mutation(
          "publishing.version.published",
          ActivityLog.actor_uuid(opts),
          "publishing_version",
          post_uuid,
          %{
            "group_slug" => group_slug,
            "version_number" => version,
            "reason" => "not_found"
          }
        )

        {:error, :not_found}

      db_post ->
        if db_post.trashed_at do
          ActivityLog.log_failed_mutation(
            "publishing.version.published",
            ActivityLog.actor_uuid(opts),
            "publishing_version",
            db_post.uuid,
            %{
              "group_slug" => group_slug,
              "version_number" => version,
              "reason" => "post_trashed"
            }
          )

          {:error, :post_trashed}
        else
          do_publish_version(group_slug, db_post, version, opts)
        end
    end
  end

  @doc """
  Unpublishes a post by clearing its active version.

  - Clears `post.active_version_uuid`
  - Sets the previously-active version status to "draft"

  ## Options

  - `:source_id` - ID of the source to include in broadcasts

  ## Examples

      iex> Publishing.Versions.unpublish_post("blog", post_uuid)
      :ok

      iex> Publishing.Versions.unpublish_post("blog", "nonexistent")
      {:error, :not_found}
  """
  @spec unpublish_post(String.t(), String.t(), keyword()) :: :ok | {:error, any()}
  def unpublish_post(group_slug, post_uuid, opts \\ []) do
    case DBStorage.get_post_by_uuid(post_uuid, [:group]) do
      nil ->
        ActivityLog.log_failed_mutation(
          "publishing.post.unpublished",
          ActivityLog.actor_uuid(opts),
          "publishing_post",
          post_uuid,
          %{"group_slug" => group_slug, "reason" => "not_found"}
        )

        {:error, :not_found}

      %{active_version_uuid: nil} = db_post ->
        ActivityLog.log_failed_mutation(
          "publishing.post.unpublished",
          ActivityLog.actor_uuid(opts),
          "publishing_post",
          db_post.uuid,
          %{"group_slug" => group_slug, "reason" => "not_published"}
        )

        {:error, :not_published}

      db_post ->
        do_unpublish_post(group_slug, db_post, opts)
    end
  end

  defp do_publish_version(group_slug, db_post, version, opts) do
    repo = PhoenixKit.RepoHelper.repo()

    tx_result =
      repo.transaction(fn ->
        versions = DBStorage.list_versions(db_post.uuid)
        target_version = Enum.find(versions, &(&1.version_number == version))

        unless target_version do
          repo.rollback(:version_not_found)
        end

        validate_primary_title!(repo, target_version)
        archive_other_published_versions!(repo, versions, version)
        publish_and_activate!(repo, db_post, target_version)
      end)

    case tx_result do
      {:ok, _} ->
        broadcast_publish(group_slug, db_post.uuid, version, opts)

        ActivityLog.log_manual(
          "publishing.version.published",
          ActivityLog.actor_uuid(opts),
          "publishing_version",
          db_post.uuid,
          %{
            "group_slug" => group_slug,
            "post_uuid" => db_post.uuid,
            "version_number" => version
          }
        )

        :ok

      {:error, reason} ->
        ActivityLog.log_failed_mutation(
          "publishing.version.published",
          ActivityLog.actor_uuid(opts),
          "publishing_version",
          db_post.uuid,
          %{
            "group_slug" => group_slug,
            "post_uuid" => db_post.uuid,
            "version_number" => version
          }
        )

        {:error, reason}
    end
  end

  defp archive_other_published_versions!(repo, versions, target_version_number) do
    for v <- versions,
        v.version_number != target_version_number,
        v.status == "published" do
      case DBStorage.update_version(v, %{status: "archived"}) do
        {:ok, _} -> :ok
        {:error, reason} -> repo.rollback(reason)
      end
    end
  end

  defp publish_and_activate!(repo, db_post, target_version) do
    publish_attrs =
      if target_version.published_at,
        do: %{status: "published"},
        else: %{status: "published", published_at: UtilsDate.utc_now()}

    case DBStorage.update_version(target_version, publish_attrs) do
      {:ok, published_version} ->
        case DBStorage.update_post(db_post, %{active_version_uuid: published_version.uuid}) do
          {:ok, _} -> :ok
          {:error, reason} -> repo.rollback(reason)
        end

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp broadcast_publish(group_slug, post_uuid, version, opts) do
    source_id = Keyword.get(opts, :source_id)
    ListingCache.regenerate(group_slug)
    PublishingPubSub.broadcast_version_live_changed(group_slug, post_uuid, version)
    PublishingPubSub.broadcast_post_version_published(group_slug, post_uuid, version, source_id)
  end

  defp do_unpublish_post(group_slug, db_post, opts) do
    repo = PhoenixKit.RepoHelper.repo()

    tx_result =
      repo.transaction(fn ->
        # Find the currently active version
        active_version = DBStorage.get_active_version(db_post)

        # Clear active_version_uuid on the post
        case DBStorage.update_post(db_post, %{active_version_uuid: nil}) do
          {:ok, _} -> :ok
          {:error, reason} -> repo.rollback(reason)
        end

        revert_active_version_to_draft(repo, active_version)
      end)

    case tx_result do
      {:ok, _} ->
        source_id = Keyword.get(opts, :source_id)
        broadcast_id = db_post.uuid
        ListingCache.regenerate(group_slug)
        PublishingPubSub.broadcast_version_live_changed(group_slug, broadcast_id, nil)

        PublishingPubSub.broadcast_post_version_published(
          group_slug,
          broadcast_id,
          nil,
          source_id
        )

        ActivityLog.log_manual(
          "publishing.post.unpublished",
          ActivityLog.actor_uuid(opts),
          "publishing_post",
          db_post.uuid,
          %{"group_slug" => group_slug}
        )

        :ok

      {:error, reason} ->
        ActivityLog.log_failed_mutation(
          "publishing.post.unpublished",
          ActivityLog.actor_uuid(opts),
          "publishing_post",
          db_post.uuid,
          %{"group_slug" => group_slug}
        )

        {:error, reason}
    end
  end

  @doc """
  Creates a new version from an existing version or blank.

  ## Parameters

    * `group_slug` - The publishing group slug
    * `post_slug` - The post slug
    * `source_version` - Version to copy from, or `nil` for blank version
    * `params` - Optional parameters for the new version
    * `opts` - Options including `:scope` for audit metadata

  ## Examples

      # Create blank version
      iex> Publishing.Versions.create_version_from("blog", "my-post", nil, %{}, scope: scope)
      {:ok, %{version: 3, ...}}

      # Branch from version 1
      iex> Publishing.Versions.create_version_from("blog", "my-post", 1, %{}, scope: scope)
      {:ok, %{version: 3, ...}}
  """
  @spec create_version_from(String.t(), String.t(), integer() | nil, map(), map() | keyword()) ::
          {:ok, map()} | {:error, any()}
  def create_version_from(group_slug, post_uuid, source_version, params \\ %{}, opts \\ %{}) do
    create_version_in_db(group_slug, post_uuid, source_version, params, opts)
  end

  @doc """
  Deletes an entire version of a post.

  Archives the version instead of permanent deletion.
  Refuses to delete the last remaining version or the live version.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_version(String.t(), String.t(), integer(), keyword() | map()) ::
          :ok | {:error, term()}
  def delete_version(group_slug, post_uuid, version, opts \\ []) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
         db_version when not is_nil(db_version) <- DBStorage.get_version(db_post.uuid, version),
         :ok <- validate_version_deletable(db_post, db_version) do
      broadcast_id = db_post.uuid

      case DBStorage.update_version(db_version, %{status: "archived"}) do
        {:ok, _} ->
          ListingCache.regenerate(group_slug)
          PublishingPubSub.broadcast_version_deleted(group_slug, broadcast_id, version)
          PublishingPubSub.broadcast_post_version_deleted(group_slug, broadcast_id, version)

          ActivityLog.log_manual(
            "publishing.version.deleted",
            ActivityLog.actor_uuid(opts),
            "publishing_version",
            db_version.uuid,
            %{
              "group_slug" => group_slug,
              "post_uuid" => db_post.uuid,
              "version_number" => version
            }
          )

          :ok

        {:error, reason} ->
          ActivityLog.log_failed_mutation(
            "publishing.version.deleted",
            ActivityLog.actor_uuid(opts),
            "publishing_version",
            db_version.uuid,
            %{
              "group_slug" => group_slug,
              "post_uuid" => db_post.uuid,
              "version_number" => version
            }
          )

          {:error, reason}
      end
    else
      nil ->
        ActivityLog.log_failed_mutation(
          "publishing.version.deleted",
          ActivityLog.actor_uuid(opts),
          "publishing_version",
          post_uuid,
          %{
            "group_slug" => group_slug,
            "version_number" => version,
            "reason" => "not_found"
          }
        )

        {:error, :not_found}

      {:error, reason} = err ->
        ActivityLog.log_failed_mutation(
          "publishing.version.deleted",
          ActivityLog.actor_uuid(opts),
          "publishing_version",
          post_uuid,
          %{
            "group_slug" => group_slug,
            "version_number" => version,
            "reason" => to_string(reason)
          }
        )

        err
    end
  end

  defp validate_version_deletable(db_post, db_version) do
    cond do
      db_post.active_version_uuid == db_version.uuid ->
        {:error, :cannot_delete_live}

      length(Enum.reject(DBStorage.list_versions(db_post.uuid), &(&1.status == "archived"))) <= 1 ->
        {:error, :last_version}

      true ->
        :ok
    end
  end

  @doc false
  @spec broadcast_version_created(String.t(), String.t(), map()) :: :ok
  def broadcast_version_created(group_slug, broadcast_id, new_version) do
    PublishingPubSub.broadcast_version_created(group_slug, new_version)

    version_info = %{
      version: new_version[:current_version] || new_version[:version],
      available_versions: new_version[:available_versions] || []
    }

    PublishingPubSub.broadcast_post_version_created(group_slug, broadcast_id, version_info)
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp create_version_in_db(group_slug, post_uuid, source_version, _params, opts) do
    case DBStorage.get_post_by_uuid(post_uuid, [:group]) do
      nil -> {:error, :post_not_found}
      db_post -> do_create_version(group_slug, post_uuid, db_post, source_version, opts)
    end
  end

  defp do_create_version(group_slug, post_uuid, db_post, source_version, opts) do
    scope = Shared.fetch_option(opts, :scope)
    created_by_uuid = Shared.resolve_scope_user_uuids(scope)

    user_opts = %{created_by_uuid: created_by_uuid}

    result =
      if source_version do
        DBStorage.create_version_from(db_post.uuid, source_version, user_opts)
      else
        # Blank version — create empty version with site default language content
        primary_language = LanguageHelpers.get_primary_language()

        with {:ok, db_version} <-
               DBStorage.create_version(%{
                 post_uuid: db_post.uuid,
                 version_number: DBStorage.next_version_number(db_post.uuid),
                 status: "draft",
                 created_by_uuid: created_by_uuid
               }),
             {:ok, _content} <-
               DBStorage.create_content(%{
                 version_uuid: db_version.uuid,
                 language: primary_language,
                 title: "",
                 content: "",
                 status: "draft"
               }) do
          {:ok, db_version}
        end
      end

    with {:ok, db_version} <- result,
         {:ok, post} <-
           Shared.read_back_post(group_slug, post_uuid, db_post, nil, db_version.version_number) do
      ListingCache.regenerate(group_slug)
      broadcast_version_created(group_slug, db_post.uuid, post)

      ActivityLog.log_manual(
        "publishing.version.created",
        ActivityLog.actor_uuid(opts) || created_by_uuid,
        "publishing_version",
        db_version.uuid,
        %{
          "group_slug" => group_slug,
          "post_uuid" => db_post.uuid,
          "version_number" => db_version.version_number,
          "source_version" => source_version
        }
      )

      {:ok, post}
    end
  end

  defp revert_active_version_to_draft(_repo, nil), do: :ok

  defp revert_active_version_to_draft(repo, active_version) do
    case DBStorage.update_version(active_version, %{status: "draft"}) do
      {:ok, _} -> :ok
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp validate_primary_title!(repo, target_version) do
    primary_language = LanguageHelpers.get_primary_language()
    content = DBStorage.get_content(target_version.uuid, primary_language)

    if is_nil(content) or content.title in ["", nil, Constants.default_title()] do
      repo.rollback(:title_required)
    end
  end
end
