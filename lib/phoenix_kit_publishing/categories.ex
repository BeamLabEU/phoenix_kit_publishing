defmodule PhoenixKit.Modules.Publishing.Categories do
  @moduledoc """
  Hierarchical, per-group categories (WordPress-parity taxonomy) and the
  assignments of posts to them. The category rows come from core migration
  **V159**.

  ## Assignments are version-level

  A post's filing lives in `version.data["category_uuids"]`, next to the
  version's tags, excerpt and SEO fields — not in a post-level join table.
  A post's subject genuinely changes as it is revised (a release note that
  grows into a guide), and a reader on `?v=2` should see how v2 was filed,
  not how the live version is filed today. A new version inherits the whole
  `data` map from the one it was created from, so the filing carries forward
  by default and only differs where somebody changed it.

  This is why there is no foreign key behind an assignment: `delete_category/2`
  has to unfile the category by hand (`unfile_deleted_category/1`).

  The V159 join table predates this and is drained on first use by
  `backfill_version_categories/1`; nothing writes it any more.

  Post-level helpers here (`replace_post_categories/3`,
  `categories_of_post/1`, `category_uuids_for_post/1`) mean "the live
  version, or the newest draft if it has never been published". Callers
  that hold a specific version should read `category_uuids` off the post map
  and resolve it with `categories_by_uuids/2`.

  ## Context-layer rules the DB doesn't enforce

  - **Same-group parents** — a category's parent must belong to the same
    group.
  - **No cycles** — a category cannot become its own descendant; checked
    inside the update transaction so concurrent re-parents can't sneak a
    loop through.
  - **Assignment scope** — only categories of the post's own group are
    accepted; foreign uuids are dropped rather than raising.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PublishingCategory
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingPostCategory
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Publishing.SlugHelpers

  require Logger

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

    walk_tree(roots, by_parent, 0, %{})
  end

  # `seen` is a plain map used as a set, not a MapSet: this is seeded EMPTY
  # and grows through the recursion, and dialyzer treats an empty MapSet and
  # a populated one as different parameterisations of the same opaque type —
  # a `call_without_opaque` on the very next `member?`. The other sets in
  # this module (`known` above, `collect_subtree/3`) are seeded with their
  # elements, so they don't hit it and stay MapSets.
  #
  # The set is per-branch, not global: it stops a corrupt parent chain
  # looping forever, while a node legitimately reachable under two roots
  # still renders under each.
  defp walk_tree(nodes, by_parent, depth, seen) do
    Enum.flat_map(nodes, fn node ->
      if Map.has_key?(seen, node.uuid) do
        []
      else
        children = Map.get(by_parent, node.uuid, [])

        [
          {node, depth}
          | walk_tree(children, by_parent, depth + 1, Map.put(seen, node.uuid, true))
        ]
      end
    end)
  end

  @doc """
  Flat category list for a group, ordered by position then name. Degrades to
  `[]` when the backing table is missing (host core < V159) — every public
  read path must survive the release-gated window.
  """
  def list_categories(group_slug) do
    from(c in PublishingCategory,
      join: g in PublishingGroup,
      on: g.uuid == c.group_uuid,
      where: g.slug == ^group_slug,
      order_by: [asc: c.position, asc: c.name]
    )
    |> repo().all()
  rescue
    _ -> []
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
  rescue
    _ -> {:error, :not_found}
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
    result =
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

    log_category_failure(result, "publishing.category.created", opts, nil, %{
      "group" => group_slug
    })
  end

  @doc """
  Updates a category. Re-parenting is cycle-checked inside a transaction —
  the new parent must be same-group and not the category itself or any of
  its descendants.
  """
  def update_category(uuid, attrs, opts \\ []) do
    repo().transaction(fn ->
      with {:ok, category} <- get_category(uuid),
           :ok <- lock_group_categories(category.group_uuid, attrs),
           :ok <-
             validate_parent(
               attrs["parent_uuid"] || attrs[:parent_uuid],
               category.group_uuid,
               category
             ) do
        write_category_update(category, attrs, opts)
      else
        # Every step returns `:ok` or a tagged `{:error, reason}` — there is
        # no bare `:error` to catch here.
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> log_category_failure("publishing.category.updated", opts, uuid, %{})
  end

  # Runs inside `update_category/3`'s transaction — `rollback/1` throws, so
  # returning the struct is the only success path out of here.
  defp write_category_update(category, attrs, opts) do
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
  end

  # A cycle check answers a question about the whole tree, so two re-parents
  # in the same group have to take turns asking it. Both transactions used to
  # read the tree as it was before either had written, so moving A under B and
  # B under A at the same moment each looked fine on its own and left
  # A → B → A. The tree is built from its roots, so both branches — and every
  # category hanging off them — then vanished from the admin page entirely.
  #
  # Locking the group's rows before the check serialises only re-parenting;
  # renames and other edits carry no parent_uuid and skip it.
  defp lock_group_categories(group_uuid, attrs) do
    if Map.has_key?(attrs, "parent_uuid") or Map.has_key?(attrs, :parent_uuid) do
      from(c in PublishingCategory, where: c.group_uuid == ^group_uuid, lock: "FOR UPDATE")
      |> repo().all()
    end

    :ok
  end

  @doc """
  Deletes a category. The DB lifts its children to the root
  (`ON DELETE SET NULL`) and cascades the post assignments.
  """
  def delete_category(uuid, opts \\ []) do
    result =
      with {:ok, category} <- get_category(uuid) do
        case repo().delete(category) do
          {:ok, deleted} ->
            unfile_deleted_category(deleted)

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

    log_category_failure(result, "publishing.category.deleted", opts, uuid, %{})
  end

  # Assignments live in `version.data`, which no foreign key can reach, so
  # deleting a category has to remove its uuid from every version that named
  # it. Skipping this leaves versions filed under something that no longer
  # exists — harmless to render (the uuid just resolves to nothing) but it
  # comes back to life the moment a new category is created with the same
  # uuid, and it quietly inflates nothing while looking like data.
  #
  # Scoped to the deleted category's own group: `data` is JSONB with no index
  # here, and a group-wide update is small, where a table-wide one would not
  # stay small.
  defp unfile_deleted_category(%{uuid: category_uuid, group_uuid: group_uuid}) do
    from(v in PublishingVersion,
      join: p in PublishingPost,
      on: p.uuid == v.post_uuid,
      where: p.group_uuid == ^group_uuid,
      where: fragment("? -> 'category_uuids' @> ?", v.data, ^[category_uuid]),
      update: [
        set: [
          data:
            fragment(
              "jsonb_set(?, '{category_uuids}', (? -> 'category_uuids') - ?)",
              v.data,
              v.data,
              ^category_uuid
            )
        ]
      ]
    )
    |> repo().update_all([])

    :ok
  rescue
    error ->
      Logger.warning("[Publishing] Could not unfile deleted category: #{inspect(error)}")
      :ok
  end

  @doc """
  Persists a drag-reorder. `ordered_uuids` is the client's DOM order of
  the whole flattened tree; rows are grouped by their EXISTING parent and
  renumbered within each sibling group — a sortable drop can only reorder
  siblings, never reparent (reparenting is `update_category/3`, which
  cycle-checks). Unknown/foreign uuids are ignored rather than erroring.
  Capped at 500 rows (client-misbehavior guard, same convention as the
  assignment cap). Returns `{:ok, changed_count}`.
  """
  def reorder_categories(group_slug, ordered_uuids, opts \\ [])

  def reorder_categories(group_slug, ordered_uuids, opts)
      when is_list(ordered_uuids) and length(ordered_uuids) <= 500 do
    # Read inside the transaction: a concurrent create/move between read and
    # write would otherwise renumber from a stale parent map.
    repo().transaction(fn ->
      categories = list_categories(group_slug)
      by_uuid = Map.new(categories, &{&1.uuid, &1})
      by_parent = Enum.group_by(categories, & &1.parent_uuid)

      sibling_orders =
        ordered_uuids
        |> Enum.uniq()
        |> Enum.filter(&(is_binary(&1) and is_map_key(by_uuid, &1)))
        |> Enum.group_by(&by_uuid[&1].parent_uuid)

      changed =
        sibling_orders
        |> Enum.map(fn {parent, sent} ->
          # Renumber the FULL sibling group, not just the sent subset — a
          # stale client (concurrent create) must not leave position
          # collisions: unsent siblings keep their relative order, after
          # the sent ones.
          sent_set = MapSet.new(sent)

          unsent =
            by_parent
            |> Map.get(parent, [])
            |> Enum.map(& &1.uuid)
            |> Enum.reject(&MapSet.member?(sent_set, &1))

          renumber_siblings(sent ++ unsent, by_uuid)
        end)
        |> Enum.sum()

      if changed > 0 do
        group_uuid = hd(categories).group_uuid

        ActivityLog.log_manual(
          "publishing.category.reordered",
          ActivityLog.actor_uuid(opts),
          "publishing_group",
          group_uuid,
          %{"group" => group_slug, "changed" => changed}
        )

        invalidate_group_cache(group_uuid)
      end

      changed
    end)
    |> log_category_failure("publishing.category.reordered", opts, nil, %{
      "group" => group_slug
    })
  end

  def reorder_categories(group_slug, _ordered_uuids, opts) do
    log_category_failure(
      {:error, :invalid_order},
      "publishing.category.reordered",
      opts,
      nil,
      %{"group" => group_slug}
    )
  end

  @doc """
  Re-parents a category, appending it at the END of the new sibling group
  (the catalogue `move_folder` convention) — keeping its old position would
  drop it mid-group unpredictably. Cycle/scope rules are
  `update_category/3`'s.
  """
  def move_category(uuid, new_parent_uuid, opts \\ []) do
    with {:ok, category} <- get_category(uuid) do
      parent = if new_parent_uuid in [nil, ""], do: nil, else: new_parent_uuid

      next_position =
        from(c in PublishingCategory,
          where: c.group_uuid == ^category.group_uuid,
          where: ^parent_condition(parent),
          select: max(c.position)
        )
        |> repo().one()
        |> case do
          nil -> 0
          max -> max + 1
        end

      update_category(
        uuid,
        %{"parent_uuid" => new_parent_uuid, "position" => next_position},
        opts
      )
    end
  end

  defp parent_condition(nil), do: dynamic([c], is_nil(c.parent_uuid))
  defp parent_condition(parent), do: dynamic([c], c.parent_uuid == ^parent)

  defp renumber_siblings(uuids, by_uuid) do
    uuids
    |> Enum.with_index()
    |> Enum.count(fn {uuid, index} -> reposition(by_uuid[uuid], index) end)
  end

  # True when the row actually moved, so the caller can count real changes —
  # a drop that lands everything back where it was must not report a reorder.
  defp reposition(%{position: index}, index), do: false

  defp reposition(category, index) do
    category
    |> PublishingCategory.changeset(%{"position" => index})
    |> repo().update()
    |> case do
      {:ok, _} -> true
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  # ===========================================================================
  # Post assignments
  # ===========================================================================

  @doc """
  Moves the legacy post-level assignments onto the versions, once per group.

  Categories used to be a post-level join table, so every existing post's
  filing lives there and nowhere else. Versions are the source of truth now,
  and a version whose `data` has no `category_uuids` key is indistinguishable
  from one deliberately filed under nothing — so without this, upgrading
  silently unfiles the entire archive.

  Copied onto EVERY version of the post, not just the active one, because
  that is what the old model meant: the assignment applied to whatever
  version you were looking at. Versions that already carry the key are left
  alone, so a real edit can never be overwritten.

  The legacy rows are then dropped, which is what makes this self-limiting:
  no rows means nothing to move, so the steady state is a single cheap query
  rather than a scan that repeats forever. It also leaves the core-owned
  table empty, so whoever eventually drops it isn't deleting live data.

  Returns the number of versions written.
  """
  def backfill_version_categories(group_slug) do
    legacy =
      from(pc in PublishingPostCategory,
        join: p in PublishingPost,
        on: p.uuid == pc.post_uuid,
        join: g in PublishingGroup,
        on: g.uuid == p.group_uuid,
        where: g.slug == ^group_slug,
        select: {pc.post_uuid, pc.category_uuid}
      )
      |> repo().all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    if legacy == %{} do
      0
    else
      {:ok, written} = repo().transaction(fn -> write_backfill(legacy) end)
      Logger.info("[Publishing] Moved categories onto #{written} versions in #{group_slug}")
      written
    end
  rescue
    error ->
      Logger.warning("[Publishing] Category backfill skipped: #{inspect(error)}")
      0
  end

  defp write_backfill(legacy) do
    post_uuids = Map.keys(legacy)

    # An EMPTY list counts as "not migrated yet", not as a deliberate answer.
    # A save can reach a version before this ever runs — the editor builds its
    # form from `version.data`, sees no categories there because they are
    # still in the old table, and writes that back as `[]`. Treating that as a
    # real edit would let one autosave permanently unfile a post, and the
    # writer would have no way to know it happened.
    #
    # Safe because the legacy rows are drained below: once the move is done
    # there is nothing left to re-apply, so a genuine "filed under nothing"
    # sticks from then on.
    # One key, set in place. Reading each row and writing the whole `data`
    # map back would hand a concurrent save's work to whichever statement
    # committed second: the map was read before that save and still holds
    # the old featured image, tags, SEO and excerpt, and the UPDATE simply
    # waits for the save to commit and then overwrites all of it. Nothing
    # errors and `updated_at` moves, so the revert looks like a fresh write.
    #
    # That window is open for as long as the legacy rows survive, and every
    # regenerate re-enters it — which is every save, trash and publish in
    # the group. `jsonb_set` touches the one key against the row as it is at
    # UPDATE time, the way `unfile_deleted_category/1` already does.
    written =
      legacy
      |> Enum.reduce(0, fn {post_uuid, uuids}, count ->
        uuids = Enum.uniq(uuids)

        {updated, _} =
          from(v in PublishingVersion,
            where: v.post_uuid == ^post_uuid,
            where:
              fragment("NOT (? \\? 'category_uuids')", v.data) or
                fragment("? -> 'category_uuids' = '[]'::jsonb", v.data),
            update: [
              set: [
                data: fragment("jsonb_set(?, '{category_uuids}', ?::jsonb)", v.data, ^uuids)
              ]
            ]
          )
          |> repo().update_all([])

        count + updated
      end)

    from(pc in PublishingPostCategory, where: pc.post_uuid in ^post_uuids)
    |> repo().delete_all()

    written
  end

  @doc """
  Files a post's ACTIVE version under `category_uuids` (max 100 — a
  client-misbehavior guard, same convention as the reorder fns). Only
  categories belonging to the post's group are accepted; unknown/foreign
  uuids are silently dropped rather than erroring, so a stale selection
  can't fail the whole save.

  Assignments are version-level now, and this writes the version the public
  sees. The editor doesn't use it — a writer edits the version they have
  open, through the form — but it stays as the way to file a post when you
  have a post uuid and mean "the live one": seeds, imports, bulk tools.
  """
  def replace_post_categories(post_uuid, category_uuids, opts \\ [])
      when is_list(category_uuids) and length(category_uuids) <= 100 do
    result = do_replace_post_categories(post_uuid, category_uuids, opts)

    case result do
      {:error, reason} ->
        ActivityLog.log_failed_mutation(
          "publishing.post.categorized",
          ActivityLog.actor_uuid(opts),
          "publishing_post",
          post_uuid,
          %{"reason" => ActivityLog.reason_string(reason)}
        )

        result

      _ ->
        result
    end
  end

  defp do_replace_post_categories(post_uuid, category_uuids, opts) do
    with {:ok, post} <- get_post(post_uuid),
         {:ok, version} <- target_version(post) do
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
        version
        |> Ecto.Changeset.change(
          data: Map.put(version.data || %{}, "category_uuids", valid_uuids)
        )
        |> repo().update()

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

  @doc """
  Full category structs for a set of uuids within a group, position-ordered.

  The lookup categories now go through: assignments live on the version, so a
  reader has uuids and needs rows. Foreign or deleted uuids simply don't come
  back — a version filed under a category somebody later deleted renders with
  one fewer chip instead of erroring.
  """
  def categories_by_uuids(_group_slug, []), do: []

  def categories_by_uuids(group_slug, uuids) when is_list(uuids) do
    castable =
      Enum.filter(uuids, fn value ->
        is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))
      end)

    if castable == [] do
      []
    else
      group_slug
      |> list_categories()
      |> Enum.filter(&(&1.uuid in castable))
    end
  end

  def categories_by_uuids(_group_slug, _uuids), do: []

  @doc """
  Full category structs on a post's ACTIVE version, position-ordered.

  For a specific version, read `category_uuids` off the post map you already
  have and resolve with `categories_by_uuids/2` — the public post page does
  that, so `?v=2` shows how v2 was filed.
  """
  def categories_of_post(post_uuid) do
    with {:ok, post} <- get_post(post_uuid),
         {:ok, version} <- target_version(post) do
      group_slug = group_slug_of(post)
      categories_by_uuids(group_slug, PublishingVersion.get_category_uuids(version))
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # The version a post-level caller means: the live one if there is one,
  # otherwise the newest draft. A post that has never been published has no
  # active version, and filing something before publishing it is the normal
  # order of work — refusing there would make categories settable only after
  # the fact.
  defp target_version(post) do
    case active_version(post) do
      {:ok, version} -> {:ok, version}
      {:error, _} -> latest_version(post)
    end
  end

  defp active_version(%{active_version_uuid: uuid}) when is_binary(uuid) do
    case repo().get(PublishingVersion, uuid) do
      nil -> {:error, :no_active_version}
      version -> {:ok, version}
    end
  end

  defp active_version(_post), do: {:error, :no_active_version}

  defp latest_version(%{uuid: post_uuid}) do
    from(v in PublishingVersion,
      where: v.post_uuid == ^post_uuid,
      order_by: [desc: v.version_number],
      limit: 1
    )
    |> repo().one()
    |> case do
      nil -> {:error, :no_version}
      version -> {:ok, version}
    end
  end

  defp latest_version(_post), do: {:error, :no_version}

  defp group_slug_of(post) do
    case repo().get(PublishingGroup, post.group_uuid) do
      nil -> nil
      group -> group.slug
    end
  end

  @doc "Category uuids on a post's ACTIVE version."
  def category_uuids_for_post(post_uuid) do
    with {:ok, post} <- get_post(post_uuid),
         {:ok, version} <- target_version(post) do
      PublishingVersion.get_category_uuids(version)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  Category uuids per post, from each post's ACTIVE version —
  `%{post_uuid => [category_uuid]}`.

  The listing cache no longer needs this (it has the version in hand while
  building each entry), but bulk callers that only hold post uuids still do.
  """
  def categories_for_posts(post_uuids) when is_list(post_uuids) do
    from(p in PublishingPost,
      join: v in PublishingVersion,
      on: v.uuid == p.active_version_uuid,
      where: p.uuid in ^post_uuids,
      select: {p.uuid, fragment("? -> 'category_uuids'", v.data)}
    )
    |> repo().all()
    |> Map.new(fn {post_uuid, uuids} ->
      {post_uuid, uuids |> List.wrap() |> Enum.filter(&is_binary/1)}
    end)
  rescue
    # Must degrade to "no categories", never take a public listing down.
    _ -> %{}
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
    # Counted off each post's ACTIVE version, because that is the filing the
    # public sees. A draft version refiled into a different category doesn't
    # move the count until it is published — otherwise the admin tree would
    # advertise archive entries that aren't there yet.
    from(p in PublishingPost,
      join: g in PublishingGroup,
      on: g.uuid == p.group_uuid,
      join: v in PublishingVersion,
      on: v.uuid == p.active_version_uuid,
      where: g.slug == ^group_slug,
      where: is_nil(p.trashed_at),
      select: {p.uuid, fragment("? -> 'category_uuids'", v.data)}
    )
    |> repo().all()
    |> Enum.reduce(%{}, fn {_post_uuid, uuids}, acc ->
      uuids
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.reduce(acc, fn uuid, inner -> Map.update(inner, uuid, 1, &(&1 + 1)) end)
    end)
  rescue
    _ -> %{}
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

  # Failure chokepoint — the success row is written at each mutation site;
  # this records the error branch (db_pending) so a failed admin action
  # still leaves an audit trail, matching groups/posts/versions.
  defp log_category_failure({:error, reason} = err, action, opts, resource_uuid, metadata) do
    ActivityLog.log_failed_mutation(
      action,
      ActivityLog.actor_uuid(opts),
      "publishing_category",
      resource_uuid,
      Map.put(metadata, "reason", ActivityLog.reason_string(reason))
    )

    err
  end

  defp log_category_failure(result, _action, _opts, _resource_uuid, _metadata), do: result
end
