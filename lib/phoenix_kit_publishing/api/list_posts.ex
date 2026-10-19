defmodule PhoenixKit.Modules.Publishing.API.ListPosts do
  @moduledoc false
  # Tool `publishing.list_posts`: the post rows of one group, filtered and paged
  # on LIGHT rows (post rows, one filter query); versions and contents are loaded for the page only.

  alias PhoenixKit.Modules.Publishing.API.{Common, Presenter, Refs}
  alias PhoenixKit.Modules.Publishing.{Constants, DBStorage}
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing

  @default_limit 20
  @max_limit 100

  @spec call(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def call(input, _ctx) do
    with {:ok, group} <- input["group"] |> Refs.resolve_group() |> not_found(input["group"]),
         {:ok, limit, warnings} <- limit(input["limit"]),
         {:ok, allow} <- category_allow_list(group, input["category_id"]),
         status = input["status"] || "all",
         now = DateTime.utc_now(),
         tz = Constants.site_tz(),
         rows = filter(group.slug, status, allow, now, tz),
         {:ok, rest} <- after_cursor(rows, input["cursor"]) do
      page = Enum.take(rest, limit)
      next = if length(rest) > limit, do: encode_cursor(List.last(page)), else: nil
      date_counts = Listing.group_date_counts(group.slug)

      posts = Enum.map(page, &present(&1, group, now, tz, date_counts))

      {:ok,
       Common.with_warnings(
         %{"posts" => posts, "count" => length(rows), "next_cursor" => next},
         warnings
       )}
    end
  end

  defp not_found({:ok, _} = ok, _ref), do: ok

  defp not_found({:error, :not_found}, ref),
    do: {:error, :not_found, "The group does not exist.", %{ref: clip(ref)}}

  defp clip(ref), do: if(is_binary(ref), do: String.slice(ref, 0, 100), else: nil)

  defp limit(nil), do: {:ok, @default_limit, []}

  defp limit(n) when is_integer(n) and n > @max_limit,
    do:
      {:ok, @max_limit,
       [%{"code" => "limit_trimmed", "message" => "limit was trimmed to #{@max_limit}"}]}

  defp limit(n) when is_integer(n) and n >= 1, do: {:ok, n, []}
  defp limit(_other), do: Common.invalid("limit", "must be an integer of at least 1")

  # Post rows in the module's order (DBStorage.list_posts/2 already applies it).
  defp filter(group_slug, status, allow, now, tz) do
    group_slug
    |> DBStorage.list_posts(db_status(status))
    |> Enum.filter(fn post ->
      (allow == :all or MapSet.member?(allow, post.uuid)) and
        status_matches?(post, status, now, tz)
    end)
  end

  defp db_status(status) when status in ["published", "scheduled"], do: "published"
  defp db_status("all"), do: nil
  defp db_status(status), do: status

  defp status_matches?(post, "published", now, tz),
    do: Presenter.status(post, [], now, tz) == "published"

  defp status_matches?(post, "scheduled", now, tz),
    do: Presenter.status(post, [], now, tz) == "scheduled"

  defp status_matches?(_post, _status, _now, _tz), do: true

  # --- category filter: ONE query ---------------------------------------------------------

  defp category_allow_list(_group, nil), do: {:ok, :all}

  defp category_allow_list(group, category_id) do
    categories = Common.categories!(group.slug)

    case Enum.find(categories, &(&1.uuid == category_id)) do
      nil ->
        Common.invalid("category_id", "is not a category of this group", "unknown_category")

      category ->
        subtree = subtree(category.uuid, categories)

        sql = """
        SELECT p.uuid
        FROM phoenix_kit_publishing_posts p
        JOIN phoenix_kit_publishing_groups g ON g.uuid = p.group_uuid
        JOIN LATERAL (
          SELECT v.data FROM phoenix_kit_publishing_versions v
          WHERE v.post_uuid = p.uuid
          ORDER BY (v.uuid = p.active_version_uuid) DESC, v.version_number DESC
          LIMIT 1
        ) shown ON true
        WHERE g.slug = $1 AND jsonb_exists_any(shown.data -> 'category_uuids', $2::text[])
        """

        uuids =
          PhoenixKit.RepoHelper.repo().query!(sql, [group.slug, subtree]).rows
          |> Enum.map(fn [raw] -> Ecto.UUID.load!(raw) end)

        {:ok, MapSet.new(uuids)}
    end
  end

  defp subtree(root, categories) do
    by_parent = Enum.group_by(categories, & &1.parent_uuid, & &1.uuid)
    walk([root], by_parent, %{}) |> Map.keys()
  end

  defp walk([], _by_parent, seen), do: seen

  defp walk([uuid | rest], by_parent, seen) do
    if Map.has_key?(seen, uuid),
      do: walk(rest, by_parent, seen),
      else: walk(Map.get(by_parent, uuid, []) ++ rest, by_parent, Map.put(seen, uuid, true))
  end

  # --- cursor ------------------------------------------------------------------------------

  defp encode_cursor(post), do: Base.url_encode64(post.uuid, padding: false)

  defp after_cursor(rows, nil), do: {:ok, rows}

  defp after_cursor(rows, cursor) do
    with {:ok, uuid} <- Base.url_decode64(cursor, padding: false),
         idx when is_integer(idx) <- Enum.find_index(rows, &(&1.uuid == uuid)) do
      {:ok, Enum.drop(rows, idx + 1)}
    else
      _ ->
        Common.invalid(
          "cursor",
          "no longer matches the list; start again without a cursor",
          "cursor_stale"
        )
    end
  end

  # --- one row (HEAVY: versions and contents of this post only) --------------------------------

  defp present(db_post, group, now, tz, date_counts) do
    versions = DBStorage.list_versions(db_post.uuid)
    shown = Enum.find(versions, &(&1.uuid == db_post.active_version_uuid)) || List.last(versions)
    contents = if shown, do: DBStorage.list_contents(shown.uuid), else: []

    Presenter.post_summary(db_post, group, versions, contents,
      now: now,
      tz: tz,
      date_counts: date_counts
    )
  end
end
