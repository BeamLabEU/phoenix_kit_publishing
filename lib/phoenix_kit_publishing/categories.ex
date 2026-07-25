defmodule PhoenixKit.Modules.Publishing.Categories do
  @moduledoc """
  Hierarchical, per-group categories (WordPress-parity taxonomy) and the
  post↔category assignments. Backed by core migration **V159**.

  Context-layer rules the DB doesn't enforce:

  - **Same-group parents** — a category's parent must belong to the same
    group.
  - **No cycles** — a category cannot become its own descendant; checked
    inside the update transaction so concurrent re-parents can't sneak a
    loop through.
  - **Assignment scope** — `replace_post_categories/3` only accepts
    categories of the post's own group.

  Reads used by the public side (`categories_for_posts/1`, `by_slug/2`)
  are plain queries — the listing cache carries the per-post category
  uuids so hot listing paths never join here.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PublishingCategory
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingPostCategory
  alias PhoenixKit.Modules.Publishing.SlugHelpers

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ===========================================================================
  # Category CRUD
  # ===========================================================================

  @doc """
  All categories of a group, tree-ordered: roots by position/name, each
  followed by its (recursively ordered) children. Returns
  `%PublishingCategory{}` structs with a virtual-ish `:depth` in the
  returned tuples: `[{category, depth}]`.
  """
  def list_tree(group_slug) do
    categories = list_categories(group_slug)
    by_parent = Enum.group_by(categories, & &1.parent_uuid)

    # Roots include orphans whose parent row vanished mid-read (deleted
    # concurrently): any parent_uuid not present in this result set.
    known = MapSet.new(categories, & &1.uuid)

    roots =
      Enum.filter(categories, fn c ->
        is_nil(c.parent_uuid) or not MapSet.member?(known, c.parent_uuid)
      end)

    walk_tree(roots, by_parent, 0, MapSet.new())
  end

  defp walk_tree(nodes, by_parent, depth, seen) do
    Enum.flat_map(nodes, fn node ->
      if MapSet.member?(seen, node.uuid) do
        []
      else
        children = Map.get(by_parent, node.uuid, [])
        [{node, depth} | walk_tree(children, by_parent, depth + 1, MapSet.put(seen, node.uuid))]
      end
    end)
  end

  @doc "Flat category list for a group, ordered by position then name."
  def list_categories(group_slug) do
    from(c in PublishingCategory,
      join: g in PublishingGroup,
      on: g.uuid == c.group_uuid,
      where: g.slug == ^group_slug,
      order_by: [asc: c.position, asc: c.name]
    )
    |> repo().all()
  end

  @doc "A group's category by slug."
  def by_slug(group_slug, category_slug) do
    from(c in PublishingCategory,
      join: g in PublishingGroup,
      on: g.uuid == c.group_uuid,
      where: g.slug == ^group_slug and c.slug == ^category_slug
    )
    |> repo().one()
    |> case do
      nil -> {:error, :not_found}
      category -> {:ok, category}
    end
  end

  @doc "A category by uuid."
  def get_category(uuid) when is_binary(uuid) do
    case repo().get(PublishingCategory, uuid) do
      nil -> {:error, :not_found}
      category -> {:ok, category}
    end
  end

  @doc """
  Creates a category in a group. `attrs` may carry `"name"`, `"slug"`
  (auto-derived from the name when blank), `"parent_uuid"`, `"description"`,
  `"position"`, `"name_i18n"`.
  """
  def create_category(group_slug, attrs, opts \\ []) do
    with {:ok, group_uuid} <- group_uuid(group_slug),
         attrs = ensure_slug(attrs),
         :ok <- validate_parent(attrs["parent_uuid"] || attrs[:parent_uuid], group_uuid, nil) do
      %PublishingCategory{}
      |> PublishingCategory.create_changeset(
        attrs
        |> stringify_keys()
        |> Map.put("group_uuid", group_uuid)
      )
      |> repo().insert()
      |> case do
        {:ok, category} ->
          ActivityLog.log_manual(
            "publishing.category.created",
            ActivityLog.actor_uuid(opts),
            "publishing_category",
            category.uuid,
            %{"group" => group_slug, "slug" => category.slug}
          )

          {:ok, category}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Updates a category. Re-parenting is cycle-checked inside a transaction —
  the new parent must be same-group and not the category itself or any of
  its descendants.
  """
  def update_category(uuid, attrs, opts \\ []) do
    repo().transaction(fn ->
      with {:ok, category} <- get_category(uuid),
           :ok <-
             validate_parent(
               attrs["parent_uuid"] || attrs[:parent_uuid],
               category.group_uuid,
               category
             ) do
        category
        |> PublishingCategory.changeset(stringify_keys(attrs))
        |> repo().update()
        |> case do
          {:ok, updated} ->
            ActivityLog.log_manual(
              "publishing.category.updated",
              ActivityLog.actor_uuid(opts),
              "publishing_category",
              updated.uuid,
              %{"slug" => updated.slug}
            )

            invalidate_group_cache(updated.group_uuid)
            updated

          {:error, changeset} ->
            repo().rollback(changeset)
        end
      else
        {:error, reason} -> repo().rollback(reason)
        :error -> repo().rollback(:invalid_parent)
      end
    end)
  end

  @doc """
  Deletes a category. The DB lifts its children to the root
  (`ON DELETE SET NULL`) and cascades the post assignments.
  """
  def delete_category(uuid, opts \\ []) do
    with {:ok, category} <- get_category(uuid) do
      case repo().delete(category) do
        {:ok, deleted} ->
          ActivityLog.log_manual(
            "publishing.category.deleted",
            ActivityLog.actor_uuid(opts),
            "publishing_category",
            deleted.uuid,
            %{"slug" => deleted.slug}
          )

          invalidate_group_cache(deleted.group_uuid)
          {:ok, deleted}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # ===========================================================================
  # Post assignments
  # ===========================================================================

  @doc """
  Replaces a post's category set with `category_uuids` (max 100 — a
  client-misbehavior guard, same convention as the reorder fns). Only
  categories belonging to the post's group are accepted; unknown/foreign
  uuids are silently dropped rather than erroring, so a stale editor
  checkbox can't fail the whole save.
  """
  def replace_post_categories(post_uuid, category_uuids, opts \\ [])
      when is_list(category_uuids) and length(category_uuids) <= 100 do
    with {:ok, post} <- get_post(post_uuid) do
      # Non-UUID strings must be dropped BEFORE the query — Ecto raises a
      # CastError on an uncastable value inside `in ^list`.
      castable =
        Enum.filter(category_uuids, fn value ->
          is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))
        end)

      valid_uuids =
        from(c in PublishingCategory,
          where: c.uuid in ^castable,
          where: c.group_uuid == ^post.group_uuid,
          select: c.uuid
        )
        |> repo().all()

      {:ok, _} =
        repo().transaction(fn ->
          from(pc in PublishingPostCategory, where: pc.post_uuid == ^post_uuid)
          |> repo().delete_all()

          now = DateTime.utc_now() |> DateTime.truncate(:second)

          rows =
            Enum.map(valid_uuids, fn category_uuid ->
              %{post_uuid: post_uuid, category_uuid: category_uuid, inserted_at: now}
            end)

          repo().insert_all(PublishingPostCategory, rows, on_conflict: :nothing)
        end)

      ActivityLog.log_manual(
        "publishing.post.categorized",
        ActivityLog.actor_uuid(opts),
        "publishing_post",
        post_uuid,
        %{"category_count" => length(valid_uuids)}
      )

      invalidate_group_cache(post.group_uuid)
      {:ok, valid_uuids}
    end
  end

  @doc "Full category structs assigned to a post, position-ordered."
  def categories_of_post(post_uuid) do
    from(pc in PublishingPostCategory,
      join: c in PublishingCategory,
      on: c.uuid == pc.category_uuid,
      where: pc.post_uuid == ^post_uuid,
      order_by: [asc: c.position, asc: c.name],
      select: c
    )
    |> repo().all()
  end

  @doc "Category uuids assigned to a post."
  def category_uuids_for_post(post_uuid) do
    from(pc in PublishingPostCategory,
      where: pc.post_uuid == ^post_uuid,
      select: pc.category_uuid
    )
    |> repo().all()
  end

  @doc """
  Category uuids per post, for a whole list of post uuids in one query —
  `%{post_uuid => [category_uuid]}`. The listing-cache regen uses this so
  cached maps carry categories without per-post queries.
  """
  def categories_for_posts(post_uuids) when is_list(post_uuids) do
    from(pc in PublishingPostCategory,
      where: pc.post_uuid in ^post_uuids,
      select: {pc.post_uuid, pc.category_uuid}
    )
    |> repo().all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  The uuids of a category and all its descendants within a group — the
  WordPress archive rule (a parent category's archive includes posts filed
  under its children). One query for the group's categories, then an
  in-memory walk; cycle-safe via the seen set.
  """
  def subtree_uuids(group_slug, root_uuid) do
    by_parent =
      group_slug
      |> list_categories()
      |> Enum.group_by(& &1.parent_uuid, & &1.uuid)

    collect_subtree([root_uuid], by_parent, MapSet.new([root_uuid]))
  end

  defp collect_subtree([], _by_parent, acc), do: acc

  defp collect_subtree([node | rest], by_parent, acc) do
    children =
      by_parent
      |> Map.get(node, [])
      |> Enum.reject(&MapSet.member?(acc, &1))

    collect_subtree(children ++ rest, by_parent, Enum.reduce(children, acc, &MapSet.put(&2, &1)))
  end

  @doc """
  Published-post counts per category of a group (for the admin tree and
  archive headers): `%{category_uuid => count}`. Counts posts with an
  active published version, not trashed.
  """
  def published_post_counts(group_slug) do
    from(pc in PublishingPostCategory,
      join: c in PublishingCategory,
      on: c.uuid == pc.category_uuid,
      join: g in PublishingGroup,
      on: g.uuid == c.group_uuid,
      join: p in PublishingPost,
      on: p.uuid == pc.post_uuid,
      where: g.slug == ^group_slug,
      where: is_nil(p.trashed_at) and not is_nil(p.active_version_uuid),
      group_by: pc.category_uuid,
      select: {pc.category_uuid, count(p.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp get_post(post_uuid) do
    case repo().get(PublishingPost, post_uuid) do
      nil -> {:error, :not_found}
      post -> {:ok, post}
    end
  end

  defp group_uuid(group_slug) do
    from(g in PublishingGroup, where: g.slug == ^group_slug, select: g.uuid)
    |> repo().one()
    |> case do
      nil -> {:error, :group_not_found}
      uuid -> {:ok, uuid}
    end
  end

  defp ensure_slug(attrs) do
    attrs = stringify_keys(attrs)

    case attrs["slug"] do
      s when is_binary(s) and s != "" ->
        attrs

      _ ->
        Map.put(attrs, "slug", SlugHelpers.slugify(attrs["name"] || ""))
    end
  end

  # nil parent (root) is always valid; otherwise the parent must exist, be
  # same-group, and — on update — not be the category or its descendant.
  defp validate_parent(nil, _group_uuid, _category), do: :ok
  defp validate_parent("", _group_uuid, _category), do: :ok

  defp validate_parent(parent_uuid, group_uuid, category) when is_binary(parent_uuid) do
    case repo().get(PublishingCategory, parent_uuid) do
      nil ->
        {:error, :parent_not_found}

      %{group_uuid: ^group_uuid} = parent ->
        if category && (parent.uuid == category.uuid or descendant?(parent.uuid, category.uuid)) do
          {:error, :category_cycle}
        else
          :ok
        end

      _other_group ->
        {:error, :parent_wrong_group}
    end
  end

  defp validate_parent(_bad, _group_uuid, _category), do: {:error, :parent_not_found}

  # Walks up from `node_uuid` looking for `ancestor_uuid`. Depth-capped so a
  # pre-existing corrupt loop can't spin this forever.
  defp descendant?(node_uuid, ancestor_uuid, hops \\ 0)
  defp descendant?(_node, _ancestor, hops) when hops > 100, do: true

  defp descendant?(node_uuid, ancestor_uuid, hops) do
    case repo().one(
           from(c in PublishingCategory, where: c.uuid == ^node_uuid, select: c.parent_uuid)
         ) do
      nil -> false
      ^ancestor_uuid -> true
      parent -> descendant?(parent, ancestor_uuid, hops + 1)
    end
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp invalidate_group_cache(group_uuid) do
    case repo().one(from(g in PublishingGroup, where: g.uuid == ^group_uuid, select: g.slug)) do
      nil -> :ok
      slug -> ListingCache.invalidate(slug)
    end
  rescue
    _ -> :ok
  end
end
