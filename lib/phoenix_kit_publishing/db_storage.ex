defmodule PhoenixKit.Modules.Publishing.DBStorage do
  @moduledoc """
  Database storage layer for the Publishing module.

  Provides CRUD operations for publishing groups, posts, versions, and contents
  via PostgreSQL with Ecto.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.DBStorage.Mapper
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion

  require Logger

  @typep changeset_or_struct(struct) ::
           {:ok, struct} | {:error, Ecto.Changeset.t()}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ===========================================================================
  # Groups
  # ===========================================================================

  @doc "Creates a publishing group."
  @spec create_group(map()) :: changeset_or_struct(PublishingGroup.t())
  def create_group(attrs) do
    %PublishingGroup{}
    |> PublishingGroup.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a publishing group."
  @spec update_group(PublishingGroup.t(), map()) :: changeset_or_struct(PublishingGroup.t())
  def update_group(%PublishingGroup{} = group, attrs) do
    group
    |> PublishingGroup.changeset(attrs)
    |> repo().update()
  end

  @doc "Gets a group by slug."
  @spec get_group_by_slug(String.t()) :: PublishingGroup.t() | nil
  def get_group_by_slug(slug) do
    repo().get_by(PublishingGroup, slug: slug)
  end

  @doc "Gets a group by UUID."
  @spec get_group(String.t()) :: PublishingGroup.t() | nil
  def get_group(uuid) do
    repo().get(PublishingGroup, uuid)
  end

  @doc "Lists groups ordered by position. Filters by status (default: active only)."
  @spec list_groups(String.t() | nil) :: [PublishingGroup.t()]
  def list_groups(status \\ "active") do
    query = from(g in PublishingGroup, order_by: [asc: g.position, asc: g.name])

    if status do
      where(query, [g], g.status == ^status)
    else
      query
    end
    |> repo().all()
  end

  @doc "Trashes a group by setting status to 'trashed'."
  @spec trash_group(PublishingGroup.t()) :: changeset_or_struct(PublishingGroup.t())
  def trash_group(%PublishingGroup{} = group) do
    update_group(group, %{status: "trashed"})
  end

  @doc "Restores a trashed group by setting status to 'active'."
  @spec restore_group(PublishingGroup.t()) :: changeset_or_struct(PublishingGroup.t())
  def restore_group(%PublishingGroup{} = group) do
    update_group(group, %{status: "active"})
  end

  @doc """
  Upserts a group by slug atomically via PostgreSQL `ON CONFLICT`.

  The previous check-then-act version (`get_group_by_slug` then create
  or update) had a TOCTOU race: two concurrent callers with the same
  slug could both observe `nil` and both attempt to insert, with one
  crashing on the unique index. This version delegates conflict
  resolution to PostgreSQL and replaces the mutable columns on hit.
  """
  @spec upsert_group(map()) :: changeset_or_struct(PublishingGroup.t())
  def upsert_group(attrs) do
    %PublishingGroup{}
    |> PublishingGroup.changeset(attrs)
    |> repo().insert(
      on_conflict:
        {:replace,
         [:name, :mode, :status, :position, :data, :title_i18n, :description_i18n, :updated_at]},
      conflict_target: :slug,
      returning: true
    )
  end

  @doc "Deletes a group and all its posts (cascade)."
  @spec delete_group(PublishingGroup.t()) :: changeset_or_struct(PublishingGroup.t())
  def delete_group(%PublishingGroup{} = group) do
    repo().delete(group)
  end

  # ===========================================================================
  # Posts
  # ===========================================================================

  @doc "Creates a post within a group."
  @spec create_post(map()) :: changeset_or_struct(PublishingPost.t())
  def create_post(attrs) do
    %PublishingPost{}
    |> PublishingPost.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a post."
  @spec update_post(PublishingPost.t(), map()) :: changeset_or_struct(PublishingPost.t())
  def update_post(%PublishingPost{} = post, attrs) do
    post
    |> PublishingPost.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Gets a post by group slug and post slug. Excludes trashed posts.

  Preloads `:active_version` so that downstream `get_active_version/1` calls
  read from the in-memory association instead of issuing a second query — the
  read-then-resolve hot path becomes a single round trip.
  """
  @spec get_post(String.t(), String.t()) :: PublishingPost.t() | nil
  def get_post(group_slug, post_slug) do
    from(p in PublishingPost,
      join: g in assoc(p, :group),
      where: g.slug == ^group_slug and p.slug == ^post_slug and is_nil(p.trashed_at),
      preload: [group: g, active_version: :post]
    )
    |> repo().one()
  end

  @doc """
  Gets a timestamp-mode post by date and time.

  Truncates seconds from the input time since URLs use HH:MM format only,
  and new posts are stored with seconds zeroed. For older posts with non-zero
  seconds, falls back to hour:minute matching.
  """
  @spec get_post_by_datetime(String.t(), Date.t(), Time.t() | nil) :: PublishingPost.t() | nil
  def get_post_by_datetime(group_slug, %Date{} = date, nil) do
    # Date-only lookup — return the first post on this date (by time asc)
    # Preload :active_version (see get_post/2 docstring).
    from(p in PublishingPost,
      join: g in assoc(p, :group),
      where: g.slug == ^group_slug and p.post_date == ^date and is_nil(p.trashed_at),
      order_by: [asc: p.post_time],
      limit: 1,
      preload: [group: g, active_version: :post]
    )
    |> repo().one()
  end

  def get_post_by_datetime(group_slug, %Date{} = date, %Time{} = time) do
    # Normalize to zero seconds (URLs only carry HH:MM)
    normalized_time = %Time{hour: time.hour, minute: time.minute, second: 0, microsecond: {0, 0}}

    # Try exact match first (fast, uses index, works for all properly-stored posts)
    # Preload :active_version (see get_post/2 docstring).
    result =
      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where:
          g.slug == ^group_slug and p.post_date == ^date and p.post_time == ^normalized_time and
            is_nil(p.trashed_at),
        preload: [group: g, active_version: :post]
      )
      |> repo().one()

    if result do
      result
    else
      # Fallback for older posts stored with non-zero seconds
      hour = time.hour
      minute = time.minute

      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where:
          g.slug == ^group_slug and p.post_date == ^date and is_nil(p.trashed_at) and
            fragment(
              "EXTRACT(HOUR FROM ?)::integer = ? AND EXTRACT(MINUTE FROM ?)::integer = ?",
              p.post_time,
              ^hour,
              p.post_time,
              ^minute
            ),
        order_by: [asc: p.post_time],
        limit: 1,
        preload: [group: g, active_version: :post]
      )
      |> repo().one()
    end
  end

  @doc "Gets a post by UUID with preloads."
  @spec get_post_by_uuid(String.t(), list(atom() | tuple())) :: PublishingPost.t() | nil
  def get_post_by_uuid(uuid, preloads \\ []) do
    PublishingPost
    |> repo().get(uuid)
    |> maybe_preload(preloads)
  end

  @doc "Lists posts in a group, optionally filtered by status. Excludes trashed by default."
  @spec list_posts(String.t(), String.t() | nil) :: [PublishingPost.t()]
  def list_posts(group_slug, status \\ nil) do
    # Base query has no trashed_at filter — each status branch adds its own.
    # Composing additively means future base-query refinements (e.g. extra
    # joins / preloads) can't be silently dropped by a status branch that
    # rebuilds from scratch.
    base =
      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where: g.slug == ^group_slug,
        preload: [group: g]
      )

    base
    |> filter_by_status(status)
    |> order_by_mode()
    |> repo().all()
  end

  defp filter_by_status(query, "published"),
    do: where(query, [p], is_nil(p.trashed_at) and not is_nil(p.active_version_uuid))

  defp filter_by_status(query, "draft"),
    do: where(query, [p], is_nil(p.trashed_at) and is_nil(p.active_version_uuid))

  defp filter_by_status(query, "trashed"),
    do: where(query, [p], not is_nil(p.trashed_at))

  defp filter_by_status(query, _), do: where(query, [p], is_nil(p.trashed_at))

  @doc "Counts non-trashed posts in a group."
  @spec count_posts(String.t()) :: non_neg_integer()
  def count_posts(group_slug) do
    from(p in PublishingPost,
      join: g in assoc(p, :group),
      where: g.slug == ^group_slug and is_nil(p.trashed_at),
      select: count(p.uuid)
    )
    |> repo().one() || 0
  end

  @doc """
  Streams every post in a group (including trashed) for batch operations
  that shouldn't materialise the whole listing in memory.

  Caller MUST be inside a `Repo.checkout/1` (or an explicit transaction) —
  Postgres-backed Ecto streams require a checked-out connection. Yields raw
  `%PublishingPost{}` structs with `:group` preloaded; no version/content
  metadata (callers re-read what they need).
  """
  @spec stream_posts(String.t()) :: Enumerable.t()
  def stream_posts(group_slug) do
    from(p in PublishingPost,
      join: g in assoc(p, :group),
      where: g.slug == ^group_slug,
      preload: [group: g]
    )
    |> repo().stream(max_rows: 200)
  end

  @doc """
  Lists posts in timestamp mode (ordered by date/time desc).

  Options:
    * `:date` - Filter to a specific date (Date struct or ISO 8601 string)
  """
  @spec list_posts_timestamp_mode(String.t(), String.t() | nil, keyword()) :: [PublishingPost.t()]
  def list_posts_timestamp_mode(group_slug, status \\ nil, opts \\ []) do
    query =
      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where: g.slug == ^group_slug and is_nil(p.trashed_at),
        order_by: [desc: p.post_date, desc: p.post_time],
        preload: [group: g]
      )

    query =
      case status do
        "published" -> where(query, [p], not is_nil(p.active_version_uuid))
        "draft" -> where(query, [p], is_nil(p.active_version_uuid))
        _ -> query
      end

    query =
      case Keyword.get(opts, :date) do
        nil ->
          query

        %Date{} = date ->
          where(query, [p], p.post_date == ^date)

        date_string when is_binary(date_string) ->
          where(query, [p], p.post_date == ^Date.from_iso8601!(date_string))
      end

    repo().all(query)
  end

  @doc "Lists posts in slug mode (ordered by slug asc)."
  @spec list_posts_slug_mode(String.t(), String.t() | nil) :: [PublishingPost.t()]
  def list_posts_slug_mode(group_slug, status \\ nil) do
    query =
      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where: g.slug == ^group_slug and is_nil(p.trashed_at),
        order_by: [asc: p.slug],
        preload: [group: g]
      )

    case status do
      "published" -> where(query, [p], not is_nil(p.active_version_uuid))
      "draft" -> where(query, [p], is_nil(p.active_version_uuid))
      _ -> query
    end
    |> repo().all()
  end

  @doc "Finds a post by date and time (timestamp mode, matches hour:minute only)."
  @spec find_post_by_date_time(String.t(), Date.t(), Time.t() | nil) :: PublishingPost.t() | nil
  def find_post_by_date_time(group_slug, date, time) do
    get_post_by_datetime(group_slug, date, time)
  end

  @doc "Trashes a post by setting trashed_at timestamp."
  @spec trash_post(PublishingPost.t()) :: changeset_or_struct(PublishingPost.t())
  def trash_post(%PublishingPost{} = post) do
    post
    |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> repo().update()
  end

  @doc "Restores a trashed post by clearing trashed_at."
  @spec restore_post(PublishingPost.t()) :: changeset_or_struct(PublishingPost.t())
  def restore_post(%PublishingPost{} = post) do
    post
    |> Ecto.Changeset.change(trashed_at: nil)
    |> repo().update()
  end

  @doc "Hard-deletes a post and all its versions/contents (cascade)."
  @spec delete_post(PublishingPost.t()) :: changeset_or_struct(PublishingPost.t())
  def delete_post(%PublishingPost{} = post) do
    repo().delete(post)
  end

  # ===========================================================================
  # Versions
  # ===========================================================================

  @doc "Creates a new version for a post."
  @spec create_version(map()) :: changeset_or_struct(PublishingVersion.t())
  def create_version(attrs) do
    %PublishingVersion{}
    |> PublishingVersion.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a version."
  @spec update_version(PublishingVersion.t(), map()) :: changeset_or_struct(PublishingVersion.t())
  def update_version(%PublishingVersion{} = version, attrs) do
    version
    |> PublishingVersion.changeset(attrs)
    |> repo().update()
  end

  @doc "Gets the latest version for a post."
  @spec get_latest_version(String.t()) :: PublishingVersion.t() | nil
  def get_latest_version(post_uuid) do
    from(v in PublishingVersion,
      where: v.post_uuid == ^post_uuid,
      order_by: [desc: v.version_number],
      limit: 1
    )
    |> repo().one()
  end

  @doc """
  Gets the active (published) version for a post via active_version_uuid.

  Reads from the preloaded `:active_version` association if present (see
  `get_post/2`), otherwise falls back to a direct lookup. This keeps callers
  that received a hand-built struct working while letting the read paths
  short-circuit the second round trip.
  """
  @spec get_active_version(PublishingPost.t()) :: PublishingVersion.t() | nil
  def get_active_version(%PublishingPost{} = post) do
    case post do
      %PublishingPost{active_version_uuid: nil} ->
        nil

      %PublishingPost{active_version: %PublishingVersion{} = version} ->
        version

      %PublishingPost{active_version_uuid: uuid} when is_binary(uuid) ->
        repo().get(PublishingVersion, uuid)
    end
  end

  @doc "Gets a specific version by post and version number."
  @spec get_version(String.t(), pos_integer()) :: PublishingVersion.t() | nil
  def get_version(post_uuid, version_number) do
    repo().get_by(PublishingVersion,
      post_uuid: post_uuid,
      version_number: version_number
    )
  end

  @doc "Lists all versions for a post, ordered by version number."
  @spec list_versions(String.t()) :: [PublishingVersion.t()]
  def list_versions(post_uuid) do
    from(v in PublishingVersion,
      where: v.post_uuid == ^post_uuid,
      order_by: [asc: v.version_number]
    )
    |> repo().all()
  end

  @doc """
  Gets the next version number for a post.

  Uses SELECT ... FOR UPDATE to lock the row and prevent concurrent reads
  from getting the same number.
  """
  @spec next_version_number(String.t()) :: pos_integer()
  def next_version_number(post_uuid) do
    versions =
      from(v in PublishingVersion,
        where: v.post_uuid == ^post_uuid,
        select: v.version_number,
        lock: "FOR UPDATE"
      )
      |> repo().all()

    Enum.max(versions, fn -> 0 end) + 1
  end

  @doc """
  Creates a new version by cloning content from a source version.

  Creates a new version row and copies all content rows from the source.
  Also copies version-level data (featured_image, tags, seo, etc.).
  Wrapped in a transaction for atomicity.

  Returns `{:ok, %PublishingVersion{}}` or `{:error, reason}`.
  """
  @spec create_version_from(String.t(), pos_integer(), map() | keyword()) ::
          {:ok, PublishingVersion.t()} | {:error, term()}
  def create_version_from(post_uuid, source_version_number, opts \\ %{}) do
    repo().transaction(fn ->
      source_version = get_version(post_uuid, source_version_number)
      unless source_version, do: repo().rollback(:source_not_found)

      new_version = do_create_cloned_version(post_uuid, source_version, opts)
      copy_contents_to_version(source_version.uuid, new_version.uuid)
      new_version
    end)
  end

  defp do_create_cloned_version(post_uuid, source_version, opts) do
    new_number = next_version_number(post_uuid)

    # Carry forward version-level data (featured_image, tags, seo, etc.)
    source_data = source_version.data || %{}

    version_data =
      Map.merge(source_data, %{"created_from" => source_version.version_number})

    case create_version(%{
           post_uuid: post_uuid,
           version_number: new_number,
           status: "draft",
           created_by_uuid: opts[:created_by_uuid],
           data: version_data
         }) do
      {:ok, new_version} -> new_version
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp copy_contents_to_version(source_version_uuid, target_version_uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      list_contents(source_version_uuid)
      |> Enum.map(fn content ->
        %{
          uuid: UUIDv7.generate(),
          version_uuid: target_version_uuid,
          language: content.language,
          title: content.title || "",
          content: content.content || "",
          status: "draft",
          url_slug: content.url_slug,
          data: content.data || %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [] do
      case repo().insert_all(PublishingContent, rows, on_conflict: :nothing) do
        {count, _} when count >= 0 -> :ok
        _ -> repo().rollback(:content_copy_failed)
      end
    end
  end

  # ===========================================================================
  # Contents
  # ===========================================================================

  @doc "Creates content for a version/language."
  @spec create_content(map()) :: changeset_or_struct(PublishingContent.t())
  def create_content(attrs) do
    %PublishingContent{}
    |> PublishingContent.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates content."
  @spec update_content(PublishingContent.t(), map()) :: changeset_or_struct(PublishingContent.t())
  def update_content(%PublishingContent{} = content, attrs) do
    content
    |> PublishingContent.changeset(attrs)
    |> repo().update()
  end

  @doc "Deletes content."
  @spec delete_content(PublishingContent.t()) :: changeset_or_struct(PublishingContent.t())
  def delete_content(%PublishingContent{} = content) do
    repo().delete(content)
  end

  @doc "Bulk-updates the status of all content rows for a version."
  @spec update_content_status(String.t(), String.t()) :: {non_neg_integer(), nil}
  def update_content_status(version_uuid, new_status) do
    from(c in PublishingContent, where: c.version_uuid == ^version_uuid)
    |> repo().update_all(set: [status: new_status, updated_at: DateTime.utc_now()])
  end

  @doc "Bulk-updates the status of all content rows for a version, excluding a specific language."
  @spec update_content_status_except(String.t(), String.t(), String.t()) ::
          {non_neg_integer(), nil}
  def update_content_status_except(version_uuid, exclude_language, new_status) do
    from(c in PublishingContent,
      where: c.version_uuid == ^version_uuid and c.language != ^exclude_language
    )
    |> repo().update_all(set: [status: new_status, updated_at: DateTime.utc_now()])
  end

  @doc "Gets content for a specific version and language."
  @spec get_content(String.t(), String.t()) :: PublishingContent.t() | nil
  def get_content(version_uuid, language) do
    repo().get_by(PublishingContent,
      version_uuid: version_uuid,
      language: language
    )
  end

  @doc "Lists all content rows for a version."
  @spec list_contents(String.t()) :: [PublishingContent.t()]
  def list_contents(version_uuid) do
    from(c in PublishingContent,
      where: c.version_uuid == ^version_uuid,
      order_by: [asc: c.language]
    )
    |> repo().all()
  end

  @doc "Lists available languages for a version."
  @spec list_languages(String.t()) :: [String.t()]
  def list_languages(version_uuid) do
    from(c in PublishingContent,
      where: c.version_uuid == ^version_uuid,
      select: c.language,
      order_by: [asc: c.language]
    )
    |> repo().all()
  end

  @doc "Finds content by URL slug across all versions in a group. Excludes trashed posts."
  @spec find_by_url_slug(String.t(), String.t(), String.t()) :: PublishingContent.t() | nil
  def find_by_url_slug(group_slug, language, url_slug) do
    find_by_custom_url_slug(group_slug, language, url_slug) ||
      find_by_post_slug_fallback(group_slug, language, url_slug)
  end

  defp find_by_custom_url_slug(group_slug, language, url_slug) do
    from(c in PublishingContent,
      join: v in assoc(c, :version),
      join: p in assoc(v, :post),
      join: g in assoc(p, :group),
      where:
        g.slug == ^group_slug and c.language == ^language and c.url_slug == ^url_slug and
          is_nil(p.trashed_at),
      preload: [version: {v, post: {p, group: g}}]
    )
    |> repo().one()
  end

  defp find_by_post_slug_fallback(group_slug, language, url_slug) do
    from(c in PublishingContent,
      join: v in assoc(c, :version),
      join: p in assoc(v, :post),
      join: g in assoc(p, :group),
      where:
        g.slug == ^group_slug and c.language == ^language and p.slug == ^url_slug and
          is_nil(p.trashed_at) and
          (is_nil(c.url_slug) or c.url_slug == ""),
      preload: [version: {v, post: {p, group: g}}]
    )
    |> repo().one()
  end

  @doc "Finds content by a previous URL slug (stored in data.previous_url_slugs JSONB array). Excludes trashed posts."
  @spec find_by_previous_url_slug(String.t(), String.t(), String.t()) ::
          PublishingContent.t() | nil
  def find_by_previous_url_slug(group_slug, language, url_slug) do
    from(c in PublishingContent,
      join: v in assoc(c, :version),
      join: p in assoc(v, :post),
      join: g in assoc(p, :group),
      where:
        g.slug == ^group_slug and
          c.language == ^language and
          is_nil(p.trashed_at) and
          fragment("? @> ?", c.data, ^%{"previous_url_slugs" => [url_slug]}),
      preload: [version: {v, post: {p, group: g}}]
    )
    |> repo().one()
  end

  @doc "Clears a specific url_slug from all content rows of a post. Returns cleared language codes."
  @spec clear_url_slug_from_post(String.t(), String.t(), String.t()) :: [String.t()]
  def clear_url_slug_from_post(group_slug, post_slug, url_slug_to_clear) do
    case get_post(group_slug, post_slug) do
      nil ->
        []

      db_post ->
        contents =
          from(c in PublishingContent,
            join: v in assoc(c, :version),
            where: v.post_uuid == ^db_post.uuid and c.url_slug == ^url_slug_to_clear,
            select: {c, c.language}
          )
          |> repo().all()

        from(c in PublishingContent,
          join: v in assoc(c, :version),
          where: v.post_uuid == ^db_post.uuid and c.url_slug == ^url_slug_to_clear
        )
        |> repo().update_all(set: [url_slug: nil, updated_at: DateTime.utc_now()])

        Enum.map(contents, fn {_content, lang} -> lang end) |> Enum.uniq()
    end
  end

  @doc "Upserts content by version_id + language using ON CONFLICT."
  @spec upsert_content(map()) :: changeset_or_struct(PublishingContent.t())
  def upsert_content(attrs) do
    changeset = PublishingContent.changeset(%PublishingContent{}, attrs)

    repo().insert(changeset,
      on_conflict: {:replace, [:title, :content, :url_slug, :data, :updated_at]},
      conflict_target: [:version_uuid, :language],
      returning: true
    )
  end

  # ===========================================================================
  # Compound Operations
  # ===========================================================================

  @doc """
  Reads a full post with its latest version and content for a specific language.

  Returns a post map or nil if not found.
  """
  @spec read_post(String.t(), String.t(), String.t() | nil, pos_integer() | nil) ::
          {:ok, map()} | {:error, :not_found}
  def read_post(group_slug, post_slug, language \\ nil, version_number \\ nil) do
    with post when not is_nil(post) <- get_post(group_slug, post_slug),
         version when not is_nil(version) <- resolve_version(post, version_number),
         contents <- list_contents(version.uuid),
         content when not is_nil(content) <- resolve_content(contents, language) do
      all_versions = list_versions(post.uuid)

      {:ok, Mapper.to_post_map(post, version, content, contents, all_versions)}
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Reads a timestamp-mode post by date and time instead of slug.
  """
  @spec read_post_by_datetime(
          String.t(),
          Date.t(),
          Time.t() | nil,
          String.t() | nil,
          pos_integer() | nil
        ) :: {:ok, map()} | {:error, :not_found}
  def read_post_by_datetime(group_slug, date, time, language \\ nil, version_number \\ nil) do
    with post when not is_nil(post) <- get_post_by_datetime(group_slug, date, time),
         version when not is_nil(version) <- resolve_version(post, version_number),
         contents <- list_contents(version.uuid),
         content when not is_nil(content) <- resolve_content(contents, language) do
      all_versions = list_versions(post.uuid)

      {:ok, Mapper.to_post_map(post, version, content, contents, all_versions)}
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Lists all posts in a group with their latest version metadata.

  Returns a list of post maps suitable for listing pages.
  """
  @spec list_posts_with_metadata(String.t(), String.t() | nil) :: [map()]
  def list_posts_with_metadata(group_slug, status \\ nil) do
    posts = if status, do: list_posts(group_slug, status), else: list_posts(group_slug)
    post_uuids = Enum.map(posts, & &1.uuid)

    # Batch-load ALL versions for all posts in one query
    all_versions_by_post = batch_load_versions(post_uuids)

    # Find latest version per post
    latest_by_post =
      Map.new(all_versions_by_post, fn {post_uuid, versions} ->
        {post_uuid, List.last(versions)}
      end)

    # Also find published versions that differ from latest (for status overlay)
    published_by_post =
      Map.new(all_versions_by_post, fn {post_uuid, versions} ->
        {post_uuid, Enum.find(versions, fn v -> v.status == "published" end)}
      end)

    # Collect all version UUIDs we need contents for (latest + published if different)
    version_uuids_needed =
      Enum.flat_map(posts, fn post ->
        latest = latest_by_post[post.uuid]
        published = published_by_post[post.uuid]

        [latest, published]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.uuid)
        |> Enum.map(& &1.uuid)
      end)

    # Batch-load ALL contents for all needed versions in one query
    all_contents_by_version = batch_load_contents(version_uuids_needed)

    Enum.map(posts, fn post ->
      all_versions = Map.get(all_versions_by_post, post.uuid, [])
      version = latest_by_post[post.uuid]

      build_post_or_listing_map(
        post,
        all_versions,
        version,
        all_contents_by_version,
        published_by_post
      )
    end)
  end

  @doc """
  Lists all posts in a group in listing format (excerpt only, no full content).

  Always uses `Mapper.to_listing_map/4` which strips content bodies and includes
  only excerpts. Designed for caching in `:persistent_term` where data is copied
  to the reading process heap — keeping entries small matters.
  """
  @spec list_posts_for_listing(String.t()) :: [map()]
  def list_posts_for_listing(group_slug) do
    posts = list_posts(group_slug)
    post_uuids = Enum.map(posts, & &1.uuid)

    all_versions_by_post = batch_load_versions(post_uuids)

    # For the public listing, use the ACTIVE (published) version, not the latest draft.
    # This ensures the public site shows the content that's actually live.
    active_by_post =
      Map.new(posts, fn post ->
        active_uuid = Map.get(post, :active_version_uuid)
        versions = Map.get(all_versions_by_post, post.uuid, [])
        active_version = find_active_version(versions, active_uuid)
        {post.uuid, active_version}
      end)

    # Only load contents for posts that have an active version
    version_uuids_needed =
      active_by_post
      |> Map.values()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.uuid)

    all_contents_by_version = batch_load_contents(version_uuids_needed)

    posts
    |> Enum.filter(fn post -> active_by_post[post.uuid] != nil end)
    |> Enum.map(fn post ->
      all_versions = Map.get(all_versions_by_post, post.uuid, [])
      version = active_by_post[post.uuid]
      contents = Map.get(all_contents_by_version, version.uuid, [])

      Mapper.to_listing_map(post, version, contents, all_versions)
    end)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp build_post_or_listing_map(post, all_versions, nil, _all_contents, _published_by_post) do
    Mapper.to_listing_map(post, nil, [], all_versions)
  end

  defp build_post_or_listing_map(post, all_versions, version, all_contents, published_by_post) do
    contents = Map.get(all_contents, version.uuid, [])
    published_version = published_by_post[post.uuid]
    published_statuses = build_published_statuses(published_version, version, all_contents)
    primary_content = resolve_content(contents, nil)

    if primary_content do
      Mapper.to_post_map(post, version, primary_content, contents, all_versions,
        published_language_statuses: published_statuses
      )
    else
      Mapper.to_listing_map(post, version, contents, all_versions,
        published_language_statuses: published_statuses
      )
    end
  end

  defp find_active_version(_versions, nil), do: nil

  defp find_active_version(versions, active_uuid) do
    Enum.find(versions, fn v -> v.uuid == active_uuid end)
  end

  defp resolve_version(post, nil) do
    # Prefer the active (published) version; fall back to latest for unpublished posts
    get_active_version(post) || get_latest_version(post.uuid)
  end

  defp resolve_version(post, version_number), do: get_version(post.uuid, version_number)

  defp build_published_statuses(published_version, latest_version, all_contents_by_version) do
    if published_version && published_version.uuid != latest_version.uuid do
      # Status is version-level — all languages in the published version share its status
      Map.get(all_contents_by_version, published_version.uuid, [])
      |> Map.new(fn c -> {c.language, published_version.status} end)
    else
      %{}
    end
  end

  @doc """
  Resolves content for a language from a list of content rows.

  Fallback chain: exact language match → site default language → first available.
  """
  @spec resolve_content([PublishingContent.t()], String.t() | nil) :: PublishingContent.t() | nil
  def resolve_content(contents, nil) do
    default = LanguageHelpers.get_primary_language()

    Enum.find(contents, fn c -> c.language == default end) ||
      List.first(contents)
  end

  def resolve_content(contents, language) do
    default = LanguageHelpers.get_primary_language()

    Enum.find(contents, fn c -> c.language == language end) ||
      Enum.find(contents, fn c -> c.language == default end) ||
      List.first(contents)
  end

  defp order_by_mode(query) do
    # Timestamp-mode posts sort by post_date/post_time (the user-visible
    # publication date in the URL). Slug-mode posts have nil post_date and
    # post_time, so coalesce them to inserted_at — without the fallback,
    # a multi-post slug-mode listing would collapse onto a single inserted_at
    # tiebreaker (the previous behaviour) and slug-mode posts would all
    # cluster at the top of a mixed listing under PostgreSQL's default
    # NULLS FIRST DESC ordering.
    order_by(query, [p],
      desc:
        coalesce(
          p.post_date,
          fragment("CAST(? AS DATE)", p.inserted_at)
        ),
      desc:
        coalesce(
          p.post_time,
          fragment("CAST(? AS TIME)", p.inserted_at)
        ),
      desc: p.inserted_at
    )
  end

  @doc false
  @spec batch_load_versions([String.t()]) :: %{optional(String.t()) => [PublishingVersion.t()]}
  def batch_load_versions([]), do: %{}

  def batch_load_versions(post_uuids) do
    from(v in PublishingVersion,
      where: v.post_uuid in ^post_uuids,
      order_by: [asc: v.version_number]
    )
    |> repo().all()
    |> Enum.group_by(& &1.post_uuid)
  end

  @doc false
  @spec batch_load_contents([String.t()]) :: %{optional(String.t()) => [PublishingContent.t()]}
  def batch_load_contents([]), do: %{}

  def batch_load_contents(version_uuids) do
    from(c in PublishingContent,
      where: c.version_uuid in ^version_uuids,
      order_by: [asc: c.language]
    )
    |> repo().all()
    |> Enum.group_by(& &1.version_uuid)
  end

  defp maybe_preload(nil, _preloads), do: nil
  defp maybe_preload(record, []), do: record
  defp maybe_preload(record, preloads), do: repo().preload(record, preloads)
end
