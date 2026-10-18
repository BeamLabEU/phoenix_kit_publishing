defmodule PhoenixKit.Modules.Publishing.API.RestoreGroups do
  @moduledoc false
  # Tool `publishing.restore_groups` (spec §9.17): bring groups back from the trash.

  alias PhoenixKit.Modules.Publishing.API.Common
  alias PhoenixKit.Modules.Publishing.{DBStorage, Groups}

  @tool "publishing.restore_groups"

  @spec call(map(), map()) :: {:ok, map()} | {:preview, map(), String.t()}
  def call(input, ctx) do
    plan = plan(input["groups"])
    if Map.get(ctx, :dry_run?, false), do: preview(plan), else: execute(plan, ctx)
  end

  # {:restore, ref, db_group} | {:already, ref, db_group} | {:error, ref, row}
  defp plan(refs) do
    {entries, _seen} =
      Enum.map_reduce(refs, MapSet.new(), fn
        %{"slug" => slug} = ref, seen when map_size(ref) == 1 and is_binary(slug) ->
          if MapSet.member?(seen, slug) do
            row =
              Common.row_error(ref, "invalid_ref", "the same group appears twice in the request")

            {{:error, ref, row}, seen}
          else
            {classify(ref, DBStorage.get_group_by_slug(slug)), MapSet.put(seen, slug)}
          end

        ref, seen ->
          {{:error, ref, Common.row_error(ref, "invalid_ref", "give {slug}")}, seen}
      end)

    entries
  end

  defp classify(ref, nil),
    do: {:error, ref, Common.row_error(ref, "not_found", "The group does not exist.")}

  defp classify(ref, %{status: "trashed"} = group), do: {:restore, ref, group}
  defp classify(ref, group), do: {:already, ref, group}

  defp execute(plan, ctx) do
    opts = Common.write_opts(ctx, @tool)

    rows =
      Enum.map(plan, fn
        {:restore, ref, group} ->
          case Groups.restore_group(group.slug, opts) do
            {:ok, _} -> Common.row_ok(ref, "restored", group.uuid)
            {:error, reason} -> Common.row_from_error(ref, reason)
          end

        {:already, ref, group} ->
          Common.row_ok(ref, "unchanged", group.uuid)

        {:error, _ref, row} ->
          row
      end)

    Common.batch_result(rows)
  end

  defp preview(plan) do
    plan = Enum.map(plan, &with_counts/1)

    rows =
      Enum.map(plan, fn
        {{:restore, ref, group}, counts} ->
          Common.row_ok(ref, "restored", group.uuid, counts)

        {{:already, ref, group}, _counts} ->
          Common.row_ok(ref, "unchanged", group.uuid)

        {:error, _ref, row} ->
          row
      end)

    # The fingerprint binds every entry: a group's state, the post counts the owner saw, and the
    # ref and code of an error row (a group that appears after the preview must not ride in on
    # the old confirmation).
    term = Enum.map(plan, &fingerprint_entry/1)

    Common.preview(rows, %{"requires_confirmation" => true}, {:restore_groups, term})
  end

  defp with_counts({:restore, ref, group}) do
    posts = DBStorage.list_posts(group.slug)

    counts = %{
      "post_count" => length(posts),
      "live_posts" => Enum.count(posts, &(&1.active_version_uuid != nil))
    }

    {{:restore, ref, group}, counts}
  end

  defp with_counts({:already, ref, group}), do: {{:already, ref, group}, nil}
  defp with_counts({:error, _ref, _row} = entry), do: entry

  defp fingerprint_entry({:error, ref, row}),
    do: {:error, row["error"]["code"], Common.fingerprint(ref)}

  defp fingerprint_entry({{kind, _ref, group}, counts}),
    do: {kind, group.uuid, group.status, group.slug, Common.fingerprint(group.data), counts}
end
