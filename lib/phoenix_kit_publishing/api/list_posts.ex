defmodule PhoenixKit.Modules.Publishing.API.ListPosts do
  @moduledoc false
  # Tool `publishing.list_posts`: the post rows of one group, filtered and paged. Statuses that
  # are columns (all, draft, trashed) are cut to the page in the query; published and scheduled
  # depend on the site clock, so their rows are filtered in memory. Versions and contents are
  # loaded for the page only.

  alias PhoenixKit.Modules.Publishing.API.{Common, Presenter, Refs}
  alias PhoenixKit.Modules.Publishing.{Constants, DBStorage}
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing

  @default_limit 20
  @max_limit 100
  @query_statuses ~w(all draft trashed)

  @spec call(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def call(input, _ctx) do
    with {:ok, group} <-
           input["group"] |> Refs.resolve_group() |> Refs.group_missing(input["group"]),
         {:ok, limit, warnings} <- limit(input["limit"]),
         {:ok, allow} <- category_allow_list(group, input["category_id"]),
         status = input["status"] || "all",
         now = DateTime.utc_now(),
         tz = Constants.site_tz(),
         {:ok, {page, total, more?}} <-
           page(group.slug, status, allow, input["cursor"], limit, now, tz) do
      next = if more?, do: encode_cursor(List.last(page)), else: nil
      date_counts = Listing.group_date_counts(group.slug)

      posts = Enum.map(page, &present(&1, group, now, tz, date_counts))

      {:ok,
       Common.with_warnings(
         %{"posts" => posts, "count" => total, "next_cursor" => next},
         warnings
       )}
    end
  end

  defp limit(nil), do: {:ok, @default_limit, []}

  defp limit(n) when is_integer(n) and n > @max_limit,
    do:
      {:ok, @max_limit,
       [%{"code" => "limit_trimmed", "message" => "limit was trimmed to #{@max_limit}"}]}

  defp limit(n) when is_integer(n) and n >= 1, do: {:ok, n, []}
  defp limit(_other), do: Common.invalid("limit", "must be an integer of at least 1")

  # `{:ok, {page_rows, total, more?}}`.
  defp page(group_slug, status, allow, cursor, limit, _now, _tz) when status in @query_statuses do
    with {:ok, after_uuid} <- decode_cursor(cursor),
         {:ok, %{rows: rows, total: total, more?: more?}} <-
           group_slug
           |> DBStorage.list_posts_page(db_status(status),
             limit: limit,
             allow: allow_list(allow),
             after: after_uuid
           )
           |> stale() do
      {:ok, {rows, total, more?}}
    end
  end

  # Post rows in the module's order (DBStorage.list_posts/2 already applies it).
  defp page(group_slug, status, allow, cursor, limit, now, tz) do
    rows =
      group_slug
      |> DBStorage.list_posts(db_status(status))
      |> Enum.filter(fn post ->
        (allow == :all or MapSet.member?(allow, post.uuid)) and
          status_matches?(post, status, now, tz)
      end)

    with {:ok, rest} <- after_cursor(rows, cursor) do
      {:ok, {Enum.take(rest, limit), length(rows), length(rest) > limit}}
    end
  end

  defp allow_list(:all), do: nil
  defp allow_list(allow), do: MapSet.to_list(allow)

  defp stale(:error), do: cursor_stale()
  defp stale(ok), do: ok

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

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, uuid} <- Ecto.UUID.cast(decoded) do
      {:ok, uuid}
    else
      :error -> cursor_stale()
    end
  end

  defp after_cursor(rows, nil), do: {:ok, rows}

  defp after_cursor(rows, cursor) do
    with {:ok, uuid} <- decode_cursor(cursor),
         idx when is_integer(idx) <- Enum.find_index(rows, &(&1.uuid == uuid)) do
      {:ok, Enum.drop(rows, idx + 1)}
    else
      _ -> cursor_stale()
    end
  end

  defp cursor_stale do
    Common.invalid(
      "cursor",
      "no longer matches the list; start again without a cursor",
      "cursor_stale"
    )
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
