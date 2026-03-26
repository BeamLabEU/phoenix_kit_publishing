defmodule PhoenixKit.Modules.Publishing.StaleFixer do
  @moduledoc """
  Fixes stale or invalid values on publishing records.

  Validates and corrects fields like mode, type, language, and
  timestamps across groups, posts, versions, and content. Also reconciles
  active_version_uuid consistency between posts and versions.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost

  alias PhoenixKit.Modules.Publishing.Constants

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
  def fix_stale_post(%PublishingPost{} = post) do
    # Pre-fetch all versions and contents once to avoid redundant queries
    ctx = build_post_context(post)
    do_fix_stale_post(post, ctx)
  end

  defp build_post_context(post) do
    versions = DBStorage.list_versions(post.uuid)
    version_uuids = Enum.map(versions, & &1.uuid)
    contents_by_version = DBStorage.batch_load_contents(version_uuids)
    %{versions: versions, contents_by_version: contents_by_version}
  end

  defp do_fix_stale_post(post, ctx) do
    # Hard-delete empty posts (no content in any version) — they're abandoned
    # drafts with no recoverable content, so trashing them just creates a
    # restore → auto-trash loop. Skip recently created posts to avoid killing
    # posts before the editor has had a chance to autosave.
    if empty_post?(ctx) and past_grace_period?(post) do
      Logger.info("[Publishing] Deleting empty post #{post.uuid} (no content in any version)")
      DBStorage.delete_post(post)
      post
    else
      post = apply_stale_fix(post, build_post_fixes(post, ctx), &DBStorage.update_post/2)

      # Fix version/content-level issues
      fix_multiple_published_versions(post, ctx)

      for version <- ctx.versions do
        fix_stale_version(version)
        contents = Map.get(ctx.contents_by_version, version.uuid, [])
        Enum.each(contents, &fix_stale_content/1)
      end

      DBStorage.get_post_by_uuid(post.uuid, [:group]) || post
    end
  end

  defp empty_post?(ctx) do
    if ctx.versions == [] do
      true
    else
      Enum.all?(ctx.versions, fn version ->
        contents = Map.get(ctx.contents_by_version, version.uuid, [])

        contents == [] or
          Enum.all?(contents, fn c ->
            (c.content || "") == "" and (c.title || "") in ["", Constants.default_title()]
          end)
      end)
    end
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
    |> maybe_fix_active_version(post, ctx)
  end

  defp maybe_fix_post_mode(attrs, post) do
    # First ensure the mode is a valid value
    fixed_mode = if post.mode in @valid_group_modes, do: post.mode, else: @default_group_mode

    # Then sync with the group's mode if they differ (e.g., group switched from
    # timestamp to slug but existing posts were never updated)
    group = if post.group, do: post.group, else: DBStorage.get_group(post.group_uuid)

    fixed_mode =
      if group && group.mode in @valid_group_modes do
        group.mode
      else
        fixed_mode
      end

    if fixed_mode != post.mode, do: Map.put(attrs, :mode, fixed_mode), else: attrs
  end

  defp maybe_fix_post_slug(attrs, post, ctx) do
    effective_mode = attrs[:mode] || post.mode

    if effective_mode == "slug" and (is_nil(post.slug) or post.slug == "") do
      # Post switched to slug mode but has no slug — generate from title or date
      base_slug = generate_slug_for_post(post, ctx)

      if base_slug != "" do
        # Ensure uniqueness by checking if slug exists in the group
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
    else
      attrs
    end
  end

  # Ensures a slug is unique within a group by appending a UUID suffix if needed
  defp ensure_unique_slug(group_uuid, slug, post_uuid) do
    conflict =
      from(p in PublishingPost,
        where: p.group_uuid == ^group_uuid and p.slug == ^slug and p.uuid != ^post_uuid,
        select: p.uuid,
        limit: 1
      )
      |> PhoenixKit.RepoHelper.repo().one()

    if conflict do
      suffix = String.slice(post_uuid || "", 0, 8)
      "#{slug}-#{suffix}"
    else
      slug
    end
  end

  defp generate_slug_for_post(post, ctx) do
    # Try to get title from the latest version's primary content
    primary_lang = LanguageHelpers.get_primary_language()

    title =
      case ctx.versions do
        [] ->
          nil

        versions ->
          latest = List.last(versions)
          contents = Map.get(ctx.contents_by_version, latest.uuid, [])

          case Enum.find(contents, &(&1.language == primary_lang)) do
            nil -> nil
            content -> content.title
          end
      end

    base =
      cond do
        is_binary(title) and title not in ["", Constants.default_title()] ->
          title

        post.post_date ->
          Date.to_iso8601(post.post_date)

        true ->
          "post-#{String.slice(post.uuid || "", 0, 8)}"
      end

    base
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp maybe_fix_post_timestamp(attrs, post) do
    if (attrs[:mode] || post.mode) == "timestamp" do
      now = DateTime.utc_now()

      attrs
      |> then(fn a ->
        if is_nil(post.post_date), do: Map.put(a, :post_date, DateTime.to_date(now)), else: a
      end)
      |> then(fn a ->
        if is_nil(post.post_time),
          do: Map.put(a, :post_time, Time.new!(now.hour, now.minute, 0)),
          else: a
      end)
    else
      attrs
    end
  end

  # If active_version_uuid points to a non-existent or non-published version, clear it
  defp maybe_fix_active_version(attrs, post, ctx) do
    case post.active_version_uuid do
      nil ->
        attrs

      active_uuid ->
        version = Enum.find(ctx.versions, &(&1.uuid == active_uuid))

        if is_nil(version) or version.status != "published" do
          Logger.info(
            "[Publishing] Clearing stale active_version_uuid for post #{post.uuid}: " <>
              "version #{inspect(active_uuid)} is #{if version, do: version.status, else: "missing"}"
          )

          Map.put(attrs, :active_version_uuid, nil)
        else
          attrs
        end
    end
  end

  defp apply_stale_fix(record, attrs, _update_fn) when attrs == %{}, do: record

  defp apply_stale_fix(record, attrs, update_fn) do
    identifier = Map.get(record, :uuid) || Map.get(record, :slug) || "unknown"

    Logger.info(
      "[Publishing] Fixing stale values for #{record.__struct__} #{identifier}: #{inspect(attrs)}"
    )

    case update_fn.(record, attrs) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        Logger.warning(
          "[Publishing] Failed to fix stale values for #{identifier}: #{inspect(reason)}"
        )

        record
    end
  end

  defp maybe_update(data, key, old_val, new_val) do
    if old_val != new_val, do: Map.put(data, key, new_val), else: data
  end

  @doc """
  Fixes stale values across all groups, posts, versions, and content.
  Also reconciles active_version_uuid consistency and ensures single published version.
  Callable via internal API or IEx.
  """
  @spec fix_all_stale_values() :: :ok
  def fix_all_stale_values do
    # Scan ALL groups (including trashed) — pass nil to skip status filter
    groups = DBStorage.list_groups(nil)
    Enum.each(groups, &fix_stale_group/1)

    for group <- groups do
      posts = DBStorage.list_posts(group.slug)
      Enum.each(posts, &fix_stale_post/1)
    end

    :ok
  end

  def fix_stale_version(version) do
    if version.status not in @valid_version_statuses do
      Logger.info(
        "[Publishing] Fixing stale version #{version.uuid}: status #{inspect(version.status)} → \"draft\""
      )

      DBStorage.update_version(version, %{status: "draft"})
    end
  end

  def fix_stale_content(content) do
    attrs =
      %{}
      |> maybe_fix_content_status(content)
      |> maybe_fix_content_language(content)

    if attrs != %{} do
      Logger.info(
        "[Publishing] Fixing stale content #{content.uuid} (#{content.language}): #{inspect(attrs)}"
      )

      DBStorage.update_content(content, attrs)
    end
  end

  defp maybe_fix_content_status(attrs, content) do
    if content.status in @valid_version_statuses,
      do: attrs,
      else: Map.put(attrs, :status, "draft")
  end

  defp maybe_fix_content_language(attrs, content) do
    if is_binary(content.language) and content.language != "" do
      attrs
    else
      Map.put(attrs, :language, LanguageHelpers.get_primary_language())
    end
  end

  @doc """
  Ensures only one version is published per post.

  If multiple versions have status "published", keeps the highest version
  number as published and archives the rest.
  """
  def fix_multiple_published_versions(%PublishingPost{} = post) do
    ctx = build_post_context(post)
    fix_multiple_published_versions(post, ctx)
  end

  defp fix_multiple_published_versions(post, ctx) do
    published = Enum.filter(ctx.versions, &(&1.status == "published"))

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
      end
    end
  end

  # Reconciles active_version_uuid consistency for a post.
  #
  # If active_version_uuid points to a non-existent or non-published version,
  # clears it. Also ensures non-published versions don't have "published" content.
  def reconcile_post_status(%PublishingPost{} = post) do
    # Re-read to get current state after individual fixes
    post = DBStorage.get_post_by_uuid(post.uuid) || post
    versions = DBStorage.list_versions(post.uuid)

    # If active_version_uuid points to a missing or non-published version, clear it
    if post.active_version_uuid do
      active_version = Enum.find(versions, &(&1.uuid == post.active_version_uuid))

      if is_nil(active_version) or active_version.status != "published" do
        Logger.info(
          "[Publishing] Reconcile: post #{post.uuid} active_version_uuid points to " <>
            "#{if active_version, do: "#{active_version.status} version", else: "non-existent version"}, clearing"
        )

        DBStorage.update_post(post, %{active_version_uuid: nil})
      end
    end

    # If post is trashed, archive any published versions
    if post.trashed_at do
      published_versions = Enum.filter(versions, &(&1.status == "published"))

      if published_versions != [] do
        Logger.info(
          "[Publishing] Reconcile: post #{post.uuid} is trashed but has #{length(published_versions)} published versions, archiving"
        )

        for v <- published_versions do
          DBStorage.update_version(v, %{status: "archived"})
          demote_published_content(v.uuid)
        end
      end
    end

    # For ALL non-published versions, no content should be "published"
    non_published_versions = Enum.reject(versions, &(&1.status == "published"))

    for v <- non_published_versions do
      demote_published_content(v.uuid)
    end
  end

  # Demotes any "published" content rows to "draft" within a version.
  # Leaves "draft" and "archived" content untouched.
  defp demote_published_content(version_uuid) do
    contents = DBStorage.list_contents(version_uuid)
    published = Enum.filter(contents, &(&1.status == "published"))

    if published != [] do
      Logger.info(
        "[Publishing] Demoting #{length(published)} published content row(s) to \"draft\" in version #{version_uuid}"
      )

      for content <- published do
        DBStorage.update_content(content, %{status: "draft"})
      end
    end
  end

  # Returns the default item names for a given type.
  defp default_item_names(type) do
    Map.get(@type_item_names, type, {@default_item_singular, @default_item_plural})
  end
end
