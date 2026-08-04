defmodule PhoenixKit.Modules.Publishing.Versions do
  @moduledoc """
  Version management functions for the Publishing module.

  Handles listing, creating, publishing, and deleting versions
  of publishing posts.
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @doc "Lists version numbers for a post."
  @spec list_versions(String.t(), String.t()) :: [integer()]
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
  @spec get_published_version(String.t(), String.t()) ::
          {:ok, integer()} | {:error, :not_found | :no_published_version}
  def get_published_version(group_slug, post_slug) do
    case DBStorage.get_post(group_slug, post_slug) do
      nil ->
        {:error, :not_found}

      db_post ->
        db_post.uuid
        |> DBStorage.list_versions()
        |> Enum.find(&Constants.published?(&1.status))
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
  @spec get_version_status(String.t(), String.t(), integer(), String.t()) :: String.t()
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

  @doc """
  Returns a `%{status, title, url_slug, version}` map for the given
  group/post/version/language tuple, or `nil` when any link in the
  chain (post → version → per-language content) is missing.

  Used by the editor and listing views to surface the version's
  title and URL slug for a specific language without having to load
  the full version + content rows.

  Returns `nil` (not an `{:error, _}` tuple) on DB exceptions — the
  caller treats absent metadata the same as a missing version, and
  the exception is logged for diagnostics.
  """
  @spec get_version_metadata(String.t(), String.t(), integer(), String.t()) :: map() | nil
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

  The new version starts as draft with status: "draft", carrying a copy of
  the source version's content.

  `params` must be empty — this branches a version, it does not edit one.
  Passing anything returns `{:error, :params_not_applied}`; save the changes
  with `Posts.update_post/4` against the version this returns.

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
    case DBStorage.get_group_post_by_uuid(group_slug, post_uuid, [:group]) do
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
  - Sets the previously-active version status to `:target_status` opt
    (default `"draft"`; pass `"archived"` to archive instead). The UI's
    "archived" status flows through here so the version's row should
    actually carry `"archived"`, otherwise the UI label and the DB state
    diverge (the admin listing shows "Archived" but the underlying
    version is `"draft"`).

  ## Options

  - `:source_id` - ID of the source to include in broadcasts
  - `:target_status` - final status for the previously-active version
    (`"draft"` or `"archived"`; default `"draft"`)

  ## Examples

      iex> Publishing.Versions.unpublish_post("blog", post_uuid)
      :ok

      iex> Publishing.Versions.unpublish_post("blog", post_uuid, target_status: "archived")
      :ok

      iex> Publishing.Versions.unpublish_post("blog", "nonexistent")
      {:error, :not_found}
  """
  @spec unpublish_post(String.t(), String.t(), keyword()) :: :ok | {:error, any()}
  def unpublish_post(group_slug, post_uuid, opts \\ []) do
    case DBStorage.get_group_post_by_uuid(group_slug, post_uuid, [:group]) do
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
        lock_post!(repo, db_post.uuid)

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

  # Takes a `SELECT … FOR UPDATE` row lock on the post for the rest of the
  # enclosing transaction. Publish and unpublish both mutate
  # `active_version_uuid` and version statuses; serializing them on this
  # single lock prevents a concurrent publish/unpublish — or two publishes —
  # from interleaving into a stale `active_version_uuid` or multiple
  # `status == "published"` rows. Operations on DIFFERENT posts stay
  # parallel. Both `do_publish_version/4` and `do_unpublish_post/3` MUST
  # acquire this same lock — the per-post serialization depends on it.
  defp lock_post!(repo, post_uuid) do
    from(p in PublishingPost, where: p.uuid == ^post_uuid, lock: "FOR UPDATE")
    |> repo.one()
  end

  defp archive_other_published_versions!(repo, versions, target_version_number) do
    for v <- versions,
        v.version_number != target_version_number,
        Constants.published?(v.status) do
      case DBStorage.update_version(v, %{status: "archived"}) do
        {:ok, _} -> :ok
        {:error, reason} -> repo.rollback(reason)
      end
    end
  end

  defp publish_and_activate!(repo, db_post, target_version) do
    publish_attrs =
      if target_version.published_at,
        do: %{status: Constants.status_published()},
        else: %{status: Constants.status_published(), published_at: UtilsDate.utc_now()}

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

  # Create an empty version + its site-default-language content row in ONE
  # transaction, so a content-insert failure rolls the version back instead of
  # orphaning an empty version (L4).
  defp create_blank_version(db_post, created_by_uuid) do
    primary_language = LanguageHelpers.get_primary_language()
    repo = PhoenixKit.RepoHelper.repo()

    repo.transaction(fn ->
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
        db_version
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp do_unpublish_post(group_slug, db_post, opts) do
    repo = PhoenixKit.RepoHelper.repo()
    target_status = Keyword.get(opts, :target_status, "draft")

    tx_result =
      repo.transaction(fn ->
        lock_post!(repo, db_post.uuid)

        # Re-read under the lock so active_version_uuid reflects any publish that
        # committed between the initial read and acquiring the row lock — otherwise
        # we'd demote the wrong (stale) version (L3).
        db_post = DBStorage.get_post_by_uuid(db_post.uuid) || db_post
        active_version = DBStorage.get_active_version(db_post)

        # Clear active_version_uuid on the post
        case DBStorage.update_post(db_post, %{active_version_uuid: nil}) do
          {:ok, _} -> :ok
          {:error, reason} -> repo.rollback(reason)
        end

        set_active_version_status(repo, active_version, target_status)
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
    with db_post when not is_nil(db_post) <-
           DBStorage.get_group_post_by_uuid(group_slug, post_uuid, [:group]),
         db_version when not is_nil(db_version) <- DBStorage.get_version(db_post.uuid, version),
         :ok <- validate_version_deletable(db_post, db_version) do
      broadcast_id = db_post.uuid

      case archive_deleted_version(db_post, db_version) do
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

  # "Not the live one" is checked before the write, and between those two
  # moments someone else can publish the very version being deleted —
  # `publish_version/4` and `unpublish_post/3` both take the post row's lock
  # for exactly this reason, and this path did not. The loser archived a
  # version the winner had just made live, leaving `active_version_uuid`
  # pointing at an archived row: the public page kept serving it (the join is
  # on the pointer, not the status) while the admin list called it a draft,
  # and `stale_fixer` doesn't repair that shape because the pointer isn't nil.
  #
  # Same lock, same re-read under it, and the deletion loses the race instead
  # of silently winning it.
  defp archive_deleted_version(db_post, db_version) do
    repo = PhoenixKit.RepoHelper.repo()

    repo.transaction(fn ->
      lock_post!(repo, db_post.uuid)

      fresh_post = DBStorage.get_post_by_uuid(db_post.uuid)
      fresh_version = DBStorage.get_version(db_post.uuid, db_version.version_number)

      archive_under_lock!(repo, fresh_post, fresh_version)
    end)
  end

  defp archive_under_lock!(repo, fresh_post, fresh_version) do
    cond do
      is_nil(fresh_version) ->
        repo.rollback(:not_found)

      fresh_post && fresh_post.active_version_uuid == fresh_version.uuid ->
        repo.rollback(:cannot_delete_live)

      # Fresh last-version re-check UNDER the lock — the pre-lock count in
      # validate_version_deletable is a courtesy fast-fail; two concurrent
      # deletes of the two remaining non-archived versions both passed it
      # and left the post with zero live-able versions.
      last_nonarchived_version?(fresh_post, fresh_version) ->
        repo.rollback(:last_version)

      true ->
        case DBStorage.update_version(fresh_version, %{status: "archived"}) do
          {:ok, updated} -> updated
          {:error, reason} -> repo.rollback(reason)
        end
    end
  end

  defp last_nonarchived_version?(fresh_post, fresh_version) do
    post_uuid = (fresh_post && fresh_post.uuid) || fresh_version.post_uuid

    post_uuid
    |> DBStorage.list_versions()
    |> Enum.reject(&(&1.status == "archived"))
    |> length()
    |> Kernel.<=(1)
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

  # Failure chokepoint — success is logged inside do_create_version, so this
  # wrapper only records the error branches (the "New version" click has to
  # leave an audit row either way, matching publish/unpublish/delete).
  defp create_version_in_db(group_slug, post_uuid, source_version, params, opts) do
    case run_create_version(group_slug, post_uuid, source_version, params, opts) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        ActivityLog.log_failed_mutation(
          "publishing.version.created",
          ActivityLog.actor_uuid(opts),
          "publishing_post",
          post_uuid,
          %{
            "group_slug" => group_slug,
            "source_version" => source_version,
            "reason" => ActivityLog.reason_string(reason)
          }
        )

        err
    end
  end

  # Both public entry points have always taken a `params` map, documented as
  # "content and metadata updates are applied to the new version", and neither
  # ever applied it — the argument reached here and was dropped. Every caller
  # in this repo passes an empty map, so nothing lost work; an integration that
  # trusted the docs would have watched a version get cloned over the edit it
  # thought it was saving, and been handed a success tuple saying otherwise.
  # Say no out loud instead: branch, then save through the normal update path.
  defp run_create_version(_group_slug, _post_uuid, _source_version, params, _opts)
       when params not in [nil, %{}],
       do: {:error, :params_not_applied}

  defp run_create_version(group_slug, post_uuid, source_version, _params, opts) do
    case DBStorage.get_group_post_by_uuid(group_slug, post_uuid, [:group]) do
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
        create_blank_version(db_post, created_by_uuid)
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

  defp set_active_version_status(_repo, nil, _target_status), do: :ok

  defp set_active_version_status(repo, active_version, target_status) do
    case DBStorage.update_version(active_version, %{status: target_status}) do
      {:ok, _} -> :ok
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp validate_primary_title!(repo, target_version) do
    primary_language = LanguageHelpers.get_primary_language()

    # A never-edited V1 post carries its primary content under the legacy
    # BASE code ("en" while primary is "en-US"); editor flows heal that on
    # read, but a programmatic publish reached here directly and failed
    # with a misleading :title_required despite a titled row.
    content =
      DBStorage.get_content(target_version.uuid, primary_language) ||
        DBStorage.get_content(
          target_version.uuid,
          LanguageHelpers.url_language_code(primary_language) || primary_language
        )

    if is_nil(content) or content.title in ["", nil, Constants.default_title()] do
      repo.rollback(:title_required)
    end
  end
end
