defmodule PhoenixKit.Modules.Publishing.API.RestorePosts do
  @moduledoc false
  # Tool `publishing.restore_posts` (spec §9.11): bring posts back from the trash.

  alias PhoenixKit.Modules.Publishing.API.{Common, Danger, Presenter, Refs}
  alias PhoenixKit.Modules.Publishing.{Constants, DBStorage, Posts}

  @tool "publishing.restore_posts"

  @spec call(map(), map()) :: {:ok, map()} | {:preview, map(), String.t()}
  def call(input, ctx) do
    plan = plan(input["posts"])
    if Map.get(ctx, :dry_run?, false), do: preview(input, plan, ctx), else: execute(plan, ctx)
  end

  # One entry per ref, in order: {:restore, ref, hit} | {:already, ref, hit} (not in the trash)
  # | {:error, ref, row}.
  defp plan(refs) do
    {entries, _seen} =
      Enum.map_reduce(refs, MapSet.new(), fn ref, seen ->
        case Refs.resolve_post(ref, include_trashed: true) do
          {:ok, %{db_post: db_post} = hit} -> classify(ref, hit, db_post, seen)
          {:error, :invalid_ref} -> {{:error, ref, invalid_ref_row(ref)}, seen}
          {:error, :not_found} -> {{:error, ref, not_found_row(ref)}, seen}
        end
      end)

    entries
  end

  defp classify(ref, hit, db_post, seen) do
    cond do
      MapSet.member?(seen, db_post.uuid) ->
        row =
          Common.row_error(ref, "invalid_ref", "the same post appears twice in the request")

        {{:error, ref, row}, seen}

      db_post.trashed_at == nil ->
        {{:already, ref, hit}, MapSet.put(seen, db_post.uuid)}

      hit.group.status == "trashed" ->
        row =
          Common.row_error(ref, "group_trashed", "the group is in the trash; restore it first")

        {{:error, ref, row}, seen}

      true ->
        {{:restore, ref, hit}, MapSet.put(seen, db_post.uuid)}
    end
  end

  defp invalid_ref_row(ref),
    do: Common.row_error(ref, "invalid_ref", "give {id} or {group, slug}")

  defp not_found_row(ref), do: Common.row_error(ref, "not_found", "The post does not exist.")

  defp execute(plan, ctx) do
    opts = Common.write_opts(ctx, @tool)

    rows =
      Enum.map(plan, fn
        {:restore, ref, hit} ->
          case Posts.restore_post(hit.group.slug, hit.db_post.uuid, opts) do
            {:ok, _} -> Common.row_ok(ref, "restored", hit.db_post.uuid)
            {:error, reason} -> Common.row_from_error(ref, reason)
          end

        {:already, ref, hit} ->
          Common.row_ok(ref, "unchanged", hit.db_post.uuid)

        {:error, _ref, row} ->
          row
      end)

    Common.batch_result(rows)
  end

  defp preview(input, plan, ctx) do
    entries =
      Enum.map(plan, fn
        {kind, ref, hit} when kind in [:restore, :already] -> {kind, ref, hit, shown(hit)}
        error -> error
      end)

    rows =
      Enum.map(entries, fn
        {:restore, ref, hit, shown} ->
          Common.row_ok(ref, "restored", hit.db_post.uuid, describe(hit, shown))

        {:already, ref, hit, _shown} ->
          Common.row_ok(ref, "unchanged", hit.db_post.uuid)

        {:error, _ref, row} ->
          row
      end)

    term =
      for {kind, _ref, hit, {versions, shown_contents}} <- entries,
          kind in [:restore, :already],
          do: {kind, Common.post_state(hit.db_post, hit.group, versions, shown_contents)}

    Common.preview(
      rows,
      %{"requires_confirmation" => Danger.restore_posts(input, ctx)},
      {:restore_posts, term, Enum.map(plan, &elem(&1, 0))}
    )
  end

  # Built from DBStorage rows (never read_post: it excludes trashed posts and heals): the
  # versions, and the content rows of the version visitors would see (else the latest).
  defp shown(hit) do
    versions = DBStorage.list_versions(hit.db_post.uuid)

    shown =
      Enum.find(versions, &(&1.uuid == hit.db_post.active_version_uuid)) || List.last(versions)

    {versions, if(shown, do: DBStorage.list_contents(shown.uuid), else: [])}
  end

  defp describe(hit, {_versions, contents}) do
    db_post = hit.db_post
    live? = db_post.active_version_uuid != nil
    scheduled? = live? and scheduled_ahead?(db_post)
    visible? = live? and not scheduled?

    %{
      "becomes_visible" => visible?,
      "changes" => %{"status" => %{"from" => "trashed", "to" => target_status(live?, scheduled?)}},
      "title" => contents |> Enum.find(&(&1.title not in [nil, ""])) |> then(&(&1 && &1.title)),
      "public_paths" =>
        if(visible?,
          do: db_post |> Presenter.public_paths(contents) |> Map.values() |> Enum.sort(),
          else: []
        )
    }
  end

  defp scheduled_ahead?(db_post) do
    Constants.scheduled_ahead?(%{
      mode: db_post.mode,
      date: db_post.post_date,
      time: db_post.post_time
    })
  end

  defp target_status(_live?, true), do: "scheduled"
  defp target_status(true, _scheduled?), do: "published"
  defp target_status(false, _scheduled?), do: "draft"
end
