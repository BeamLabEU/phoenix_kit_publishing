defmodule PhoenixKit.Modules.Publishing.Posts do
  @moduledoc """
  Post CRUD operations for the Publishing module.

  Handles creating, reading, updating, and trashing posts,
  as well as slug/version/language extraction and timestamp management.

  Posts are routing shells — versions are the source of truth for status,
  published_at, and metadata (featured_image, tags, seo, description).
  Content rows hold per-language title + body + url_slug.
  """

  require Logger

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.Constants

  @timestamp_modes Constants.timestamp_modes()
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Modules.Publishing.SlugHelpers
  alias PhoenixKit.Modules.Publishing.StaleFixer
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Suppress dialyzer false positives for pattern matches
  @dialyzer {:nowarn_function, create_post: 2}

  @max_timestamp_attempts 60

  @doc """
  Returns true when the given post is a DB-backed post (has a UUID).
  """
  @spec db_post?(map()) :: boolean()
  def db_post?(post), do: not is_nil(post[:uuid])

  @doc "Counts posts on a specific date for a group."
  def count_posts_on_date(group_slug, date) do
    group_slug
    |> list_times_on_date(date)
    |> length()
  end

  @doc "Lists time values for posts on a specific date."
  def list_times_on_date(group_slug, date) do
    date = if is_binary(date), do: Date.from_iso8601!(date), else: date

    group_slug
    |> DBStorage.list_posts_timestamp_mode("published", date: date)
    |> Enum.map(&(Time.to_string(&1.post_time) |> String.slice(0, 5)))
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    e ->
      Logger.warning(
        "[Publishing] list_times_on_date failed for #{group_slug}/#{date}: #{inspect(e)}"
      )

      []
  end

  @doc """
  Finds a post by URL slug from the database.
  """
  @spec find_by_url_slug(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_by_url_slug(group_slug, language, url_slug) do
    case find_content_with_stale_retry(
           group_slug,
           language,
           url_slug,
           &DBStorage.find_by_url_slug/3
         ) do
      nil -> {:error, :not_found}
      content -> {:ok, db_content_to_post_map(content)}
    end
  end

  @doc """
  Finds a post by a previous URL slug (for 301 redirects).
  """
  @spec find_by_previous_url_slug(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_by_previous_url_slug(group_slug, language, url_slug) do
    case find_content_with_stale_retry(
           group_slug,
           language,
           url_slug,
           &DBStorage.find_by_previous_url_slug/3
         ) do
      nil -> {:error, :not_found}
      content -> {:ok, db_content_to_post_map(content)}
    end
  end

  defp find_content_with_stale_retry(group_slug, language, url_slug, finder)
       when is_function(finder, 3) do
    case finder.(group_slug, language, url_slug) do
      nil ->
        retry_stale_slug_lookup(group_slug, language, url_slug, finder)

      content ->
        content
    end
  end

  defp retry_stale_slug_lookup(group_slug, language, url_slug, finder) do
    legacy_language = legacy_base_language(language)

    with legacy when is_binary(legacy) <- legacy_language,
         legacy_content when not is_nil(legacy_content) <- finder.(group_slug, legacy, url_slug),
         %_{version: %{post: db_post}} <- legacy_content do
      StaleFixer.fix_stale_post(db_post)
      finder.(group_slug, language, url_slug)
    else
      _ -> nil
    end
  end

  defp legacy_base_language(language) when is_binary(language) do
    base_language = DialectMapper.extract_base(language)
    if base_language != language, do: base_language, else: nil
  end

  defp legacy_base_language(_), do: nil

  @doc """
  Lists posts for a given publishing group slug.

  Queries the database directly via DBStorage.
  The optional second argument is accepted for API compatibility but unused.
  """
  @spec list_posts(String.t(), String.t() | nil) :: [map()]
  def list_posts(group_slug, _preferred_language \\ nil) do
    DBStorage.list_posts_with_metadata(group_slug)
  end

  @doc "Lists posts filtered by status (e.g. 'trashed', 'published')."
  @spec list_posts_by_status(String.t(), String.t()) :: [map()]
  def list_posts_by_status(group_slug, status) do
    DBStorage.list_posts_with_metadata(group_slug, status)
  end

  @doc "Lists raw DB post records for a group, optionally filtered by status."
  @spec list_raw_posts(String.t(), String.t() | nil) :: [struct()]
  def list_raw_posts(group_slug, status \\ nil) do
    if status,
      do: DBStorage.list_posts(group_slug, status),
      else: DBStorage.list_posts(group_slug)
  end

  @doc """
  Creates a new post for the given publishing group using the current timestamp.
  """
  @spec create_post(String.t(), map() | keyword()) :: {:ok, map()} | {:error, any()}
  def create_post(group_slug, opts \\ %{}) do
    case create_post_in_db(group_slug, opts) do
      {:ok, post} = result ->
        ActivityLog.log_manual(
          "publishing.post.created",
          ActivityLog.actor_uuid(opts),
          "publishing_post",
          post[:uuid] || post[:db_uuid],
          %{
            "group_slug" => group_slug,
            "slug" => post[:slug],
            "mode" => to_string(post[:mode] || "")
          }
        )

        result

      other ->
        other
    end
  end

  @doc """
  Reads a post by its database UUID.

  Resolves the UUID to a group slug and post slug, then delegates to `read_post/4`.
  Invalid version/language params gracefully fall back to latest/primary.
  """
  def read_post_by_uuid(post_uuid, language \\ nil, version \\ nil) do
    case DBStorage.get_post_by_uuid(post_uuid, [:group]) do
      nil ->
        {:error, :not_found}

      db_post ->
        db_post = StaleFixer.fix_stale_post(db_post)
        group_slug = db_post.group.slug
        resolved_language = resolve_language_to_dialect(language)
        version_number = if version, do: normalize_version_number(version), else: nil

        if db_post.post_date && db_post.post_time do
          DBStorage.read_post_by_datetime(
            group_slug,
            db_post.post_date,
            db_post.post_time,
            resolved_language,
            version_number
          )
        else
          DBStorage.read_post(group_slug, db_post.slug, resolved_language, version_number)
        end
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning("[Publishing] read_post_by_uuid failed for #{post_uuid}: #{inspect(e)}")
      {:error, :not_found}
  end

  @doc """
  Reads an existing post.

  For slug-mode groups, accepts an optional version parameter.
  If version is nil, reads the latest version.

  Reads from the database.
  """
  @spec read_post(String.t(), String.t(), String.t() | nil, integer() | nil) ::
          {:ok, map()} | {:error, any()}
  def read_post(group_slug, identifier, language \\ nil, version \\ nil) do
    read_post_from_db(group_slug, identifier, language, version)
  end

  @doc """
  Updates a post in the database.
  """
  @spec update_post(String.t(), map(), map(), map() | keyword()) ::
          {:ok, map()} | {:error, any()}
  def update_post(group_slug, post, params, opts \\ %{}) do
    # Normalize opts to map (callers may pass keyword list or map)
    opts_map = if Keyword.keyword?(opts), do: Map.new(opts), else: opts

    audit_meta =
      opts_map
      |> Shared.fetch_option(:scope)
      |> Shared.audit_metadata(:update)

    result = update_post_in_db(group_slug, post, params, audit_meta)

    with {:ok, updated_post} <- result do
      ListingCache.regenerate(group_slug)

      unless Map.get(opts_map, :skip_broadcast, false) do
        PublishingPubSub.broadcast_post_updated(group_slug, updated_post)
      end

      ActivityLog.log_manual(
        "publishing.post.updated",
        actor_uuid_for_log(opts_map, audit_meta),
        "publishing_post",
        updated_post[:uuid] || post[:uuid],
        %{
          "group_slug" => group_slug,
          "slug" => updated_post[:slug] || post[:slug],
          "language" => updated_post[:language] || post[:language]
        }
      )
    end

    result
  end

  # Activity-log actor preference: explicit opts > scope-derived audit
  # metadata. The audit_meta path keeps backwards compatibility with LV
  # callers that only pass scope today (C10 will switch them to opts).
  defp actor_uuid_for_log(opts_map, audit_meta) do
    ActivityLog.actor_uuid(opts_map) || audit_meta[:updated_by_uuid]
  end

  @doc """
  Restores a trashed post by UUID, clearing its trashed_at timestamp.

  Regenerates the group cache and broadcasts the update.
  Returns {:ok, post_uuid} on success or {:error, reason} on failure.
  """
  @spec restore_post(String.t(), String.t(), keyword() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def restore_post(group_slug, post_uuid, opts \\ []) do
    case DBStorage.get_post_by_uuid(post_uuid) do
      nil ->
        {:error, :not_found}

      db_post ->
        case DBStorage.update_post(db_post, %{trashed_at: nil}) do
          {:ok, _} ->
            ListingCache.regenerate(group_slug)
            PublishingPubSub.broadcast_post_updated(group_slug, %{uuid: db_post.uuid})

            ActivityLog.log_manual(
              "publishing.post.restored",
              ActivityLog.actor_uuid(opts),
              "publishing_post",
              db_post.uuid,
              %{"group_slug" => group_slug, "slug" => db_post.slug}
            )

            {:ok, post_uuid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Soft-deletes a post by UUID (sets trashed_at timestamp).

  Returns {:ok, post_uuid} on success or {:error, reason} on failure.
  """
  @spec trash_post(String.t(), String.t(), keyword() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def trash_post(group_slug, post_uuid, opts \\ []) do
    case DBStorage.get_post_by_uuid(post_uuid, [:group]) do
      nil ->
        {:error, :not_found}

      db_post ->
        case DBStorage.trash_post(db_post) do
          {:ok, _} ->
            broadcast_id = db_post.uuid
            ListingCache.regenerate(group_slug)
            PublishingPubSub.broadcast_post_deleted(group_slug, broadcast_id)

            ActivityLog.log_manual(
              "publishing.post.trashed",
              ActivityLog.actor_uuid(opts),
              "publishing_post",
              db_post.uuid,
              %{"group_slug" => group_slug, "slug" => db_post.slug}
            )

            {:ok, post_uuid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Extract slug, version, and language from a path identifier
  # Handles paths like:
  #   - "post-slug" → {"post-slug", nil, nil}
  #   - "post-slug/en" → {"post-slug", nil, "en"}
  #   - "post-slug/v1/en" → {"post-slug", 1, "en"}
  #   - "group/post-slug/v2/am" → {"post-slug", 2, "am"}
  def extract_slug_version_and_language(_group_slug, nil), do: {"", nil, nil}

  def extract_slug_version_and_language(group_slug, identifier) do
    parts =
      identifier
      |> to_string()
      |> String.trim()
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> drop_group_prefix(group_slug)

    case parts do
      [] ->
        {"", nil, nil}

      [slug] ->
        {slug, nil, nil}

      [slug | rest] ->
        # Extract version if present (v1, v2, v3, etc.)
        {version, rest_after_version} = Shared.extract_version_from_parts(rest)

        # Extract language from remaining parts
        language =
          rest_after_version
          |> List.first()
          |> case do
            nil -> nil
            <<>> -> nil
            lang_code -> lang_code
          end

        {slug, version, language}
    end
  end

  @doc false
  def read_back_post(group_slug, identifier, db_post, language, version_number) do
    Shared.read_back_post(group_slug, identifier, db_post, language, version_number)
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  # Converts a DBStorage content record (with preloaded version/post/group) to a post map
  defp db_content_to_post_map(content) do
    version = content.version
    post = version.post
    version_data = version.data || %{}

    %{
      slug: post.slug,
      url_slug: content.url_slug,
      language: content.language,
      metadata: %{
        title: content.title,
        status: version.status,
        description: version_data["description"]
      }
    }
  end

  defp create_post_in_db(group_slug, opts) do
    case DBStorage.get_group_by_slug(group_slug) do
      nil ->
        {:error, :group_not_found}

      group ->
        do_create_post_in_db(group_slug, group, opts)
    end
  end

  defp do_create_post_in_db(group_slug, group, opts) do
    scope = Shared.fetch_option(opts, :scope)
    mode = Publishing.get_group_mode(group_slug)
    primary_language = LanguageHelpers.get_primary_language()
    now = UtilsDate.utc_now()

    # Resolve user UUID for audit
    created_by_uuid = Shared.resolve_scope_user_uuids(scope)

    # Generate slug for slug-mode groups
    slug_result =
      case mode do
        "slug" ->
          title = Shared.fetch_option(opts, :title)
          preferred_slug = Shared.fetch_option(opts, :slug)
          SlugHelpers.generate_unique_slug(group_slug, title || "", preferred_slug)

        _ ->
          {:ok, nil}
      end

    with {:ok, post_slug} <- slug_result do
      # Build post attributes — posts are routing shells only
      post_attrs = %{
        group_uuid: group.uuid,
        slug: post_slug,
        mode: mode,
        created_by_uuid: created_by_uuid
      }

      post_attrs = maybe_add_initial_timestamp(post_attrs, mode, now)

      repo = PhoenixKit.RepoHelper.repo()

      tx_result =
        repo.transaction(fn ->
          create_post_in_transaction(
            repo,
            post_attrs,
            mode,
            group_slug,
            opts,
            primary_language,
            created_by_uuid,
            post_slug
          )
        end)

      with {:ok, db_post} <- tx_result,
           {:ok, post} <- read_back_created_post(group_slug, db_post, mode, primary_language) do
        ListingCache.regenerate(group_slug)
        PublishingPubSub.broadcast_post_created(group_slug, post)
        {:ok, post}
      end
    end
  end

  defp create_post_in_transaction(
         repo,
         post_attrs,
         mode,
         group_slug,
         opts,
         primary_language,
         created_by_uuid,
         post_slug
       ) do
    final_attrs = resolve_timestamp_in_transaction(post_attrs, mode, group_slug)

    with {:ok, db_post} <- DBStorage.create_post(final_attrs),
         {:ok, db_version} <-
           DBStorage.create_version(%{
             post_uuid: db_post.uuid,
             version_number: 1,
             status: "draft",
             created_by_uuid: created_by_uuid
           }),
         {:ok, _content} <-
           DBStorage.create_content(%{
             version_uuid: db_version.uuid,
             language: primary_language,
             title: Shared.fetch_option(opts, :title) || "",
             content: Shared.fetch_option(opts, :content) || "",
             url_slug: post_slug
           }) do
      db_post
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp maybe_add_initial_timestamp(post_attrs, "timestamp", now) do
    date = DateTime.to_date(now)
    time = %Time{hour: now.hour, minute: now.minute, second: 0, microsecond: {0, 0}}
    Map.merge(post_attrs, %{post_date: date, post_time: time})
  end

  defp maybe_add_initial_timestamp(post_attrs, _mode, _now), do: post_attrs

  defp resolve_timestamp_in_transaction(post_attrs, "timestamp", group_slug) do
    {date, time} =
      find_available_timestamp(group_slug, post_attrs.post_date, post_attrs.post_time)

    %{post_attrs | post_date: date, post_time: time}
  end

  defp resolve_timestamp_in_transaction(post_attrs, _mode, _group_slug), do: post_attrs

  defp read_back_created_post(group_slug, db_post, "timestamp", language) do
    DBStorage.read_post_by_datetime(group_slug, db_post.post_date, db_post.post_time, language, 1)
  end

  defp read_back_created_post(group_slug, db_post, _mode, language) do
    DBStorage.read_post(group_slug, db_post.slug, language, 1)
  end

  defp read_post_from_db(group_slug, identifier, language, version) do
    # If identifier is a UUID, resolve via UUID lookup (handles both modes)
    if Shared.uuid_format?(identifier) do
      read_post_by_uuid(identifier, language, version)
    else
      case Publishing.get_group_mode(group_slug) do
        "timestamp" ->
          read_post_from_db_timestamp(group_slug, identifier, language, version)

        _ ->
          read_post_from_db_slug(group_slug, identifier, language, version)
      end
    end
  end

  defp read_post_from_db_timestamp(group_slug, identifier, language, version) do
    case Shared.parse_timestamp_path(identifier) do
      {:ok, date, time, inferred_version, inferred_language} ->
        final_language = resolve_language_to_dialect(language || inferred_language)
        final_version = version || inferred_version
        version_number = normalize_version_number(final_version)

        case DBStorage.read_post_by_datetime(
               group_slug,
               date,
               time,
               final_language,
               version_number
             ) do
          {:ok, _} = ok ->
            ok

          {:error, :not_found} ->
            retry_stale_timestamp_post_read(
              group_slug,
              date,
              time,
              final_language,
              version_number
            )
        end

      _ ->
        # Fallback: try as slug-based lookup
        read_post_from_db_slug(group_slug, identifier, language, version)
    end
  end

  defp read_post_from_db_slug(group_slug, identifier, language, version) do
    {post_slug, inferred_version, inferred_language} =
      extract_slug_version_and_language(group_slug, identifier)

    final_language = resolve_language_to_dialect(language || inferred_language)
    final_version = version || inferred_version
    version_number = normalize_version_number(final_version)

    case DBStorage.read_post(group_slug, post_slug, final_language, version_number) do
      {:ok, _} = ok ->
        ok

      {:error, :not_found} ->
        retry_stale_slug_post_read(group_slug, post_slug, final_language, version_number)
    end
  end

  defp retry_stale_slug_post_read(group_slug, post_slug, language, version_number) do
    with legacy_language when is_binary(legacy_language) <- legacy_base_language(language),
         {:ok, _legacy_post} <-
           DBStorage.read_post(group_slug, post_slug, legacy_language, version_number),
         db_post when not is_nil(db_post) <- DBStorage.get_post(group_slug, post_slug) do
      StaleFixer.fix_stale_post(db_post)
      DBStorage.read_post(group_slug, post_slug, language, version_number)
    else
      _ -> {:error, :not_found}
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning(
        "[Publishing] retry_stale_slug_post_read failed for #{group_slug}/#{post_slug}: #{inspect(e)}"
      )

      {:error, :not_found}
  end

  defp retry_stale_timestamp_post_read(group_slug, date, time, language, version_number) do
    with legacy_language when is_binary(legacy_language) <- legacy_base_language(language),
         {:ok, _legacy_post} <-
           DBStorage.read_post_by_datetime(
             group_slug,
             date,
             time,
             legacy_language,
             version_number
           ),
         db_post when not is_nil(db_post) <-
           DBStorage.get_post_by_datetime(group_slug, date, time) do
      StaleFixer.fix_stale_post(db_post)
      DBStorage.read_post_by_datetime(group_slug, date, time, language, version_number)
    else
      _ -> {:error, :not_found}
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning(
        "[Publishing] retry_stale_timestamp_post_read failed for #{group_slug}/#{date}/#{time}: #{inspect(e)}"
      )

      {:error, :not_found}
  end

  defp normalize_version_number(nil), do: nil

  defp normalize_version_number(v) when is_integer(v) and v > 0, do: v
  defp normalize_version_number(v) when is_integer(v), do: nil

  defp normalize_version_number(v) do
    case Integer.parse("#{v}") do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  # Resolves base language codes (de, en) to stored BCP-47 dialect codes (de-DE, en-US).
  # Content rows store full dialect codes, but URL paths use base codes.
  defp resolve_language_to_dialect(nil), do: nil

  # Only resolve base codes (e.g. "en") to dialects (e.g. "en-US") if the base
  # code doesn't exist as an enabled language. If "en" is enabled, use "en" directly.
  defp resolve_language_to_dialect(language) do
    enabled = LanguageHelpers.enabled_language_codes()

    if language in enabled do
      language
    else
      base = DialectMapper.extract_base(language)

      if base == language do
        DialectMapper.base_to_dialect(language)
      else
        language
      end
    end
  end

  # Finds the next available minute for a timestamp-mode post.
  # If the given date/time is already taken, bumps forward by one minute at a time.
  # Limited to 60 attempts to prevent unbounded recursion.
  defp find_available_timestamp(group_slug, date, time, attempts \\ 0)

  defp find_available_timestamp(_group_slug, date, time, @max_timestamp_attempts) do
    {date, time}
  end

  defp find_available_timestamp(group_slug, date, time, attempts) do
    case DBStorage.get_post_by_datetime(group_slug, date, time) do
      nil ->
        {date, time}

      _existing ->
        # Bump by one minute
        total_seconds = time.hour * 3600 + time.minute * 60 + 60

        if total_seconds >= 86_400 do
          # Rolled past midnight — advance to next day at 00:00
          next_date = Date.add(date, 1)
          find_available_timestamp(group_slug, next_date, ~T[00:00:00], attempts + 1)
        else
          next_hour = div(total_seconds, 3600)
          next_minute = div(rem(total_seconds, 3600), 60)
          next_time = %Time{hour: next_hour, minute: next_minute, second: 0, microsecond: {0, 0}}
          find_available_timestamp(group_slug, date, next_time, attempts + 1)
        end
    end
  end

  # Updates a post in the database.
  # Writes title + content to the content row, version-level metadata to version.data.
  defp update_post_in_db(group_slug, post, params, audit_meta) do
    db_post = find_db_post_for_update(group_slug, post)

    cond do
      is_nil(db_post) ->
        {:error, :not_found}

      post[:mode] in @timestamp_modes || db_post.mode == "timestamp" ->
        do_update_post_in_db(db_post, post, params, group_slug, nil, audit_meta)

      true ->
        desired_slug = Map.get(params, "slug", post.slug)

        case maybe_update_db_slug(db_post, desired_slug, group_slug) do
          {:ok, final_slug} ->
            do_update_post_in_db(db_post, post, params, group_slug, final_slug, audit_meta)

          {:error, _reason} = error ->
            error
        end
    end
  rescue
    e ->
      Logger.warning("[Publishing] update_post_in_db failed: #{inspect(e)}")
      {:error, :db_update_failed}
  end

  # Find the DB post record for update, using UUID, date/time, or slug as available
  defp find_db_post_for_update(group_slug, post) do
    cond do
      # If we have a UUID, use it directly (most reliable)
      post[:uuid] ->
        DBStorage.get_post_by_uuid(post[:uuid], [:group])

      # Timestamp-mode: use date/time
      post[:mode] in @timestamp_modes && post[:date] && post[:time] ->
        DBStorage.get_post_by_datetime(group_slug, post[:date], post[:time])

      # Slug-mode: use slug
      post[:slug] ->
        DBStorage.get_post(group_slug, post[:slug])

      true ->
        nil
    end
  end

  defp maybe_update_db_slug(db_post, desired_slug, _group_slug)
       when desired_slug == db_post.slug do
    {:ok, db_post.slug}
  end

  defp maybe_update_db_slug(db_post, desired_slug, group_slug) do
    with {:ok, valid_slug} <- SlugHelpers.validate_slug(desired_slug),
         false <- SlugHelpers.slug_exists?(group_slug, valid_slug),
         {:ok, _} <- DBStorage.update_post(db_post, %{slug: valid_slug}) do
      {:ok, valid_slug}
    else
      true ->
        {:error, :slug_already_exists}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("[Publishing] slug update changeset error: #{inspect(changeset.errors)}")

        if Keyword.has_key?(changeset.errors, :slug),
          do: {:error, :slug_already_exists},
          else: {:error, :db_update_failed}

      {:error, reason} ->
        Logger.warning("[Publishing] slug update failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_update_post_in_db(db_post, post, params, group_slug, final_slug, audit_meta) do
    version_number = post[:version] || 1
    version = DBStorage.get_version(db_post.uuid, version_number)

    if version do
      language = post[:language] || LanguageHelpers.get_primary_language()
      post_metadata = post[:metadata] || %{}
      content = Map.get(params, "content", post[:content] || "")
      new_title = resolve_post_title(params, post, content)
      new_status = Map.get(params, "status", post_metadata[:status] || "draft")

      # Promote any legacy content.data keys that V2 stores at the version
      # level (description / featured_image_uuid / seo_title / excerpt). The
      # whitelist in `preserve_content_data` would otherwise wipe them on this
      # save; promotion runs once per legacy row and is logged via Activity.
      legacy_promotions = collect_legacy_content_promotions(version, language)

      with :ok <- validate_title_for_publish(language, new_status, new_title),
           :ok <- upsert_post_content(version, language, new_title, content, params, post),
           :ok <- update_version_defaults(version, params, post, legacy_promotions),
           {:ok, db_post} <- maybe_sync_datetime_and_audit(db_post, params, audit_meta) do
        log_legacy_metadata_promoted(legacy_promotions, version, language)
        read_updated_post(db_post, group_slug, final_slug, language, version_number)
      end
    else
      {:error, :not_found}
    end
  end

  @default_title Constants.default_title()

  defp validate_title_for_publish(language, "published", title)
       when title in ["", @default_title] do
    primary_language = LanguageHelpers.get_primary_language()

    if language == primary_language,
      do: {:error, :title_required},
      else: :ok
  end

  defp validate_title_for_publish(_language, _status, _title), do: :ok

  defp read_updated_post(db_post, group_slug, final_slug, language, version_number) do
    if db_post.mode == "timestamp" do
      DBStorage.read_post_by_datetime(
        group_slug,
        db_post.post_date,
        db_post.post_time,
        language,
        version_number
      )
    else
      DBStorage.read_post(group_slug, final_slug, language, version_number)
    end
  end

  defp resolve_post_title(params, post, _content) do
    post_metadata = post[:metadata] || %{}

    Map.get(params, "title") ||
      post_metadata[:title] ||
      Constants.default_title()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Writes title + content + language + url_slug to the content row.
  # Content rows no longer carry status or featured_image_uuid — those live on the version.
  defp upsert_post_content(version, language, new_title, content, params, post) do
    existing_content = DBStorage.get_content(version.uuid, language)
    existing_url_slug = if existing_content, do: existing_content.url_slug
    existing_data = if existing_content, do: existing_content.data || %{}, else: %{}

    resolved_url_slug =
      case Map.fetch(params, "url_slug") do
        {:ok, val} -> val
        :error -> existing_url_slug
      end

    # Content data only holds content-row-specific metadata (previous_url_slugs, etc.)
    content_data = preserve_content_data(existing_data, params, post)

    case DBStorage.upsert_content(%{
           version_uuid: version.uuid,
           language: language,
           title: new_title,
           content: content,
           url_slug: resolved_url_slug,
           data: content_data
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @content_only_data_keys ~w(previous_url_slugs updated_by_uuid custom_css)
  @legacy_promotable_keys ~w(description featured_image_uuid seo_title excerpt)

  # Preserve content-row-specific data on save.
  #
  # Three keys are genuinely per-language and stay on the content row:
  #   * `previous_url_slugs` — old slugs for 301 redirects
  #   * `updated_by_uuid`    — last-editor audit per language
  #   * `custom_css`         — per-language custom CSS
  #
  # Four V1 keys (`description`, `featured_image_uuid`, `seo_title`,
  # `excerpt`) are now version-level in V2; they're promoted up to
  # `version.data` by `collect_legacy_content_promotions/2` BEFORE this
  # function runs and then dropped here. The promotion happens once per
  # legacy row and is logged via `ActivityLog.log/1`.
  defp preserve_content_data(existing_data, _params, _post) do
    Map.take(existing_data, @content_only_data_keys)
  end

  # Reads the current content row and returns a map of legacy V1 keys that
  # are present on `content.data` but absent from `version.data`. The caller
  # merges this into the version update so the values land at the version
  # level on the same save the content row gets wiped clean. Returns `%{}`
  # when there's nothing to promote (the steady-state path).
  defp collect_legacy_content_promotions(version, language) do
    existing_content = DBStorage.get_content(version.uuid, language)
    content_data = (existing_content && existing_content.data) || %{}
    version_data = version.data || %{}

    @legacy_promotable_keys
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.fetch(content_data, key) do
        {:ok, value} ->
          if Map.has_key?(version_data, key), do: acc, else: Map.put(acc, key, value)

        :error ->
          acc
      end
    end)
  end

  defp log_legacy_metadata_promoted(promotions, _version, _language) when promotions == %{},
    do: :ok

  defp log_legacy_metadata_promoted(promotions, version, language) do
    PhoenixKit.Modules.Publishing.ActivityLog.log(%{
      action: "publishing.content.metadata_promoted",
      mode: "auto",
      resource_type: "publishing_content",
      resource_uuid: version.uuid,
      metadata: %{
        "language" => language,
        "version_uuid" => version.uuid,
        "promoted_keys" => Map.keys(promotions)
      }
    })

    :ok
  end

  @doc """
  Updates version.data with metadata like featured_image_uuid, description, seo_title, tags, etc.

  Version is the source of truth for all post metadata beyond title and body.
  Merges new values into existing version.data, preserving keys not present in
  the update. The optional `legacy_promotions` map is merged in BEFORE the
  user updates so legacy content.data values fall through unchanged when the
  user didn't touch them — the promotion path that pairs with
  `preserve_content_data`'s whitelist (see posts.ex `do_update_post_in_db`).
  """
  @spec update_version_defaults(struct(), map(), map(), map()) :: :ok | {:error, term()}
  def update_version_defaults(version, params, post, legacy_promotions \\ %{}) do
    existing_data = version.data || %{}
    post_metadata = post[:metadata] || %{}

    new_data =
      existing_data
      |> Map.merge(legacy_promotions)
      |> maybe_put_version_field("featured_image_uuid", Map.get(params, "featured_image_uuid"))
      |> maybe_put_version_field(
        "description",
        Map.get(params, "description", post_metadata[:description])
      )
      |> maybe_put_version_field("seo_title", Map.get(params, "seo_title"))
      |> maybe_put_version_field("tags", Map.get(params, "tags"))
      |> maybe_put_version_field("seo", Map.get(params, "seo"))
      |> maybe_put_version_field("excerpt", Map.get(params, "excerpt"))

    # Also update version-level status and published_at if provided
    version_attrs =
      %{data: new_data}
      |> maybe_put(:status, Map.get(params, "status"))
      |> maybe_put(:published_at, parse_published_at_from_params(params))

    case DBStorage.update_version(version, version_attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_version_field(data, _key, nil), do: data
  defp maybe_put_version_field(data, key, value), do: Map.put(data, key, value)

  defp parse_published_at_from_params(params) do
    case Map.get(params, "published_at") do
      nil ->
        nil

      "" ->
        nil

      dt_string when is_binary(dt_string) ->
        case DateTime.from_iso8601(dt_string) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      dt ->
        dt
    end
  end

  # Combined post-row update: timestamp-mode date/time sync (when
  # `published_at` changed) + audit metadata (`updated_by_uuid`,
  # `updated_by_email`). Issuing both as a single `update_post/2` halves
  # the number of round-trips per save (PR #2 review #6) and keeps the
  # post row's `updated_at` consistent across the two concerns.
  defp maybe_sync_datetime_and_audit(db_post, params, audit_meta) do
    attrs =
      %{}
      |> add_datetime_sync_attrs(db_post, params)
      |> maybe_put(:updated_by_uuid, audit_meta[:updated_by_uuid])
      |> maybe_put(:updated_by_email, audit_meta[:updated_by_email])

    if map_size(attrs) == 0 do
      {:ok, db_post}
    else
      case DBStorage.update_post(db_post, attrs) do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp add_datetime_sync_attrs(attrs, %{mode: "timestamp"} = db_post, params) do
    case parse_published_at_from_params(params) do
      nil ->
        attrs

      %DateTime{} = dt ->
        new_date = DateTime.to_date(dt)
        new_time = %Time{hour: dt.hour, minute: dt.minute, second: 0, microsecond: {0, 0}}

        if new_date != db_post.post_date or new_time != db_post.post_time do
          attrs
          |> Map.put(:post_date, new_date)
          |> Map.put(:post_time, new_time)
        else
          attrs
        end
    end
  end

  defp add_datetime_sync_attrs(attrs, _db_post, _params), do: attrs

  # Only drop group prefix if there are more elements after it
  # This prevents dropping the post slug when it matches the group slug
  defp drop_group_prefix([group_slug | rest], group_slug) when rest != [], do: rest
  defp drop_group_prefix(list, _), do: list
end
