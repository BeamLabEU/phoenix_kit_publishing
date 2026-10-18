defmodule PhoenixKit.Modules.Publishing.API.TrashPosts do
  @moduledoc false
  # Tool `publishing.trash_posts` (spec §9.11): move posts to the trash (reversible with restore_posts).

  alias PhoenixKit.Modules.Publishing.API.{Common, Presenter, Refs}
  alias PhoenixKit.Modules.Publishing.{DBStorage, Posts}

  @tool "publishing.trash_posts"

  @spec call(map(), map()) :: {:ok, map()} | {:preview, map(), String.t()}
  def call(input, ctx) do
    plan = plan(input["posts"])
    if Map.get(ctx, :dry_run?, false), do: preview(plan), else: execute(plan, ctx)
  end

  # One entry per ref, in order: {:trash, ref, hit} | {:already, ref, hit} | {:error, ref, row}.
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

      db_post.trashed_at != nil ->
        {{:already, ref, hit}, MapSet.put(seen, db_post.uuid)}

      hit.group.status == "trashed" ->
        row =
          Common.row_error(ref, "group_trashed", "the group is in the trash; restore it first")

        {{:error, ref, row}, seen}

      true ->
        {{:trash, ref, hit}, MapSet.put(seen, db_post.uuid)}
    end
  end

  defp invalid_ref_row(ref),
    do: Common.row_error(ref, "invalid_ref", "give {id} or {group, slug}")

  defp not_found_row(ref), do: Common.row_error(ref, "not_found", "The post does not exist.")

  defp execute(plan, ctx) do
    opts = Common.write_opts(ctx, @tool)

    rows =
      Enum.map(plan, fn
        {:trash, ref, hit} ->
          case Posts.trash_post(hit.group.slug, hit.db_post.uuid, opts) do
            {:ok, _} -> Common.row_ok(ref, "removed", hit.db_post.uuid)
            {:error, reason} -> Common.row_from_error(ref, reason)
          end

        {:already, ref, hit} ->
          Common.row_ok(ref, "unchanged", hit.db_post.uuid)

        {:error, _ref, row} ->
          row
      end)

    Common.batch_result(rows)
  end

  defp preview(plan) do
    entries =
      Enum.map(plan, fn
        {kind, ref, hit} when kind in [:trash, :already] -> {kind, ref, hit, shown(hit)}
        error -> error
      end)

    rows =
      Enum.map(entries, fn
        {:trash, ref, hit, shown} ->
          Common.row_ok(ref, "removed", hit.db_post.uuid, describe(hit, shown))

        {:already, ref, hit, _shown} ->
          Common.row_ok(ref, "unchanged", hit.db_post.uuid)

        {:error, _ref, row} ->
          row
      end)

    term =
      for {kind, _ref, hit, {versions, shown_contents}} <- entries,
          kind in [:trash, :already],
          do: {kind, Common.post_state(hit.db_post, hit.group, versions, shown_contents)}

    Common.preview(
      rows,
      %{"requires_confirmation" => true},
      {:trash_posts, term, Enum.map(plan, &elem(&1, 0))}
    )
  end

  # Built from DBStorage rows (never read_post: it excludes trashed posts and heals): the
  # versions, and the content rows of the version visitors see (else the latest).
  defp shown(hit) do
    versions = DBStorage.list_versions(hit.db_post.uuid)

    shown =
      Enum.find(versions, &(&1.uuid == hit.db_post.active_version_uuid)) || List.last(versions)

    {versions, if(shown, do: DBStorage.list_contents(shown.uuid), else: [])}
  end

  defp describe(hit, {_versions, contents}) do
    live? = hit.db_post.active_version_uuid != nil

    %{
      "changes" => %{
        "status" => %{"from" => Presenter.status(hit.db_post), "to" => "trashed"}
      },
      "title" => contents |> Enum.find(&(&1.title not in [nil, ""])) |> then(&(&1 && &1.title)),
      "languages" => contents |> Enum.map(& &1.language) |> Enum.sort(),
      "public_paths" =>
        if(live?,
          do: hit.db_post |> Presenter.public_paths(contents) |> Map.values() |> Enum.sort(),
          else: []
        )
    }
  end
end
