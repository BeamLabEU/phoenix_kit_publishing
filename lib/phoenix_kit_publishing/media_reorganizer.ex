defmodule PhoenixKit.Modules.Publishing.MediaReorganizer do
  @moduledoc """
  Publishing's plan source for core's media reorganizer
  (`mix phoenix_kit.media.reorganize`), registered through
  the publishing module's media reorganizer callback.

  The group folders of `PhoenixKit.Modules.Publishing.MediaFolders` are
  planned by core's `PhoenixKit.Modules.Storage.Reorganizer.ResourceSource`,
  which applies the whole `Reorganizer.Source` contract: when the host's
  hooks change, a group's folder moves under the new parent (a folder
  found by its deterministic `publishing-group-<uuid>` name is renamed
  after the name hook and its group's pointer back-filled); with no hook
  configured, nothing but reports.

  Orphans — folders of a trashed or deleted group, reported, never moved:
  core's scan finds them by the deterministic name only, and only at the
  root or under a parent a hook named for a live group. Every live folder of
  the site's Media library that a trashed group points at is therefore
  reported here too, through the pointer — whatever it is called and
  wherever it sits — once per folder, unless a live group points at it as
  well (it is that group's) or core's scan already reported it. A folder in
  another library is not the group's and is never reported. A hard-deleted
  group's pointer went with the row: its folder is reported only if core's
  scan finds it.

  Post folders (`MediaFolders.post_folders?/0`) are never planned: they sit
  inside their group's folder and move with it. A trashed post's folder is
  reported the same way, through the pointer its versions hold (a folder a
  live post points at too is not); a hard-deleted post's is not traced.

  What is publishing's own: a group is live until trashed, its pointer is
  `data["media_folder_uuid"]`, those pointer-found orphans, a
  `:hook_error` report for a name hook that cannot be called (core reports
  the parent hook only, and asks the name hook only once a folder exists),
  and `:unfiled` — a group or post whose files are still outside its folder,
  for which `PhoenixKit.Modules.Publishing.MediaAdoption` (`mix
  phoenix_kit_publishing.media.adopt --apply`) is the fix. The reorganizer
  moves folders only; it never files a file.
  """

  @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.MediaAdoption
  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Folder, FolderLink, Libraries}
  alias PhoenixKit.Modules.Storage.Reorganizer.ResourceSource

  @source "publishing"

  @doc "The plan (`Reorganizer.Source.plan/2`); `opts` takes `:pending_days`."
  @impl true
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    core = ResourceSource.plan(spec(), actor_uuid, opts)

    reported =
      for %{kind: :orphan, folder: %Folder{uuid: uuid}} <- core, into: %{}, do: {uuid, true}

    group_orphans = pointer_orphans(reported)

    reported =
      Enum.reduce(group_orphans, reported, fn %{folder: folder}, acc ->
        Map.put(acc, folder.uuid, true)
      end)

    core ++
      name_hook_problems(core) ++
      group_orphans ++
      post_orphans(reported) ++
      unfiled(actor_uuid, opts)
  end

  defp spec do
    %{
      source: @source,
      app: MediaFolders.app(),
      noun: "group",
      kinds: [
        %{
          kind: :group,
          schema: PublishingGroup,
          prefix: MediaFolders.folder_prefix(),
          pointer: MediaFolders.pointer(),
          live: &where(&1, [g], g.status != "trashed")
        }
      ]
    }
  end

  # Core names a failing name hook only when it has asked it — once some
  # group has a folder — so a broken one stays silent until then. Nothing is
  # added when core already reported it, or when the module is not opted in
  # (no parent hook: the name hook is never asked).
  @core_name_hook_labels ["attachments folder-name hook", "attachments hooks"]

  defp name_hook_problems(core) do
    if MediaFolders.enabled?() and not core_reported_name_hook?(core),
      do: name_hook_actions(),
      else: []
  end

  defp core_reported_name_hook?(core),
    do: Enum.any?(core, &(&1.kind == :hook_error and &1.label in @core_name_hook_labels))

  defp name_hook_actions do
    MediaFolders.hook_problems()
    |> Enum.filter(&String.starts_with?(&1, "attachments_folder_name"))
    |> Enum.map(fn problem ->
      %{
        source: @source,
        kind: :hook_error,
        op: :report,
        label: "attachments name hook",
        counts: nil,
        reason: problem
      }
    end)
  end

  # Every live Media folder a trashed group points at, except one a live
  # group points at too (it is that group's — core's claims rule) and one
  # core's scan already reported (`reported`), so no folder is reported
  # twice.
  defp pointer_orphans(reported) do
    folders =
      from(g in PublishingGroup,
        join: f in Folder,
        on: fragment("lower(?->>?)", g.data, ^pointer_key()) == type(f.uuid, :string),
        where: g.status == "trashed" and is_nil(f.trashed_at),
        where: f.library_uuid == ^Libraries.media_uuid(),
        order_by: [asc: g.inserted_at, asc: g.uuid],
        select: {map(g, [:name, :slug]), f}
      )
      |> repo().all()
      |> Enum.reject(fn {_group, folder} -> Map.has_key?(reported, folder.uuid) end)

    claimed = live_group_pointers(Enum.map(folders, fn {_group, folder} -> folder.uuid end))

    # Two trashed groups may point at one folder: it is reported once, for
    # the older group.
    folders =
      folders
      |> Enum.reject(fn {_group, folder} -> folder.uuid in claimed end)
      |> Enum.uniq_by(fn {_group, folder} -> folder.uuid end)

    counts = counts(Enum.map(folders, fn {_group, folder} -> folder.uuid end))

    Enum.map(folders, fn {group, folder} ->
      {files, _links} = folder_counts = Map.get(counts, folder.uuid, {0, 0})

      %{
        source: @source,
        kind: :orphan,
        op: :report,
        label: folder.name,
        folder: folder,
        counts: folder_counts,
        reason: "group #{group.name} (#{group.slug}) is trashed, #{files} file(s)"
      }
    end)
  end

  defp pointer_key, do: elem(MediaFolders.pointer(), 1)

  # Post folders (`MediaFolders.post_folders?/0`) are never moved by this
  # source — they sit inside their group's folder and travel with it. A
  # trashed post's live Media folder is reported, the same way as a trashed
  # group's: through the pointer its versions hold, once per folder, not
  # when a live post points at it too, not when already reported. A
  # hard-deleted post's versions went with it, and its folder is not
  # traced.
  defp post_orphans(reported) do
    folders =
      from(v in PublishingVersion,
        join: p in PublishingPost,
        on: p.uuid == v.post_uuid,
        join: f in Folder,
        on: fragment("lower(?->>?)", v.data, ^pointer_key()) == type(f.uuid, :string),
        where: not is_nil(p.trashed_at) and is_nil(f.trashed_at),
        where: f.library_uuid == ^Libraries.media_uuid(),
        order_by: [asc: p.inserted_at, asc: p.uuid],
        select: {map(p, [:uuid, :slug]), f}
      )
      |> repo().all()
      |> Enum.reject(fn {_post, folder} -> Map.has_key?(reported, folder.uuid) end)

    claimed = live_post_pointers(Enum.map(folders, fn {_post, folder} -> folder.uuid end))

    folders =
      folders
      |> Enum.reject(fn {_post, folder} -> folder.uuid in claimed end)
      |> Enum.uniq_by(fn {_post, folder} -> folder.uuid end)

    counts = counts(Enum.map(folders, fn {_post, folder} -> folder.uuid end))

    Enum.map(folders, fn {post, folder} ->
      {files, _links} = folder_counts = Map.get(counts, folder.uuid, {0, 0})

      %{
        source: @source,
        kind: :orphan,
        op: :report,
        label: folder.name,
        folder: folder,
        counts: folder_counts,
        reason: "post #{post.slug || post.uuid} is trashed, #{files} file(s)"
      }
    end)
  end

  defp live_post_pointers([]), do: []

  defp live_post_pointers(folder_uuids) do
    from(v in PublishingVersion,
      join: p in PublishingPost,
      on: p.uuid == v.post_uuid,
      where: is_nil(p.trashed_at),
      where: fragment("lower(?->>?)", v.data, ^pointer_key()) in ^folder_uuids,
      select: fragment("lower(?->>?)", v.data, ^pointer_key())
    )
    |> repo().all()
  end

  defp live_group_pointers([]), do: []

  defp live_group_pointers(folder_uuids) do
    from(g in PublishingGroup,
      where: g.status != "trashed",
      where: fragment("lower(?->>?)", g.data, ^pointer_key()) in ^folder_uuids,
      select: fragment("lower(?->>?)", g.data, ^pointer_key())
    )
    |> repo().all()
  end

  # `{files, links}` per folder, as the `Source` contract counts them: every
  # file row homed there (any status) and every link row.
  defp counts([]), do: %{}

  defp counts(folder_uuids) do
    files =
      from(f in StorageFile,
        where: f.folder_uuid in ^folder_uuids,
        group_by: f.folder_uuid,
        select: {f.folder_uuid, count()}
      )
      |> repo().all()
      |> Map.new()

    links =
      from(l in FolderLink,
        where: l.folder_uuid in ^folder_uuids,
        group_by: l.folder_uuid,
        select: {l.folder_uuid, count()}
      )
      |> repo().all()
      |> Map.new()

    Map.new(folder_uuids, &{&1, {Map.get(files, &1, 0), Map.get(links, &1, 0)}})
  end

  # A dry adoption plan: reads only, calls no hook.
  defp unfiled(actor_uuid, _opts) do
    case MediaAdoption.run(actor_uuid) do
      {:ok, %{entries: entries}} -> Enum.flat_map(entries, &unfiled_action/1)
      # Not opted in, or a hook that can't be called — reported by core
      # (parent hook) or by `name_hook_problems/1` (name hook).
      {:error, _reason} -> []
    end
  end

  defp unfiled_action(%{adopt: [], link: [], rehome: [], relocate: false}), do: []

  defp unfiled_action(entry) do
    count = length(entry.adopt) + length(entry.rehome) + length(entry.link)
    moved = if entry.relocate, do: "its folder is under another group's; ", else: ""

    [
      %{
        source: @source,
        kind: :unfiled,
        label: "#{entry.kind} #{entry.name} (#{entry.slug})",
        op: :report,
        reason:
          "#{moved}#{count} file(s) its posts use are outside its media folder " <>
            "(#{length(entry.adopt)} to adopt, #{length(entry.rehome)} to move down, " <>
            "#{length(entry.link)} to link) — run " <>
            "`mix phoenix_kit_publishing.media.adopt --apply` " <>
            "(or PhoenixKit.Modules.Publishing.MediaAdoption.run(actor_uuid, apply?: true))"
      }
    ]
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
