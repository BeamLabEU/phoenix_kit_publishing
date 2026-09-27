defmodule PhoenixKit.Modules.Publishing.MediaFoldersTest do
  use PhoenixKitPublishing.DataCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKitPublishing.Test.MediaHooks, as: Hooks

  @app :phoenix_kit_publishing

  setup do
    on_exit(fn ->
      Application.delete_env(@app, :attachments_parent_folder)
      Application.delete_env(@app, :attachments_folder_name)
    end)
  end

  defp configure_default_hooks do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :folder_name})
  end

  defp live_folders_named(name) do
    Repo.all(from(f in Folder, where: f.name == ^name and is_nil(f.trashed_at)))
  end

  describe "enabled?/0" do
    test "is off until the host configures a parent hook" do
      refute MediaFolders.enabled?()

      configure_default_hooks()
      assert MediaFolders.enabled?()
    end
  end

  describe "module_folder/3 (the ready-made parent hook)" do
    test "creates one \"Publishing\" folder at the root and keeps answering it" do
      assert {:ok, uuid} = MediaFolders.module_folder(:group, nil, nil)
      assert {:ok, ^uuid} = MediaFolders.module_folder(:group, nil, nil)

      assert [%Folder{uuid: ^uuid, parent_uuid: nil}] = live_folders_named("Publishing")
    end

    test "follows its folder after someone renames and moves it" do
      {:ok, uuid} = MediaFolders.module_folder(:group, nil, nil)
      site = folder!("Site")

      {:ok, _} = Storage.update_folder(Repo.get!(Folder, uuid), %{name: "Публикации"})
      {:ok, _} = Storage.update_folder(Repo.get!(Folder, uuid), %{parent_uuid: site.uuid})

      assert {:ok, ^uuid} = MediaFolders.module_folder(:group, nil, nil)
      assert live_folders_named("Publishing") == []
    end

    test "never takes a \"Publishing\" folder of another library" do
      private = library!()
      theirs = folder!("Publishing", nil, %{library_uuid: private.uuid})

      assert {:ok, uuid} = MediaFolders.module_folder(:group, nil, nil)

      assert uuid != theirs.uuid
      assert to_string(Repo.get!(Folder, uuid).library_uuid) == Libraries.media_uuid()
    end

    test "ignores a remembered folder that is not in Media" do
      theirs = folder!("Publishing", nil, %{library_uuid: library!().uuid})
      {:ok, _} = PhoenixKit.Settings.update_setting("publishing_media_folder_uuid", theirs.uuid)

      assert {:ok, uuid} = MediaFolders.module_folder(:group, nil, nil)
      assert uuid != theirs.uuid
    end

    test "makes a new one when its folder was trashed" do
      {:ok, uuid} = MediaFolders.module_folder(:group, nil, nil)
      {:ok, _} = Storage.trash_folder(Repo.get!(Folder, uuid))

      assert {:ok, new_uuid} = MediaFolders.module_folder(:group, nil, nil)
      assert new_uuid != uuid
      assert [%Folder{uuid: ^new_uuid}] = live_folders_named("Publishing")
    end
  end

  describe "folder_name/2 (the ready-made name hook)" do
    test "names the folder after the group" do
      assert MediaFolders.folder_name(group!("News"), nil) == {:ok, "News"}
    end

    test "has no name for anything that is not a saved group" do
      assert MediaFolders.folder_name(%{name: "News"}, nil) == nil
    end
  end

  describe "ensure_group_folder/2" do
    test "creates the group's folder under the module folder and points the group at it" do
      configure_default_hooks()
      group = group!("News")

      assert {:ok, %Folder{name: "News", parent_uuid: parent} = folder} =
               MediaFolders.ensure_group_folder(group, nil)

      assert [%Folder{uuid: ^parent}] = live_folders_named("Publishing")
      assert reload(group).data["media_folder_uuid"] == folder.uuid
    end

    test "keeps the pointed folder, whatever it is called now" do
      configure_default_hooks()
      group = group!("News")
      {:ok, folder} = MediaFolders.ensure_group_folder(group, nil)
      {:ok, _} = Storage.update_folder(folder, %{name: "Новости"})

      assert {:ok, %Folder{uuid: uuid, name: "Новости"}} =
               MediaFolders.ensure_group_folder(reload(group), nil)

      assert uuid == folder.uuid
    end

    test "leaves another group's same-named folder alone" do
      configure_default_hooks()
      first = group!("News")
      second = group!("News")

      {:ok, first_folder} = MediaFolders.ensure_group_folder(first, nil)
      {:ok, second_folder} = MediaFolders.ensure_group_folder(second, nil)

      assert second_folder.uuid != first_folder.uuid
      assert second_folder.name == "publishing-group-" <> second.uuid
    end

    test "without a name hook the folder gets the deterministic name" do
      Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
      group = group!("News")

      assert {:ok, %Folder{name: name}} = MediaFolders.ensure_group_folder(group, nil)
      assert name == "publishing-group-" <> group.uuid
    end
  end

  describe "ensure_group_folder/3 and failing or unusual hooks" do
    test "at the root, another library's same-named folders neither get adopted nor take the name" do
      Application.put_env(@app, :attachments_parent_folder, {Hooks, :root})
      Application.put_env(@app, :attachments_folder_name, {Hooks, :news})
      theirs = for _ <- 1..2, do: folder!("News", nil, %{library_uuid: library!().uuid})
      group = group!("News")

      assert {:ok, folder} = MediaFolders.ensure_group_folder(group, nil)

      refute folder.uuid in Enum.map(theirs, & &1.uuid)
      assert {folder.name, folder.parent_uuid} == {"News", nil}
      assert to_string(folder.library_uuid) == Libraries.media_uuid()
    end

    test "a group pointing at a folder outside Media gets its own folder in Media" do
      configure_default_hooks()
      theirs = folder!("News", nil, %{library_uuid: library!().uuid})
      group = group!("News", %{data: %{"media_folder_uuid" => theirs.uuid}})

      assert {:ok, folder} = MediaFolders.ensure_group_folder(group, nil)

      assert folder.uuid != theirs.uuid
      assert to_string(folder.library_uuid) == Libraries.media_uuid()
      assert reload(group).data["media_folder_uuid"] == folder.uuid
    end

    test "a host name core refuses (too long) falls back to the deterministic name" do
      Application.put_env(@app, :attachments_parent_folder, {Hooks, :root})
      Application.put_env(@app, :attachments_folder_name, {Hooks, :too_long})
      group = group!("News")

      assert {:ok, %Folder{name: name}} = MediaFolders.ensure_group_folder(group, nil)
      assert name == "publishing-group-" <> group.uuid
      assert reload(group).data["media_folder_uuid"] != nil
    end

    test "every claimant of a host name queues on core's {parent, name} lock" do
      Application.put_env(@app, :attachments_parent_folder, {Hooks, :root})
      Application.put_env(@app, :attachments_folder_name, {Hooks, :news})
      group = group!("News")
      # An unclaimed "News" already there: the claim adopts it, and must do
      # so under the host-name lock, not only the deterministic one.
      news = folder!("News")

      # A second connection holds the lock core's ensure/4 and the
      # reorganizer's back-fill take for "News" at the root.
      {:ok, other} =
        Repo.config()
        |> Keyword.take([:hostname, :port, :username, :password, :database])
        |> Postgrex.start_link()

      key = ResourceFolders.name_lock_key(nil, "News")
      Postgrex.query!(other, "SELECT pg_advisory_lock(hashtext($1))", [key])

      task = Task.async(fn -> MediaFolders.ensure_group_folder(group, nil) end)
      assert Task.yield(task, 300) == nil

      Postgrex.query!(other, "SELECT pg_advisory_unlock(hashtext($1))", [key])
      assert {:ok, {:ok, %Folder{uuid: uuid}}} = Task.yield(task, 5_000)
      assert uuid == news.uuid
      GenServer.stop(other)
    end

    test "a group's claim also queues on the lock of its deterministic name" do
      Application.put_env(@app, :attachments_parent_folder, {Hooks, :root})
      group = group!("News")

      {:ok, other} =
        Repo.config()
        |> Keyword.take([:hostname, :port, :username, :password, :database])
        |> Postgrex.start_link()

      key = ResourceFolders.name_lock_key(nil, "publishing-group-" <> group.uuid)
      Postgrex.query!(other, "SELECT pg_advisory_lock(hashtext($1))", [key])

      task = Task.async(fn -> MediaFolders.ensure_group_folder(group, nil) end)
      assert Task.yield(task, 300) == nil

      Postgrex.query!(other, "SELECT pg_advisory_unlock(hashtext($1))", [key])
      assert {:ok, {:ok, %Folder{}}} = Task.yield(task, 5_000)
      GenServer.stop(other)
    end

    test "a group deleted meanwhile leaves no folder behind" do
      configure_default_hooks()
      group = group!("News")
      Repo.delete!(group)

      assert MediaFolders.ensure_group_folder(group, nil) == {:error, :not_found}
      assert live_folders_named("News") == []
    end

    test "a pointer written since the group was loaded is used, not overwritten" do
      configure_default_hooks()
      stale = group!("News")
      {:ok, current} = MediaFolders.ensure_group_folder(stale, nil)
      # Renamed since: no lookup by name finds it; only the pointer does.
      {:ok, _} = Storage.update_folder(current, %{name: "Новости"})

      assert {:ok, %Folder{uuid: uuid}} = MediaFolders.ensure_group_folder(stale, nil)
      assert uuid == current.uuid
      assert reload(stale).data["media_folder_uuid"] == current.uuid
    end

    test "strict: a raising parent hook is an error and creates nothing" do
      Application.put_env(@app, :attachments_parent_folder, {Hooks, :boom})
      group = group!("News")

      assert {:error, {:parent_hook, %RuntimeError{}}} =
               MediaFolders.ensure_group_folder(group, nil, strict: true)

      assert Repo.aggregate(Folder, :count) == 0
      assert reload(group).data["media_folder_uuid"] == nil
    end

    test "not strict (an upload): a raising parent hook falls back to the root" do
      Application.put_env(@app, :attachments_parent_folder, {Hooks, :boom})
      group = group!("News")

      assert {:ok, %Folder{parent_uuid: nil}} = MediaFolders.ensure_group_folder(group, nil)
    end
  end

  describe "hook_problems/0" do
    test "names a hook that is not a pair or not exported, without calling anything" do
      assert MediaFolders.hook_problems() == []

      Application.put_env(@app, :attachments_parent_folder, {Hooks, :no_such_function})
      Application.put_env(@app, :attachments_folder_name, "News")

      assert [parent, name] = MediaFolders.hook_problems()
      assert parent =~ "attachments_parent_folder"
      assert parent =~ "not callable"
      assert name =~ "attachments_folder_name"

      configure_default_hooks()
      assert MediaFolders.hook_problems() == []
    end
  end

  describe "file_for_group/3" do
    test "does nothing on a host without a parent hook" do
      group = group!("News")
      file = file!()

      assert MediaFolders.file_for_group(group.slug, [file.uuid], nil) == :disabled
      assert reload(file).folder_uuid == nil
      assert live_folders_named("Publishing") == []
    end

    test "adopts a file with no home into the group's folder" do
      configure_default_hooks()
      group = group!("News")
      file = file!()

      assert MediaFolders.file_for_group(group.slug, [file.uuid], nil) == :ok

      folder_uuid = reload(group).data["media_folder_uuid"]
      assert reload(file).folder_uuid == folder_uuid
    end

    test "links a file homed elsewhere and leaves its home as it was" do
      configure_default_hooks()
      group = group!("News")
      elsewhere = folder!("Brand assets")
      file = file!(%{folder_uuid: elsewhere.uuid})

      assert MediaFolders.file_for_group(group.slug, [file.uuid], nil) == :ok

      folder_uuid = reload(group).data["media_folder_uuid"]
      assert reload(file).folder_uuid == elsewhere.uuid
      assert linked?(file, folder_uuid)
    end

    test "reports a file it cannot take instead of raising" do
      configure_default_hooks()
      group = group!("News")
      trashed = file!(%{status: "trashed", trashed_at: DateTime.utc_now(:second)})

      assert {:error, [{uuid, :file_trashed}]} =
               MediaFolders.file_for_group(group.slug, [trashed.uuid], nil)

      assert uuid == trashed.uuid
      assert reload(trashed).folder_uuid == nil
    end

    # The picker browses Media only, so another library's file can only
    # arrive as a forged pick — refused like any other, but not an
    # operator's problem: debug, not warning (the one-time adoption skips
    # the same case silently).
    test "refuses another library's file quietly — a forged pick is reported, not warned about" do
      configure_default_hooks()
      group = group!("News")
      theirs = file!(%{library_uuid: library!().uuid})

      warnings =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert {:error, [{uuid, :other_library}]} =
                   MediaFolders.file_for_group(group.slug, [theirs.uuid], nil)

          assert uuid == theirs.uuid
        end)

      refute warnings =~ "not filed into"
      assert reload(theirs).folder_uuid == nil

      # Still said, at debug — a downgrade, not a deletion. The suite runs
      # at :warning, so the level is lowered for this one call and put back.
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      debug =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          MediaFolders.file_for_group(group.slug, [theirs.uuid], nil)
        end)

      Logger.configure(level: previous)

      assert debug =~ "#{inspect(theirs.uuid)} not filed into"
      assert debug =~ "another library"
    end

    test "files nothing for a trashed group" do
      configure_default_hooks()
      group = group!("Old", %{status: "trashed"})
      file = file!()

      assert MediaFolders.file_for_group(group.slug, [file.uuid], nil) ==
               {:error, :group_not_active}

      assert reload(file).folder_uuid == nil
      assert live_folders_named("Publishing") == []
    end

    test "leaves a system-managed file alone" do
      configure_default_hooks()
      group = group!("News")
      managed = file!(%{system_managed: true})
      regular = file!()

      assert MediaFolders.file_for_group(group.slug, [managed.uuid, regular.uuid], nil) == :ok

      assert reload(managed).folder_uuid == nil
      assert reload(regular).folder_uuid != nil
    end

    test "answers an unknown group without creating anything" do
      configure_default_hooks()

      assert MediaFolders.file_for_group("no-such-group", [file!().uuid], nil) ==
               {:error, :group_not_found}

      assert live_folders_named("Publishing") == []
    end
  end
end
