defmodule PhoenixKit.Modules.Publishing.API.PostBatch do
  @moduledoc false
  # What trash_posts and restore_posts share: resolving a list of post refs into one plan entry
  # per ref, and reading the data a preview describes.

  alias PhoenixKit.Modules.Publishing.API.{Common, Refs}
  alias PhoenixKit.Modules.Publishing.DBStorage

  @doc """
  One entry per ref, in order: `{kind, ref, hit}` for a post to act on, `{:already, ref, hit}` for a
  post that is already in the wanted state (`already?` decides, over the post row) and
  `{:error, ref, row}` for a row that cannot run.
  """
  def plan(refs, kind, already?) do
    {entries, _seen} =
      Enum.map_reduce(refs, MapSet.new(), fn ref, seen ->
        case Refs.resolve_post(ref, include_trashed: true) do
          {:ok, %{db_post: db_post} = hit} -> classify(kind, already?, ref, hit, db_post, seen)
          {:error, :invalid_ref} -> {{:error, ref, invalid_ref_row(ref)}, seen}
          {:error, :not_found} -> {{:error, ref, not_found_row(ref)}, seen}
        end
      end)

    entries
  end

  defp classify(kind, already?, ref, hit, db_post, seen) do
    cond do
      MapSet.member?(seen, db_post.uuid) ->
        row =
          Common.row_error(ref, "invalid_ref", "the same post appears twice in the request")

        {{:error, ref, row}, seen}

      already?.(db_post) ->
        {{:already, ref, hit}, MapSet.put(seen, db_post.uuid)}

      hit.group.status == "trashed" ->
        row =
          Common.row_error(ref, "group_trashed", "the group is in the trash; restore it first")

        {{:error, ref, row}, seen}

      true ->
        {{kind, ref, hit}, MapSet.put(seen, db_post.uuid)}
    end
  end

  defp invalid_ref_row(ref),
    do: Common.row_error(ref, "invalid_ref", "give {id} or {group, slug}")

  defp not_found_row(ref), do: Common.row_error(ref, "not_found", "The post does not exist.")

  @doc """
  Built from DBStorage rows (never read_post: it excludes trashed posts and heals): the versions,
  and the content rows of the version visitors see (else the latest).
  """
  def shown(hit) do
    versions = DBStorage.list_versions(hit.db_post.uuid)

    shown =
      Enum.find(versions, &(&1.uuid == hit.db_post.active_version_uuid)) || List.last(versions)

    {versions, if(shown, do: DBStorage.list_contents(shown.uuid), else: [])}
  end
end
