defmodule PhoenixKit.Modules.Publishing.StaleFixer do
  @moduledoc """
  Fixes stale or invalid values on publishing records.

  Validates and corrects fields like mode, type, language, and
  timestamps across groups, posts, versions, and content. Also reconciles
  active_version_uuid consistency between posts and versions.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.RepoHelper

  # Posts younger than this are skipped by the stale fixer's empty-post deletion
  @grace_period_seconds 300

  @valid_types Constants.valid_types()
  @valid_group_modes Constants.valid_modes()
  @valid_group_statuses Constants.group_statuses()
  @valid_version_statuses Constants.content_statuses()
  @default_group_mode Constants.default_mode()
  @default_group_type Constants.default_type()

  @type_item_names %{
    "blog" => {"post", "posts"},
    "faq" => {"question", "questions"},
    "legal" => {"document", "documents"}
  }
  @default_item_singular "item"
  @default_item_plural "items"

  @doc """
  Fixes stale or invalid values on a publishing group record.

  Checks and corrects:
  - `mode` — must be "timestamp" or "slug" (defaults to "timestamp")
  - `data.type` — must be in valid_types (defaults to "custom")
  - `data.item_singular` — must be a non-empty string (defaults based on type)
  - `data.item_plural` — must be a non-empty string (defaults based on type)

  Can be called explicitly or runs lazily when groups are loaded in the admin.
  Returns the group unchanged if no fixes are needed.
  """
  @spec fix_stale_group(PublishingGroup.t()) :: PublishingGroup.t()
  def fix_stale_group(%PublishingGroup{} = group) do
    attrs = build_group_fixes(group)
    apply_stale_fix(group, attrs, &DBStorage.update_group/2)
  end

  defp build_group_fixes(group) do
    data = group.data || %{}
    type = Map.get(data, "type", @default_group_type)
    fixed_type = if type in @valid_types, do: type, else: "custom"
    fixed_mode = if group.mode in @valid_group_modes, do: group.mode, else: @default_group_mode
    fixed_status = if group.status in @valid_group_statuses, do: group.status, else: "active"

    {default_singular, default_plural} = default_item_names(fixed_type)
    item_singular = Map.get(data, "item_singular")
    item_plural = Map.get(data, "item_plural")

    fixed_singular = valid_string_or_default(item_singular, default_singular)
    fixed_plural = valid_string_or_default(item_plural, default_plural)

    data_changes =
      data
      |> maybe_update("type", type, fixed_type)
      |> maybe_update("item_singular", item_singular, fixed_singular)
      |> maybe_update("item_plural", item_plural, fixed_plural)

    attrs = if data_changes != data, do: %{data: data_changes}, else: %{}
    attrs = if fixed_mode != group.mode, do: Map.put(attrs, :mode, fixed_mode), else: attrs
    if fixed_status != group.status, do: Map.put(attrs, :status, fixed_status), else: attrs
  end

  defp valid_string_or_default(val, default) do
    if is_binary(val) and val != "", do: val, else: default
  end

  @doc """
  Fixes stale or invalid values on a publishing post record.

  Checks and corrects:
  - `mode` — must be "timestamp" or "slug" (defaults to "timestamp")
  - `post_date`/`post_time` — must be present for timestamp mode posts
  - `active_version_uuid` — must point to a valid, published version

  Deletes empty posts (no content in any version) that are past the grace period.
  """
  @spec fix_stale_post(PublishingPost.t()) :: PublishingPost.t()
  # Tracks whether any fixer wrote during this fix_stale_post call, so the
  # group's listing cache is invalidated exactly when a self-heal changed
  # something. The fixers run on the public READ path: without this, a
  # relabelled/merged language row kept serving the cached pre-heal
  # language_titles/slugs/available_languages indefinitely on a quiet site —
  # and invalidating unconditionally would nuke the cache on EVERY post read
  # (read_post_by_uuid runs the fixer each time). Process-local: the whole
  # fix runs synchronously in the calling process, and mark_listing_dirty/0
  # no-ops when the flag isn't armed (standalone fix_stale_content/version
  # calls behave as before).
  @dirty_flag {__MODULE__, :listing_cache_dirty}

  def fix_stale_post(%PublishingPost{} = post) do
    Process.put(@dirty_flag, false)

    try do
      # Pre-fetch all versions and contents once to avoid redundant queries
      ctx = build_post_context(post)
      result = do_fix_stale_post(post, ctx)

      if Process.get(@dirty_flag) == true, do: invalidate_group_listing(result)

      result
    after
      Process.delete(@dirty_flag)
    end
  end

  defp mark_listing_dirty do
    if Process.get(@dirty_flag) == false, do: Process.put(@dirty_flag, true)
    :ok
  end

  defp cas_clear_pointer(post, active_uuid, version) do
    case DBStorage.clear_active_version_if(post.uuid, active_uuid) do
      1 ->
        Logger.info(
          "[Publishing] Clearing stale active_version_uuid for post #{post.uuid}: " <>
            "version #{inspect(active_uuid)} is #{if version, do: version.status, else: "missing"}"
        )

        mark_listing_dirty()

      _ ->
        Logger.debug(
          "[Publishing] Skipped stale-pointer clear for #{post.uuid} — " <>
            "the pointer moved (concurrent publish)"
        )
    end
  end

  defp invalidate_group_listing(%PublishingPost{} = post) do
    case post.group do
      %PublishingGroup{slug: slug} when is_binary(slug) ->
        ListingCache.invalidate(slug)

      _ ->
        case DBStorage.get_post_by_uuid(post.uuid, [:group]) do
          %PublishingPost{group: %PublishingGroup{slug: slug}} when is_binary(slug) ->
            ListingCache.invalidate(slug)

          _ ->
            :ok
        end
    end
  rescue
    _ -> :ok
  end

  defp invalidate_group_listing(_), do: :ok

  defp build_post_context(post) do
    versions = DBStorage.list_versions(post.uuid)
    version_uuids = Enum.map(versions, & &1.uuid)
    contents_by_version = DBStorage.batch_load_contents(version_uuids)
    %{versions: versions, contents_by_version: contents_by_version}
  end

  defp do_fix_stale_post(post, ctx) do
    # Trash (soft-delete) empty posts (no content + no featured image in any
    # version) — abandoned drafts. Skip recently created posts so the editor has
    # time to autosave, and skip already-trashed posts so a restore isn't fought
    # in a tight loop. Trash (not hard-delete) keeps it recoverable and logged.
    if empty_post?(ctx) and past_grace_period?(post) and is_nil(post.trashed_at) do
      trash_empty_post(post)
      post
    else
      post = apply_stale_fix(post, build_post_fixes(post, ctx), &DBStorage.update_post/2)

      # Pointer heal is a discrete CAS step (not part of build_post_fixes):
      # it re-reads the post afterwards so the orphan demotion below never
      # runs off a stale pointer — the exact combination that could revert a
      # concurrent publish (clear the fresh pointer, then draft the freshly
      # published version).
      post = fix_active_pointer_cas(post, ctx)

      # Fix version/content-level issues
      demote_orphaned_published_versions(post, ctx)
      fix_multiple_published_versions(post, ctx)

      for version <- ctx.versions do
        fix_stale_version(version)
        contents = Map.get(ctx.contents_by_version, version.uuid, [])
        Enum.each(contents, &fix_stale_content/1)
      end

      DBStorage.get_post_by_uuid(post.uuid, [:group]) || post
    end
  end

  # `fix_stale_post/1` runs on the read path, so two concurrent requests can both
  # decide to trash the same empty post — the loser hits Ecto.StaleEntryError.
  # A read must never 500 over that benign race; the post is trashed either way.
  defp trash_empty_post(post) do
    Logger.info("[Publishing] Trashing empty post #{post.uuid} (no content in any version)")

    case DBStorage.update_post(post, %{trashed_at: DateTime.utc_now()}) do
      {:ok, _} ->
        mark_listing_dirty()

        ActivityLog.log_manual(
          "publishing.post.auto_trashed",
          nil,
          "publishing_post",
          post.uuid,
          %{"reason" => "empty_post", "group_uuid" => post.group_uuid}
        )

      {:error, _reason} ->
        :ok
    end
  rescue
    Ecto.StaleEntryError ->
      Logger.debug("[Publishing] Empty post #{post.uuid} already removed by a concurrent request")

      :ok
  end

  defp empty_post?(ctx) do
    ctx.versions == [] or Enum.all?(ctx.versions, &version_empty?(ctx, &1))
  end

  defp version_empty?(ctx, version) do
    not version_has_featured_image?(version) and version_contents_empty?(ctx, version)
  end

  # A featured-image-only version (no title/body) still holds user content — it
  # must NOT count as empty, or the auto-trash would discard the image.
  defp version_has_featured_image?(version) do
    case (version.data || %{})["featured_image_uuid"] do
      uuid when is_binary(uuid) and uuid != "" -> true
      _ -> false
    end
  end

  defp version_contents_empty?(ctx, version) do
    contents = Map.get(ctx.contents_by_version, version.uuid, [])
    contents == [] or Enum.all?(contents, &content_empty?/1)
  end

  defp content_empty?(c) do
    (c.content || "") == "" and (c.title || "") in ["", Constants.default_title()]
  end

  defp past_grace_period?(post) do
    case post.inserted_at do
      nil -> true
      inserted_at -> DateTime.diff(DateTime.utc_now(), inserted_at) >= @grace_period_seconds
    end
  end

  defp build_post_fixes(post, ctx) do
    %{}
    |> maybe_fix_post_mode(post)
    |> maybe_fix_post_slug(post, ctx)
    |> maybe_fix_post_timestamp(post)
  end

  defp maybe_fix_post_mode(attrs, post) do
    fixed_mode = resolve_post_mode(post)
    if fixed_mode != post.mode, do: Map.put(attrs, :mode, fixed_mode), else: attrs
  end

  defp resolve_post_mode(post) do
    group = if post.group, do: post.group, else: DBStorage.get_group(post.group_uuid)
    fallback_mode = if post.mode in @valid_group_modes, do: post.mode, else: @default_group_mode

    if group && group.mode in @valid_group_modes do
      group.mode
    else
      fallback_mode
    end
  end

  defp maybe_fix_post_slug(attrs, post, ctx) do
    effective_mode = attrs[:mode] || post.mode

    needs_slug =
      effective_mode == "slug" and (is_nil(post.slug) or post.slug == "")

    if needs_slug do
      generate_and_assign_slug(attrs, post, ctx)
    else
      attrs
    end
  end

  # Builds a candidate slug for the post. The probe is a happy-path
  # optimisation — most stale-fixer runs land on a free slug. The
  # `(group_uuid, slug)` UNIQUE INDEX backs the operation: a concurrent
  # fixer that wins the race causes the eventual `update_post` call to
  # return `{:error, %Ecto.Changeset{}}` with a `:slug` unique error,
  # and `apply_stale_fix/3` retries once with the deterministic
  # `post_uuid` suffix appended (PR #9 follow-up — Pincer review).
  defp ensure_unique_slug(group_uuid, slug, post_uuid) do
    conflict =
      from(p in PublishingPost,
        where: p.group_uuid == ^group_uuid and p.slug == ^slug and p.uuid != ^post_uuid,
        select: p.uuid,
        limit: 1
      )
      |> PhoenixKit.RepoHelper.repo().one()

    if conflict do
      slug_with_post_suffix(slug, post_uuid)
    else
      slug
    end
  end

  defp slug_with_post_suffix(slug, post_uuid) do
    suffix = String.slice(post_uuid || "", 0, 8)
    "#{slug}-#{suffix}"
  end

  defp generate_and_assign_slug(attrs, post, ctx) do
    base_slug = generate_slug_for_post(post, ctx)

    if base_slug != "" do
      slug = ensure_unique_slug(post.group_uuid, base_slug, post.uuid)

      Logger.info(
        "[Publishing] Generating slug for post #{post.uuid}: #{inspect(slug)} (mode changed to slug)"
      )

      Map.put(attrs, :slug, slug)
    else
      Logger.warning(
        "[Publishing] Failed to generate slug for post #{post.uuid} — post will be unreachable in slug mode"
      )

      attrs
    end
  end

  defp generate_slug_for_post(post, ctx) do
    title = extract_primary_title(ctx)
    base = pick_slug_base(title, post)

    base
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp extract_primary_title(ctx) do
    primary_lang = LanguageHelpers.get_primary_language()

    with [_ | _] <- ctx.versions,
         latest <- List.last(ctx.versions),
         contents <- Map.get(ctx.contents_by_version, latest.uuid, []),
         %{title: title} <- Enum.find(contents, &(&1.language == primary_lang)) do
      title
    else
      _ -> nil
    end
  end

  defp pick_slug_base(title, post)
       when is_binary(title) and title != "" do
    if title == Constants.default_title(), do: slug_fallback(post), else: title
  end

  defp pick_slug_base(_title, post), do: slug_fallback(post)

  defp slug_fallback(%{post_date: post_date}) when not is_nil(post_date) do
    Date.to_iso8601(post_date)
  end

  defp slug_fallback(post) do
    "post-#{String.slice(post.uuid || "", 0, 8)}"
  end

  defp maybe_fix_post_timestamp(attrs, post) do
    if (attrs[:mode] || post.mode) == "timestamp" do
      fill_missing_timestamp(attrs, post)
    else
      attrs
    end
  end

  defp fill_missing_timestamp(attrs, post) do
    now = DateTime.utc_now()
    attrs = maybe_set_date(attrs, post.post_date, now)
    maybe_set_time(attrs, post.post_time, now)
  end

  defp maybe_set_date(attrs, nil, now), do: Map.put(attrs, :post_date, DateTime.to_date(now))
  defp maybe_set_date(attrs, _date, _now), do: attrs

  defp maybe_set_time(attrs, nil, now),
    do: Map.put(attrs, :post_time, Time.new!(now.hour, now.minute, 0))

  defp maybe_set_time(attrs, _time, _now), do: attrs

  # If active_version_uuid points to a non-existent or non-published version, clear it
  defp fix_active_pointer_cas(%{active_version_uuid: nil} = post, _ctx), do: post

  defp fix_active_pointer_cas(post, ctx) do
    active_uuid = post.active_version_uuid
    version = Enum.find(ctx.versions, &(&1.uuid == active_uuid))

    if is_nil(version) or not Constants.published?(version.status) do
      # Compare-and-swap: clear only while the row STILL points at the
      # version this snapshot judged stale. The fixer runs lockless on the
      # read path — a publish committing between our post read and here
      # moved the pointer to a fresh version, and an unconditional write
      # reverted that publish.
      cas_clear_pointer(post, active_uuid, version)

      # Fresh re-read so downstream fixers (orphan demotion) never decide
      # off the stale pointer.
      DBStorage.get_post_by_uuid(post.uuid, [:group]) || post
    else
      post
    end
  end

  @doc false
  # Exposed (with @doc false) for the slug-conflict-retry test. Production
  # callers always go through `fix_stale_post/1` / `fix_stale_group/1`.
  def apply_stale_fix(record, attrs, update_fn \\ &DBStorage.update_post/2)

  def apply_stale_fix(record, attrs, _update_fn) when attrs == %{}, do: record

  def apply_stale_fix(record, attrs, update_fn) do
    identifier = Map.get(record, :uuid) || Map.get(record, :slug) || "unknown"

    Logger.info(
      "[Publishing] Fixing stale values for #{record.__struct__} #{identifier}: #{inspect(attrs)}"
    )

    case update_fn.(record, attrs) do
      {:ok, updated} ->
        mark_listing_dirty()
        updated

      {:error, %Ecto.Changeset{} = cs} ->
        case retry_on_slug_conflict(record, attrs, cs, update_fn) do
          {:ok, updated} ->
            mark_listing_dirty()
            updated

          {:error, reason} ->
            warn_stale_fix_failed(identifier, reason)
            record
        end

      {:error, reason} ->
        warn_stale_fix_failed(identifier, reason)
        record
    end
  end

  defp warn_stale_fix_failed(identifier, reason) do
    Logger.warning(
      "[Publishing] Failed to fix stale values for #{identifier}: #{inspect(reason)}"
    )
  end

  # Recovery for the rare race where a concurrent stale-fixer pass committed
  # the same slug between our `ensure_unique_slug/3` probe and the eventual
  # `update_post`. The DB unique index (`idx_publishing_posts_group_slug`)
  # rejects the second writer; we suffix with the deterministic
  # `post_uuid[0..8]` and retry once. Any other constraint failure (or a
  # second slug collision after the suffix — practically impossible with a
  # UUIDv7 prefix) propagates the error so the stale fixer logs and skips.
  defp retry_on_slug_conflict(record, attrs, cs, update_fn) do
    cond do
      not slug_conflict?(cs) ->
        {:error, cs}

      not Map.has_key?(attrs, :slug) ->
        {:error, cs}

      not is_binary(Map.get(record, :uuid)) ->
        {:error, cs}

      true ->
        retry_attrs = Map.put(attrs, :slug, slug_with_post_suffix(attrs.slug, record.uuid))
        update_fn.(record, retry_attrs)
    end
  end

  # PublishingPost's unique_constraint is declared on [:group_uuid, :slug]
  # which puts the error on the FIRST key (`:group_uuid`). Look at both
  # plus match the constraint name so we don't confuse a real
  # foreign-key error on group_uuid with the slug-uniqueness path.
  defp slug_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?([:slug, :group_uuid], fn key ->
      case Keyword.get(errors, key) do
        {_msg, opts} ->
          Keyword.get(opts, :constraint) == :unique and
            Keyword.get(opts, :constraint_name) == "idx_publishing_posts_group_slug"

        _ ->
          false
      end
    end)
  end

  defp maybe_update(data, key, old_val, new_val) do
    if old_val != new_val, do: Map.put(data, key, new_val), else: data
  end

  @doc """
  Fixes stale values across all groups, posts, versions, and content.
  Also reconciles active_version_uuid consistency and ensures single published version.
  Callable via internal API or IEx.

  Streams the per-group post listing inside a `Repo.checkout/1` so the BEAM
  doesn't have to hold every post in memory at once for large catalogues
  (PR #9 follow-up — Pincer review). Group fix-up still loads the group
  list eagerly because the count is bounded by the number of CMS sections
  (typically <100), and `fix_stale_group/1` mutates rows that the post
  pass also reads.
  """
  @spec fix_all_stale_values() :: :ok
  def fix_all_stale_values do
    # Scan ALL groups (including trashed) — pass nil to skip status filter
    groups = DBStorage.list_groups(nil)
    Enum.each(groups, &fix_stale_group/1)

    PhoenixKit.RepoHelper.repo().checkout(fn ->
      for group <- groups do
        DBStorage.stream_posts(group.slug)
        |> Stream.each(&fix_stale_post/1)
        |> Stream.run()
      end
    end)

    :ok
  end

  def fix_stale_version(version) do
    if version.status not in @valid_version_statuses do
      Logger.info(
        "[Publishing] Fixing stale version #{version.uuid}: status #{inspect(version.status)} → \"draft\""
      )

      case DBStorage.update_version(version, %{status: "draft"}) do
        {:ok, _} = ok ->
          mark_listing_dirty()
          ok

        other ->
          other
      end
    end
  end

  def fix_stale_content(content) do
    case normalize_content_language(content) do
      {:deleted, _target_language} ->
        :ok

      {:ok, normalized_content} ->
        apply_content_fixes(normalized_content)

      :unchanged ->
        apply_content_fixes(content)
    end
  end

  defp apply_content_fixes(content) do
    attrs =
      %{}
      |> maybe_fix_content_status(content)
      |> maybe_fix_blank_content_language(content)

    if attrs != %{} do
      Logger.info(
        "[Publishing] Fixing stale content #{content.uuid} (#{content.language}): #{inspect(attrs)}"
      )

      case DBStorage.update_content(content, attrs) do
        {:ok, _} = ok ->
          mark_listing_dirty()
          ok

        other ->
          other
      end
    end
  end

  defp maybe_fix_content_status(attrs, content) do
    if content.status in @valid_version_statuses,
      do: attrs,
      else: Map.put(attrs, :status, "draft")
  end

  defp maybe_fix_blank_content_language(attrs, content) do
    if is_binary(content.language) and content.language != "" do
      attrs
    else
      Map.put(attrs, :language, LanguageHelpers.get_primary_language())
    end
  end

  defp normalize_content_language(%PublishingContent{} = content) do
    target_language = normalized_content_language(content.language)

    cond do
      target_language in [nil, "", content.language] ->
        :unchanged

      target = DBStorage.get_content(content.version_uuid, target_language) ->
        case merge_duplicate_language_content(target, content) do
          {:ok, _} -> {:deleted, target_language}
          {:error, _reason} -> :unchanged
        end

      true ->
        Logger.info(
          "[Publishing] Normalizing legacy content language #{content.uuid}: " <>
            "#{inspect(content.language)} → #{inspect(target_language)}"
        )

        case DBStorage.update_content(content, %{language: target_language}) do
          {:ok, updated} ->
            mark_listing_dirty()

            ActivityLog.log(%{
              action: "publishing.content.language_normalized",
              mode: "auto",
              resource_type: "publishing_content",
              resource_uuid: updated.uuid,
              metadata: %{
                "from_language" => content.language,
                "to_language" => target_language,
                "version_uuid" => content.version_uuid
              }
            })

            {:ok, updated}

          {:error, reason} ->
            Logger.warning(
              "[Publishing] Failed to normalize content language for #{content.uuid}: #{inspect(reason)}"
            )

            :unchanged
        end
    end
  end

  defp normalized_content_language(language) when is_binary(language) and language != "" do
    enabled_languages = LanguageHelpers.enabled_language_codes()

    cond do
      not base_language_code?(language) ->
        language

      language in enabled_languages ->
        language

      target =
          LanguageHelpers.resolve_dialect_for_base(language, enabled_languages,
            prefer: LanguageHelpers.get_primary_language(),
            exclude: language
          ) ->
        target

      true ->
        language
    end
  end

  defp normalized_content_language(_), do: nil

  defp base_language_code?(language), do: LanguageHelpers.base_language_code?(language)

  defp merge_duplicate_language_content(target, legacy) do
    attrs = build_duplicate_content_merge_attrs(target, legacy)
    repo = RepoHelper.repo()

    result =
      repo.transaction(fn ->
        with :ok <- apply_merge_attrs(target, attrs),
             {:ok, _} <- DBStorage.delete_content(legacy) do
          :ok
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        mark_listing_dirty()

        Logger.info(
          "[Publishing] Merged duplicate legacy content #{legacy.uuid} into #{target.uuid}"
        )

        ActivityLog.log(%{
          action: "publishing.content.merged",
          mode: "auto",
          resource_type: "publishing_content",
          resource_uuid: target.uuid,
          metadata: %{
            "merged_from_uuid" => legacy.uuid,
            "from_language" => legacy.language,
            "to_language" => target.language,
            "version_uuid" => target.version_uuid,
            # True when a divergent non-blank legacy body lost to the target's
            # — its text is stashed in the merged row's data["_stale_fixer"].
            "discarded_body" =>
              not blank_string?(target.content) and not blank_string?(legacy.content) and
                target.content != legacy.content
          }
        })

        {:ok, target}

      {:error, reason} = error ->
        Logger.warning(
          "[Publishing] Failed to merge duplicate legacy content #{legacy.uuid} into #{target.uuid}: #{inspect(reason)}"
        )

        error
    end
  end

  defp apply_merge_attrs(_target, attrs) when map_size(attrs) == 0, do: :ok

  defp apply_merge_attrs(target, attrs) do
    case DBStorage.update_content(target, attrs) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # A discarded body is capped so a huge markdown blob doesn't bloat every
  # merged row's JSONB — the stash is recovery insurance, not a mirror.
  @discarded_body_cap 100_000

  defp build_duplicate_content_merge_attrs(target, legacy) do
    merged_data =
      target.data
      |> Kernel.||(%{})
      |> merge_content_data(legacy.data || %{}, target.url_slug, legacy.url_slug)
      |> maybe_stash_discarded_body(target, legacy)

    %{}
    |> maybe_take_legacy_title(target, legacy)
    |> maybe_take_legacy_body(target, legacy)
    |> maybe_take_legacy_url_slug(target, legacy)
    |> maybe_take_legacy_status(target, legacy)
    |> maybe_put_merged_data(target.data || %{}, merged_data)
  end

  # Target-wins is the right convergence rule (the target is the canonical
  # dialect row), but silently DELETING a divergent non-blank legacy body is
  # unrecoverable — there is no UI path back and the activity row carries
  # uuids, not text. Stash it under a reserved key the mappers never read,
  # so support can recover it. Public rendering is unaffected. The key is in
  # Posts' @content_only_data_keys whitelist so an edit can't wipe it, and
  # the stash is a LIST so a second heal can't overwrite the first.
  defp maybe_stash_discarded_body(merged_data, target, legacy) do
    # Union BOTH rows' prior stash lists — merge_content_data lets the
    # target's data win wholesale, which silently dropped a previously
    # healed legacy row's own discarded-body list with the deleted row.
    target_prior = get_in(merged_data, ["_stale_fixer", "discarded"]) || []
    legacy_prior = get_in(legacy.data || %{}, ["_stale_fixer", "discarded"]) || []
    prior = target_prior ++ (legacy_prior -- target_prior)

    entries =
      if not blank_string?(target.content) and not blank_string?(legacy.content) and
           target.content != legacy.content do
        entry = %{
          "discarded_content" => String.slice(legacy.content, 0, @discarded_body_cap),
          "from_uuid" => legacy.uuid,
          "from_language" => legacy.language
        }

        [entry | prior]
      else
        prior
      end

    if entries == [] do
      merged_data
    else
      Map.put(merged_data, "_stale_fixer", %{"discarded" => entries})
    end
  end

  defp maybe_take_legacy_title(attrs, target, legacy) do
    if weak_title?(target.title) and strong_title?(legacy.title) do
      Map.put(attrs, :title, legacy.title)
    else
      attrs
    end
  end

  defp maybe_take_legacy_body(attrs, target, legacy) do
    if blank_string?(target.content) and not blank_string?(legacy.content) do
      Map.put(attrs, :content, legacy.content)
    else
      attrs
    end
  end

  defp maybe_take_legacy_url_slug(attrs, target, legacy) do
    if blank_string?(target.url_slug) and not blank_string?(legacy.url_slug) do
      Map.put(attrs, :url_slug, legacy.url_slug)
    else
      attrs
    end
  end

  defp maybe_take_legacy_status(attrs, target, legacy) do
    if target.status not in @valid_version_statuses and legacy.status in @valid_version_statuses do
      Map.put(attrs, :status, legacy.status)
    else
      attrs
    end
  end

  defp maybe_put_merged_data(attrs, current_data, merged_data) do
    if merged_data != current_data do
      Map.put(attrs, :data, merged_data)
    else
      attrs
    end
  end

  defp merge_content_data(target_data, legacy_data, target_url_slug, legacy_url_slug) do
    merged_previous_slugs =
      [
        Map.get(target_data, "previous_url_slugs", []),
        Map.get(legacy_data, "previous_url_slugs", [])
      ]
      |> List.flatten()
      |> then(fn slugs ->
        if blank_string?(target_url_slug) or blank_string?(legacy_url_slug) or
             target_url_slug == legacy_url_slug do
          slugs
        else
          [legacy_url_slug | slugs]
        end
      end)
      |> Enum.reject(&blank_string?/1)
      |> Enum.uniq()

    Map.merge(legacy_data, target_data)
    |> Map.put("previous_url_slugs", merged_previous_slugs)
  end

  defp weak_title?(title), do: blank_string?(title) or title == Constants.default_title()

  defp strong_title?(title),
    do: is_binary(title) and title != "" and title != Constants.default_title()

  defp blank_string?(value), do: value in [nil, ""]

  @doc """
  Ensures only one version is published per post.

  If multiple versions have status "published", keeps the highest version
  number as published and archives the rest.
  """
  def fix_multiple_published_versions(%PublishingPost{} = post) do
    ctx = build_post_context(post)
    fix_multiple_published_versions(post, ctx)
  end

  # M4 heal: a save can no longer mark a version "published" without
  # publish_version atomically activating it, but a legacy or interrupted publish
  # can leave a version with status "published" while the post has NO active
  # version — the admin list shows it published while the public page 404s.
  # Demote those orphans back to draft so the two views agree.
  defp demote_orphaned_published_versions(%{active_version_uuid: nil} = post, ctx) do
    orphans = Enum.filter(ctx.versions, &Constants.published?(&1.status))

    for v <- orphans do
      Logger.info(
        "[Publishing] Demoting orphaned published v#{v.version_number} of post " <>
          "#{post.uuid} to draft (post has no active version)"
      )

      DBStorage.update_version(v, %{status: "draft"})
      DBStorage.update_content_status(v.uuid, "draft")
      mark_listing_dirty()
    end
  end

  defp demote_orphaned_published_versions(_post, _ctx), do: :ok

  defp fix_multiple_published_versions(post, ctx) do
    published = Enum.filter(ctx.versions, &Constants.published?(&1.status))

    if length(published) > 1 do
      # Keep the highest version number, archive the rest
      sorted = Enum.sort_by(published, & &1.version_number, :desc)
      [keep | demote] = sorted

      Logger.info(
        "[Publishing] Post #{post.uuid} has #{length(published)} published versions, " <>
          "keeping v#{keep.version_number}, archiving #{length(demote)} others"
      )

      for v <- demote do
        DBStorage.update_version(v, %{status: "archived"})
        DBStorage.update_content_status(v.uuid, "archived")
        mark_listing_dirty()
      end
    end
  end

  # Reconciles active_version_uuid consistency for a post.
  #
  # If active_version_uuid points to a non-existent or non-published version,
  # clears it. Also ensures non-published versions don't have "published" content.
  @spec reconcile_post_status(PublishingPost.t()) :: [any()]
  def reconcile_post_status(%PublishingPost{} = post) do
    # Re-read to get current state after individual fixes
    post = DBStorage.get_post_by_uuid(post.uuid) || post
    versions = DBStorage.list_versions(post.uuid)

    reconcile_active_version(post, versions)
    reconcile_trashed_post(post, versions)
    demote_non_published_version_content(versions)
  end

  defp reconcile_active_version(%{active_version_uuid: nil}, _versions), do: :ok

  defp reconcile_active_version(post, versions) do
    active_version = Enum.find(versions, &(&1.uuid == post.active_version_uuid))

    if is_nil(active_version) or not Constants.published?(active_version.status) do
      Logger.info(
        "[Publishing] Reconcile: post #{post.uuid} active_version_uuid points to " <>
          "#{if active_version, do: "#{active_version.status} version", else: "non-existent version"}, clearing"
      )

      DBStorage.update_post(post, %{active_version_uuid: nil})
      mark_listing_dirty()
    end
  end

  defp reconcile_trashed_post(%{trashed_at: nil}, _versions), do: :ok

  defp reconcile_trashed_post(post, versions) do
    published_versions = Enum.filter(versions, &Constants.published?(&1.status))

    if published_versions != [] do
      Logger.info(
        "[Publishing] Reconcile: post #{post.uuid} is trashed but has #{length(published_versions)} published versions, archiving"
      )

      for v <- published_versions do
        DBStorage.update_version(v, %{status: "archived"})
        demote_published_content(v.uuid)
        mark_listing_dirty()
      end
    end
  end

  defp demote_non_published_version_content(versions) do
    non_published_versions = Enum.reject(versions, &Constants.published?(&1.status))

    for v <- non_published_versions do
      demote_published_content(v.uuid)
    end
  end

  # Demotes any "published" content rows to "draft" within a version.
  # Leaves "draft" and "archived" content untouched.
  defp demote_published_content(version_uuid) do
    contents = DBStorage.list_contents(version_uuid)
    published = Enum.filter(contents, &Constants.published?(&1.status))

    if published != [] do
      Logger.info(
        "[Publishing] Demoting #{length(published)} published content row(s) to \"draft\" in version #{version_uuid}"
      )

      for content <- published do
        DBStorage.update_content(content, %{status: "draft"})
        mark_listing_dirty()
      end
    end
  end

  # Returns the default item names for a given type.
  defp default_item_names(type) do
    Map.get(@type_item_names, type, {@default_item_singular, @default_item_plural})
  end
end
