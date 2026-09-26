defmodule PhoenixKit.Modules.Publishing.MediaFolders do
  @moduledoc """
  One media folder per publishing group — and, optionally, one per post
  inside it — on core's per-record folder convention
  (`PhoenixKit.Modules.Storage.ResourceFolders`).

  ## Opt-in

  Nothing happens until the host configures the parent hook: no folder is
  created and a picked file stays where it is. The module ships a
  ready-made pair — a `Publishing` folder at the root, one folder per
  group inside it, named after the group:

      config :phoenix_kit_publishing,
        attachments_parent_folder: {PhoenixKit.Modules.Publishing.MediaFolders, :module_folder},
        attachments_folder_name: {PhoenixKit.Modules.Publishing.MediaFolders, :folder_name}

  Either key can name the host's own function instead. The parent hook is
  called as `fun(:group, actor_uuid, group)` (or `fun(:group, actor_uuid)`)
  and answers `{:ok, folder_uuid}`, or `nil` for the media root; the name
  hook as `fun(subject, actor_uuid)` — a `%PublishingGroup{}`, or with post
  folders a `%PublishingPost{}` — answering `{:ok, name}`, or `nil` for the
  deterministic `publishing-group-<uuid>` / `publishing-post-<uuid>`.

  ## Post folders

  A second key puts each post's files in a folder of its own inside its
  group's, `Publishing/<group>/<post>`:

      config :phoenix_kit_publishing, :post_media_folders, true

  The ready-made name hook calls a post's folder after its slug (a
  timestamp post: its date and time). Without the key nothing about posts
  changes. A post folder's parent is always its group's folder, never a
  hook's answer.

  ## Pointers

  A group keeps its folder's uuid in `data["media_folder_uuid"]`; a post,
  which has no JSONB column of its own, in `data["media_folder_uuid"]` on
  each of its versions (a new version copies it); the ready-made parent
  hook keeps the module folder's in the `publishing_media_folder_uuid`
  setting — so a folder renamed or moved in the media browser, and a post
  or group renamed later, keep the folder they have. No migration.

  ## Filing

  `file_for_group/3` and `file_for_post/4` put files into a folder by
  core's attach rule: a file with no home is adopted, a file homed
  elsewhere is linked (it keeps its home), a file already there is left
  alone — and, for a post folder, a file homed in its group's own folder
  moves down into it. The editor calls `file_for_post/4` for every file
  chosen in the media picker; files that predate the configuration are
  filed by `PhoenixKit.Modules.Publishing.MediaAdoption`. Moving a group
  folder after the host changes its hooks is the core media reorganizer's
  job (`PhoenixKit.Modules.Publishing.MediaReorganizer`); post folders
  travel with their group's.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Modules.Storage.FolderLink
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKit.Settings

  @app :phoenix_kit_publishing
  @pointer {:data, "media_folder_uuid"}
  @prefix "publishing-group-"
  @post_prefix "publishing-post-"
  @module_folder_name "Publishing"
  @module_folder_setting "publishing_media_folder_uuid"

  @doc "The OTP app whose hooks decide where group folders go."
  @spec app() :: atom()
  def app, do: @app

  @doc "Where a group keeps its folder uuid (`t:ResourceFolders.pointer/0`)."
  @spec pointer() :: ResourceFolders.pointer()
  def pointer, do: @pointer

  @doc "The prefix of a group folder's deterministic name."
  @spec folder_prefix() :: String.t()
  def folder_prefix, do: @prefix

  @doc "Whether the host has opted in (configured the parent hook)."
  @spec enabled?() :: boolean()
  def enabled?, do: ResourceFolders.hook_configured?(@app)

  @doc "The folder name a group falls back to: `publishing-group-<uuid>`."
  @spec deterministic_name(PublishingGroup.t()) :: String.t()
  def deterministic_name(%PublishingGroup{uuid: uuid}), do: @prefix <> uuid

  # ── Ready-made hooks ───────────────────────────────────────────────

  @doc """
  Parent hook: the module's `Publishing` folder at the root of the site's
  media library (Media), created on first use and remembered by uuid, so it
  may be renamed or moved. A folder of that name in any other library — a
  person's private one — is never taken for it.
  """
  @spec module_folder(atom(), String.t() | nil, term()) :: {:ok, String.t()} | {:error, term()}
  def module_folder(_kind, actor_uuid, _subject) do
    case media_folder(Settings.get_setting(@module_folder_setting)) do
      %Folder{uuid: uuid} ->
        {:ok, uuid}

      nil ->
        with {:ok, %Folder{uuid: uuid}} <-
               ResourceFolders.ensure(@module_folder_name, nil, actor_uuid,
                 lookup: &media_root_module_folder/0
               ) do
          remember_module_folder(uuid)
          {:ok, uuid}
        end
    end
  end

  # Core's by-name lookups do not look at the library (`find_under/2` takes
  # the first live folder of that name at the root of ANY library), so the
  # module folder is looked up here, in Media only. A new one is created in
  # Media too: that is where a folder without a library goes.
  defp media_root_module_folder do
    from(f in Folder,
      where: f.name == ^@module_folder_name and is_nil(f.parent_uuid) and is_nil(f.trashed_at),
      where: f.library_uuid == ^Libraries.media_uuid(),
      order_by: [asc: f.inserted_at, asc: f.uuid],
      limit: 1
    )
    |> repo().one()
  end

  defp media_folder(uuid) do
    case ResourceFolders.live_folder(uuid) do
      %Folder{} = folder -> if in_media?(folder), do: folder
      nil -> nil
    end
  end

  defp in_media?(%Folder{library_uuid: library_uuid}), do: Libraries.media?(library_uuid)

  defp remember_module_folder(uuid) do
    case Settings.update_setting(@module_folder_setting, uuid) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Publishing] could not remember the media folder: " <>
            ResourceFolders.describe_failure(reason)
        )
    end
  end

  @doc """
  Name hook: a group's folder is called after the group; a post's (with
  post folders on) after its slug, or — a timestamp post has none — its
  date and time, `2026-09-25 14:30`, the part of its URL that never
  changes. The pointer keeps the folder when either changes later.
  """
  @spec folder_name(term(), String.t() | nil) :: {:ok, String.t()} | nil
  def folder_name(%PublishingGroup{name: name}, _actor_uuid)
      when is_binary(name) and name != "",
      do: {:ok, name}

  def folder_name(%PublishingPost{slug: slug}, _actor_uuid) when is_binary(slug) and slug != "",
    do: {:ok, slug}

  def folder_name(%PublishingPost{post_date: %Date{} = date, post_time: %Time{} = time}, _actor),
    do: {:ok, "#{Date.to_iso8601(date)} #{time |> Time.to_iso8601() |> String.slice(0, 5)}"}

  def folder_name(_subject, _actor_uuid), do: nil

  @doc """
  What is wrong with the configured hooks, without calling them: a key that
  is not a `{module, function}` pair, or names a function that is not
  exported (the parent hook at arity 3 or 2, the name hook at arity 2).
  `[]` when both are fine or unset.
  """
  @spec hook_problems() :: [String.t()]
  def hook_problems do
    [
      hook_problem(:attachments_parent_folder, [3, 2]),
      hook_problem(:attachments_folder_name, [2])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp hook_problem(key, arities) do
    case Application.get_env(@app, key) do
      nil ->
        nil

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        if Code.ensure_loaded?(mod) and Enum.any?(arities, &function_exported?(mod, fun, &1)),
          do: nil,
          else: "#{key}: #{inspect(mod)}.#{fun} is not callable"

      _other ->
        "#{key}: not a {module, function} pair"
    end
  end

  # ── Group folders ──────────────────────────────────────────────────

  @doc """
  The group's folder, found or created under the parent hook's answer, and
  the group's pointer written — see "Claiming a folder" below. A host name
  taken by another group's folder, or refused by core (e.g. too long),
  falls back to the deterministic name. Only folders of the site's media
  library (Media) are ever adopted.

  A failing hook falls back to the media root and the deterministic name,
  logged — an upload never fails on a host hook. With `strict: true` (the
  one-time adoption) a failing hook is `{:error, {:parent_hook | :name_hook,
  reason}}` instead and nothing is created.
  """
  @spec ensure_group_folder(PublishingGroup.t(), String.t() | nil, keyword()) ::
          {:ok, Folder.t()} | {:error, term()}
  def ensure_group_folder(%PublishingGroup{} = group, actor_uuid, opts \\ []) do
    strict? = Keyword.get(opts, :strict, false)

    case media_folder(ResourceFolders.pointer_value(group, @pointer)) do
      %Folder{} = folder ->
        {:ok, folder}

      nil ->
        with {:ok, parent_uuid} <- parent_for(group, actor_uuid, strict?),
             {:ok, host_name} <- name_for(group, actor_uuid, strict?) do
          claim(group_owner(group, parent_uuid, host_name), actor_uuid)
        end
    end
  end

  defp group_owner(group, parent_uuid, host_name) do
    %{
      parent_uuid: parent_uuid,
      host_name: host_name,
      deterministic: deterministic_name(group),
      claimed_by_other?: &claimed_by_other_group?(&1, group),
      read_pointer: fn -> locked_group_pointer(group.uuid) end,
      write_pointer:
        &ResourceFolders.write_pointer(PublishingGroup, group.uuid, @pointer, &1.uuid)
    }
  end

  # `nil` for a group deleted meanwhile: the pointer write then answers
  # `{:error, :not_found}` and the transaction takes the new folder back.
  defp locked_group_pointer(group_uuid) do
    from(g in PublishingGroup,
      where: g.uuid == ^group_uuid,
      lock: "FOR UPDATE",
      select: fragment("?->>?", g.data, ^elem(@pointer, 1))
    )
    |> repo().one()
  end

  # A host name carries no uuid, so two groups can share one; a folder
  # another group points at is never taken. Fails closed.
  defp claimed_by_other_group?(%Folder{uuid: folder_uuid}, %PublishingGroup{uuid: own_uuid}),
    do: ResourceFolders.claimed?(folder_uuid, own_uuid, [{PublishingGroup, @pointer}])

  # ── Post folders ───────────────────────────────────────────────────

  @doc """
  Whether posts get a folder of their own inside their group's folder:
  the parent hook (`enabled?/0`) and `config :phoenix_kit_publishing,
  :post_media_folders, true`.
  """
  @spec post_folders?() :: boolean()
  def post_folders?, do: enabled?() and Application.get_env(@app, :post_media_folders) == true

  @doc "A post folder's fallback name: `publishing-post-<uuid>`."
  @spec post_deterministic_name(PublishingPost.t()) :: String.t()
  def post_deterministic_name(%PublishingPost{uuid: uuid}), do: @post_prefix <> uuid

  @doc "The prefix of a post folder's deterministic name."
  @spec post_folder_prefix() :: String.t()
  def post_folder_prefix, do: @post_prefix

  @doc """
  The live Media folder a post points at, or `nil`. A post has no JSONB of
  its own: the pointer is `data["media_folder_uuid"]` on each of its
  versions (a new version copies it), newest version first.
  """
  @spec post_folder(String.t()) :: Folder.t() | nil
  def post_folder(post_uuid) when is_binary(post_uuid) do
    post_uuid
    |> post_pointer_query()
    |> repo().all()
    # Every version carries the same pointer once filed: one lookup, not one
    # per version.
    |> Enum.uniq()
    |> Enum.find_value(&media_folder/1)
  end

  @doc """
  The post's folder inside `group_folder`, found or created, and the
  pointer written on every version of the post — see "Claiming a folder".
  Named by the name hook (the ready-made one: the slug, or the date and
  time of a timestamp post); a name taken by another post's folder, or
  refused by core, falls back to `publishing-post-<uuid>`. A pointer that
  already names a live Media folder wins, wherever that folder is — a
  post renamed later keeps its folder. `strict: true` as for groups.
  """
  @spec ensure_post_folder(PublishingPost.t(), Folder.t(), String.t() | nil, keyword()) ::
          {:ok, Folder.t()} | {:error, term()}
  def ensure_post_folder(
        %PublishingPost{} = post,
        %Folder{} = group_folder,
        actor_uuid,
        opts \\ []
      ) do
    case post_folder(post.uuid) do
      %Folder{} = folder ->
        {:ok, folder}

      nil ->
        with {:ok, host_name} <- name_for(post, actor_uuid, Keyword.get(opts, :strict, false)) do
          claim(post_owner(post, group_folder.uuid, host_name), actor_uuid)
        end
    end
  end

  defp post_owner(post, parent_uuid, host_name) do
    %{
      parent_uuid: parent_uuid,
      host_name: host_name,
      deterministic: post_deterministic_name(post),
      claimed_by_other?: &claimed_by_other_post?(&1, post),
      read_pointer: fn -> locked_post_pointer(post.uuid) end,
      write_pointer: &write_post_pointer(post.uuid, &1.uuid)
    }
  end

  defp post_pointer_query(post_uuid) do
    from(v in PublishingVersion,
      where: v.post_uuid == ^post_uuid,
      where: not is_nil(fragment("?->>?", v.data, ^elem(@pointer, 1))),
      order_by: [desc: v.version_number],
      select: fragment("?->>?", v.data, ^elem(@pointer, 1))
    )
  end

  # The post row first — the lock a post save takes before it rewrites a
  # version's `data` — then the pointer as the versions hold it now.
  defp locked_post_pointer(post_uuid) do
    from(p in PublishingPost, where: p.uuid == ^post_uuid, lock: "FOR UPDATE", select: p.uuid)
    |> repo().one()

    post_uuid |> post_pointer_query() |> repo().all() |> Enum.find(&media_folder/1)
  end

  # One key on every version, no changeset; `{:error, :not_found}` for a
  # post deleted meanwhile (its versions went with it).
  defp write_post_pointer(post_uuid, folder_uuid) do
    key = elem(@pointer, 1)

    from(v in PublishingVersion,
      where: v.post_uuid == ^post_uuid,
      update: [
        set: [
          data:
            fragment(
              "jsonb_set(coalesce(?, '{}'::jsonb), ARRAY[?]::text[], to_jsonb(?::text))",
              v.data,
              ^key,
              ^folder_uuid
            )
        ]
      ]
    )
    |> repo().update_all([])
    |> case do
      {0, _} -> {:error, :not_found}
      {_n, _} -> :ok
    end
  end

  # Another post's version points at the folder. Fails closed.
  defp claimed_by_other_post?(%Folder{uuid: folder_uuid}, %PublishingPost{uuid: own_uuid}) do
    from(v in PublishingVersion,
      where: v.post_uuid != ^own_uuid,
      where: fragment("lower(?->>?)", v.data, ^elem(@pointer, 1)) == ^String.downcase(folder_uuid)
    )
    |> repo().exists?()
  rescue
    _error -> true
  end

  # ── Claiming a folder ──────────────────────────────────────────────
  #
  # Core's by-name lookups (`ResourceFolders.resolve/1`, and the "is the
  # name taken" check inside `ensure/4`) do not look at the library and
  # take the first row without an order, so at the root — a hook that
  # answers `nil` — a person's private `News` could be adopted or could push
  # the owner onto its fallback name. The lookup, the name choice and the
  # claim are therefore made here, in Media, oldest first, in ONE
  # transaction: first the name locks core's own `ensure/4` and the
  # reorganizer's pointer back-fill take — `{parent, host name}`, so every
  # owner claiming the same host name (group names are not unique) queues
  # on it, and `{parent, deterministic name}`, both in sorted order — then
  # the owner's row, under which its pointer is re-read: a folder claimed
  # since is used as is. `ensure/4` is only asked to create; a name core
  # refuses (taken, too long) falls back to the deterministic one, which
  # cannot collide. The owner is the map `group_owner/3` / `post_owner/3`
  # build.
  defp claim(owner, actor_uuid) do
    host = if owner.host_name != owner.deterministic, do: owner.host_name
    owner = Map.put(owner, :host, host)

    safely(fn -> transact(fn -> claim_locked(owner, actor_uuid) end) end)
  end

  # `fun`'s `{:ok, value}` commits, its `{:error, reason}` rolls back.
  defp transact(fun) do
    repo().transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp claim_locked(owner, actor_uuid) do
    [owner.host, owner.deterministic]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> Enum.each(&ResourceFolders.lock_name(owner.parent_uuid, &1))

    case media_folder(owner.read_pointer.()) do
      %Folder{} = folder -> {:ok, folder}
      nil -> create_and_point(owner, actor_uuid)
    end
  end

  defp create_and_point(owner, actor_uuid) do
    with {:ok, folder} <- find_or_create(owner, actor_uuid),
         :ok <- owner.write_pointer.(folder) do
      {:ok, folder}
    end
  end

  defp find_or_create(owner, actor_uuid) do
    case find_owner_folder(owner) do
      %Folder{} = folder ->
        {:ok, folder}

      nil ->
        # Under the host-name lock, a live Media folder of that name that the
        # lookup did not adopt belongs to another owner.
        name =
          if owner.host && is_nil(media_folder_named(owner.host, owner.parent_uuid)),
            do: owner.host,
            else: owner.deterministic

        create(name, owner, actor_uuid)
    end
  end

  # `ensure/4` inserts under a savepoint inside a transaction, so a refused
  # name leaves this transaction usable for the deterministic retry.
  defp create(name, owner, actor_uuid) do
    lookup = fn -> find_owner_folder(owner) end
    deterministic = owner.deterministic

    case ResourceFolders.ensure(name, owner.parent_uuid, actor_uuid, lookup: lookup) do
      {:error, %Ecto.Changeset{errors: errors}} = error when name != deterministic ->
        if Keyword.has_key?(errors, :name),
          do:
            ResourceFolders.ensure(deterministic, owner.parent_uuid, actor_uuid, lookup: lookup),
          else: error

      result ->
        result
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # `ResourceFolders.resolve/1`'s order, in Media only: the host name
  # directly under the parent unless another owner points at that folder,
  # then the deterministic name under the parent, at the root, anywhere.
  defp find_owner_folder(owner) do
    host_folder(owner) || deterministic_folder(owner.deterministic, owner.parent_uuid)
  end

  defp host_folder(%{host: host} = owner) when is_binary(host) do
    case media_folder_named(host, owner.parent_uuid) do
      %Folder{} = folder -> if owner.claimed_by_other?.(folder), do: nil, else: folder
      nil -> nil
    end
  end

  defp host_folder(_owner), do: nil

  defp media_folder_named(name, parent_uuid) do
    media_folders_named(name)
    |> where([f], ^directly_under(parent_uuid))
    |> limit(1)
    |> repo().one()
  end

  defp deterministic_folder(name, parent_uuid) do
    name
    |> media_folders_named()
    |> repo().all()
    |> Enum.min_by(&place_rank(&1, parent_uuid), fn -> nil end)
  end

  defp media_folders_named(name) do
    from(f in Folder,
      where: f.name == ^name and is_nil(f.trashed_at),
      where: f.library_uuid == ^Libraries.media_uuid(),
      order_by: [asc: f.inserted_at, asc: f.uuid]
    )
  end

  defp directly_under(nil), do: dynamic([f], is_nil(f.parent_uuid))
  defp directly_under(parent_uuid), do: dynamic([f], f.parent_uuid == ^parent_uuid)

  # Rows come oldest first and `Enum.min_by/3` keeps the first of equal
  # ranks: under the parent, then at the root, then anywhere.
  defp place_rank(%Folder{parent_uuid: parent}, parent), do: 0
  defp place_rank(%Folder{parent_uuid: nil}, _parent), do: 1
  defp place_rank(%Folder{}, _parent), do: 2

  defp parent_for(group, actor_uuid, false),
    do: {:ok, ResourceFolders.parent_uuid(@app, :group, actor_uuid, group)}

  defp parent_for(group, actor_uuid, true) do
    case ResourceFolders.parent_hook(@app, :group, actor_uuid, group) do
      {:ok, parent_uuid} -> {:ok, parent_uuid}
      :unconfigured -> {:ok, nil}
      {:error, reason} -> {:error, {:parent_hook, reason}}
    end
  end

  defp name_for(subject, actor_uuid, false),
    do: {:ok, ResourceFolders.host_name(@app, subject, actor_uuid)}

  defp name_for(subject, actor_uuid, true) do
    case ResourceFolders.name_hook(@app, subject, actor_uuid) do
      {:ok, name} -> {:ok, name}
      :unconfigured -> {:ok, nil}
      {:error, reason} -> {:error, {:name_hook, reason}}
    end
  end

  # ── Filing files ───────────────────────────────────────────────────

  @doc """
  Puts `file_uuids` into the folder of the group `slug` (see the moduledoc's
  "Filing"). `:disabled` on a host that has not opted in — nothing is read
  or written then. A trashed group is `{:error, :group_not_active}` (the
  one-time adoption skips those too), and a system-managed file is left
  alone. Never raises; a file that could not be filed is named in
  `{:error, [{file_uuid, reason}]}` and logged.
  """
  @spec file_for_group(String.t(), [String.t()], String.t() | nil) ::
          :ok | :disabled | {:error, term()}
  def file_for_group(slug, file_uuids, actor_uuid) when is_list(file_uuids),
    do: file_for_post(slug, nil, file_uuids, actor_uuid)

  @doc """
  `file_for_group/3` for the files of one post: with post folders on
  (`post_folders?/0`) and a saved, live post of that group, the files go
  into the post's folder inside the group's — a file homed in the group's
  own folder moves down into it (it was filed there before post folders,
  or before the post was saved), any other file follows core's attach rule.
  Otherwise (post folders off, `post_uuid` nil, a trashed post) the group's
  folder, exactly as `file_for_group/3`.
  """
  @spec file_for_post(String.t(), String.t() | nil, [String.t()], String.t() | nil) ::
          :ok | :disabled | {:error, term()}
  def file_for_post(slug, post_uuid, file_uuids, actor_uuid) when is_list(file_uuids) do
    if enabled?() do
      guarded(fn -> do_file(slug, post_uuid, Enum.uniq(file_uuids), actor_uuid) end)
    else
      :disabled
    end
  end

  defp do_file(_slug, _post_uuid, [], _actor_uuid), do: :ok

  defp do_file(slug, post_uuid, file_uuids, actor_uuid) do
    with %PublishingGroup{status: "active"} = group <- group_by_slug(slug),
         {:ok, %Folder{} = group_folder} <- ensure_group_folder(group, actor_uuid),
         {:ok, %Folder{uuid: folder_uuid}, rehome_from} <-
           target_folder(group, group_folder, post_uuid, actor_uuid) do
      file_uuids
      |> without_system_managed()
      |> Enum.flat_map(&attach(&1, folder_uuid, rehome_from))
      |> case do
        [] -> :ok
        failures -> {:error, failures}
      end
    else
      nil ->
        not_filed(slug, :group_not_found)

      %PublishingGroup{} ->
        not_filed(slug, :group_not_active)

      {:error, reason} = error ->
        Logger.warning(
          "[Publishing] media folder for group #{inspect(slug)} unavailable: " <>
            ResourceFolders.describe_failure(reason)
        )

        error
    end
  end

  # The folder the files go to, and the folder a file may be moved OUT of
  # (the group's own, for a post folder; none otherwise).
  defp target_folder(group, group_folder, post_uuid, actor_uuid) do
    case post_folders?() && live_post(group, post_uuid) do
      %PublishingPost{} = post ->
        with {:ok, folder} <- ensure_post_folder(post, group_folder, actor_uuid) do
          {:ok, folder, group_folder.uuid}
        end

      _no_post_folder ->
        {:ok, group_folder, nil}
    end
  end

  defp live_post(%PublishingGroup{uuid: group_uuid}, post_uuid) when is_binary(post_uuid) do
    case cast(post_uuid) do
      [uuid] ->
        from(p in PublishingPost,
          where: p.uuid == ^uuid and p.group_uuid == ^group_uuid and is_nil(p.trashed_at)
        )
        |> repo().one()

      [] ->
        nil
    end
  end

  defp live_post(_group, _post_uuid), do: nil

  @doc """
  Moves a file whose home is `from_folder_uuid` into `folder_uuid` — only
  while it is still homed there (compare-and-set, the target folder
  share-locked first, as core's attach takes it); a link it had into
  `folder_uuid` is dropped, it is home now. Anything else — no home, homed
  elsewhere, moved meanwhile — is core's attach rule
  (`ResourceFolders.attach/2`). `{:ok, :rehomed | :adopted | :linked |
  :already_attached}` or `{:error, reason}`.
  """
  @spec file_into(String.t(), String.t(), String.t() | nil) ::
          {:ok, atom()} | {:error, term()}
  def file_into(file_uuid, folder_uuid, from_folder_uuid \\ nil)

  def file_into(file_uuid, folder_uuid, from_folder_uuid)
      when is_binary(from_folder_uuid) and from_folder_uuid != folder_uuid do
    rehomed =
      safely(fn -> transact(fn -> rehome(file_uuid, folder_uuid, from_folder_uuid) end) end)

    case rehomed do
      {:ok, :rehomed} -> {:ok, :rehomed}
      {:ok, :not_home} -> ResourceFolders.attach(file_uuid, folder_uuid)
      {:error, reason} -> {:error, reason}
    end
  end

  def file_into(file_uuid, folder_uuid, _from_folder_uuid),
    do: ResourceFolders.attach(file_uuid, folder_uuid)

  defp rehome(file_uuid, folder_uuid, from_folder_uuid) do
    live_target =
      from(f in Folder,
        where: f.uuid == ^folder_uuid and is_nil(f.trashed_at),
        lock: "FOR SHARE",
        select: f.uuid
      )
      |> repo().one()

    with [uuid] <- cast(file_uuid),
         true <- is_binary(live_target) do
      moved =
        from(f in StorageFile,
          where: f.uuid == ^uuid and f.folder_uuid == ^from_folder_uuid and f.status != "trashed"
        )
        |> repo().update_all(
          set: [folder_uuid: folder_uuid, updated_at: DateTime.utc_now(:second)]
        )

      case moved do
        {1, _} ->
          from(l in FolderLink, where: l.folder_uuid == ^folder_uuid and l.file_uuid == ^uuid)
          |> repo().delete_all()

          {:ok, :rehomed}

        {0, _} ->
          {:ok, :not_home}
      end
    else
      _ -> {:ok, :not_home}
    end
  end

  # Tile chunks and an edited image's hidden original are core's own
  # bookkeeping; the picker never offers them, and a forged event must not
  # file one either.
  defp without_system_managed(file_uuids) do
    uuids = Enum.flat_map(file_uuids, &cast/1)

    managed =
      from(f in StorageFile, where: f.uuid in ^uuids and f.system_managed, select: f.uuid)
      |> repo().all()

    Enum.reject(file_uuids, fn uuid -> Enum.any?(cast(uuid), &(&1 in managed)) end)
  end

  defp not_filed(slug, reason) do
    Logger.warning("[Publishing] nothing filed for group #{inspect(slug)}: #{inspect(reason)}")
    {:error, reason}
  end

  defp attach(file_uuid, folder_uuid, rehome_from) do
    case file_into(file_uuid, folder_uuid, rehome_from) do
      {:ok, _outcome} ->
        []

      {:error, reason} ->
        Logger.warning(
          "[Publishing] file #{inspect(file_uuid)} not filed into #{folder_uuid}: " <>
            ResourceFolders.describe_failure(reason)
        )

        [{file_uuid, reason}]
    end
  end

  defp group_by_slug(slug) when is_binary(slug), do: DBStorage.get_group_by_slug(slug)
  defp group_by_slug(_slug), do: nil

  # The editor calls this from a task: a database that raises or a pool that
  # exits must cost the filing, never anything else.
  defp guarded(fun) do
    fun.()
  rescue
    error -> failed(error)
  catch
    :exit, reason -> failed({:exit, reason})
  end

  defp failed(reason) do
    Logger.warning(
      "[Publishing] filing into a group folder failed: " <>
        ResourceFolders.describe_failure(reason)
    )

    {:error, reason}
  end

  defp cast(value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> [String.downcase(uuid)]
      :error -> []
    end
  end

  defp cast(_value), do: []

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
