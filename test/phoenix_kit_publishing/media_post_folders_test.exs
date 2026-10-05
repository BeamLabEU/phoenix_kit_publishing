defmodule PhoenixKit.Modules.Publishing.MediaPostFoldersTest do
  @moduledoc """
  Post folders: `Publishing/<group>/<post>`, on with
  `config :phoenix_kit_publishing, :post_media_folders, true` on top of the
  group folders' hooks. The pointer lives on every version of the post.
  """

  use PhoenixKitPublishing.DataCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.MediaAdoption
  alias PhoenixKit.Modules.Publishing.MediaFolders
  alias PhoenixKit.Modules.Publishing.MediaReorganizer
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Modules.Storage.Reorganizer
  alias PhoenixKitPublishing.Test.MediaHooks, as: Hooks

  @app :phoenix_kit_publishing

  setup do
    Application.put_env(@app, :attachments_parent_folder, {MediaFolders, :module_folder})
    Application.put_env(@app, :attachments_folder_name, {MediaFolders, :folder_name})
    Application.put_env(@app, :post_media_folders, true)

    on_exit(fn ->
      for key <- [:attachments_parent_folder, :attachments_folder_name, :post_media_folders],
          do: Application.delete_env(@app, key)
    end)
  end

  defp group_folder!(group) do
    {:ok, folder} = MediaFolders.ensure_group_folder(group, nil)
    folder
  end

  defp pointers(post) do
    from(v in PublishingVersion,
      where: v.post_uuid == ^post.uuid,
      select: fragment("?->>'media_folder_uuid'", v.data)
    )
    |> Repo.all()
  end

  defp folder_of(post), do: MediaFolders.post_folder(post.uuid)

  defp entry(report, post), do: Enum.find(report.entries, &(&1.post && &1.post.uuid == post.uuid))

  defp group_entry(report, group),
    do: Enum.find(report.entries, &(&1.kind == :group and &1.group_uuid == group.uuid))

  describe "post_folders?/0" do
    test "needs the parent hook and its own key" do
      assert MediaFolders.post_folders?()

      Application.delete_env(@app, :post_media_folders)
      refute MediaFolders.post_folders?()

      Application.put_env(@app, :post_media_folders, true)
      Application.delete_env(@app, :attachments_parent_folder)
      refute MediaFolders.post_folders?()
    end
  end

  describe "folder_name/2 for a post" do
    test "a slug post is named by its slug, a timestamp post by its date and time" do
      group = group!("News")

      assert MediaFolders.folder_name(post!(group, slug: "spring-fair"), nil) ==
               {:ok, "spring-fair"}

      assert MediaFolders.folder_name(post!(group, at: {~D[2026-09-25], ~T[14:30:00]}), nil) ==
               {:ok, "2026-09-25 14:30"}
    end
  end

  describe "ensure_post_folder/4" do
    test "a blank version keeps the post's folder without copying editorial metadata" do
      group = group!("News")
      post = post!(group, version_data: %{"featured" => true})
      {:ok, folder} = MediaFolders.ensure_post_folder(post, group_folder!(group), nil)

      assert {:ok, blank} = Versions.create_version_from(group.slug, post.uuid, nil)
      assert blank.content == ""

      assert DBStorage.get_version(post.uuid, blank.version).data == %{
               "media_folder_uuid" => folder.uuid
             }

      assert pointers(post) == [folder.uuid, folder.uuid]
    end

    test "creates Publishing/<group>/<slug> and points every version at it" do
      group = group!("News")
      post = post!(group, slug: "spring-fair", versions: 3)
      group_folder = group_folder!(group)

      assert {:ok, %Folder{name: "spring-fair", parent_uuid: parent} = folder} =
               MediaFolders.ensure_post_folder(post, group_folder, nil)

      assert parent == group_folder.uuid
      assert pointers(post) == List.duplicate(folder.uuid, 3)
    end

    test "a renamed post keeps its folder" do
      group = group!("News")
      post = post!(group, slug: "spring-fair")
      group_folder = group_folder!(group)
      {:ok, folder} = MediaFolders.ensure_post_folder(post, group_folder, nil)

      {:ok, renamed} = DBStorage.update_post(post, %{slug: "autumn-fair"})

      assert {:ok, %Folder{uuid: uuid, name: "spring-fair"}} =
               MediaFolders.ensure_post_folder(renamed, group_folder, nil)

      assert uuid == folder.uuid
      assert Repo.aggregate(Folder, :count) == 3
    end

    test "a name another post's folder holds falls back to publishing-post-<uuid>" do
      group = group!("News")
      group_folder = group_folder!(group)
      # "fair" under the group's folder belongs to another post.
      folder!("fair", group_folder.uuid)
      :ok = claim_for(post!(group, slug: "older"), "fair", group_folder)
      post = post!(group, slug: "fair")

      assert {:ok, %Folder{name: name}} = MediaFolders.ensure_post_folder(post, group_folder, nil)
      assert name == "publishing-post-" <> post.uuid
    end

    test "a pointer at a folder outside Media is not the post's folder" do
      group = group!("News")
      group_folder = group_folder!(group)
      post = post!(group, slug: "fair")
      theirs = folder!("fair", nil, %{library_uuid: library!().uuid})

      Repo.update_all(from(v in PublishingVersion, where: v.post_uuid == ^post.uuid),
        set: [data: %{"media_folder_uuid" => theirs.uuid}]
      )

      assert {:ok, folder} = MediaFolders.ensure_post_folder(post, group_folder, nil)
      assert folder.uuid != theirs.uuid
      assert folder.parent_uuid == group_folder.uuid
      assert pointers(post) == [folder.uuid]
    end

    test "a post deleted meanwhile leaves no folder behind" do
      group = group!("News")
      group_folder = group_folder!(group)
      post = post!(group, slug: "gone")
      Repo.delete!(post)

      assert MediaFolders.ensure_post_folder(post, group_folder, nil) == {:error, :not_found}
      refute Repo.exists?(from(f in Folder, where: f.name == "gone"))
    end

    test "strict: a name hook failing for the post creates nothing" do
      Application.put_env(@app, :attachments_folder_name, {Hooks, :groups_only})
      group = group!("News")
      group_folder = group_folder!(group)
      post = post!(group, slug: "fair")

      assert {:error, {:name_hook, %RuntimeError{}}} =
               MediaFolders.ensure_post_folder(post, group_folder, nil, strict: true)

      assert pointers(post) == [nil]
    end
  end

  # Points `post`'s versions at a folder named `name` under `parent`.
  defp claim_for(post, name, parent) do
    folder =
      Repo.one!(from(f in Folder, where: f.name == ^name and f.parent_uuid == ^parent.uuid))

    {_n, _} =
      from(v in PublishingVersion, where: v.post_uuid == ^post.uuid)
      |> Repo.update_all(set: [data: %{"media_folder_uuid" => folder.uuid}])

    :ok
  end

  describe "file_for_post/4" do
    test "files into the post's folder, moving a file down from the group's folder" do
      group = group!("News")
      post = post!(group, slug: "fair")
      group_folder = group_folder!(group)
      loose = file!()
      in_group = file!(%{folder_uuid: group_folder.uuid})
      elsewhere = file!(%{folder_uuid: folder!("Brand").uuid})

      assert MediaFolders.file_for_post(
               group.slug,
               post.uuid,
               [loose.uuid, in_group.uuid, elsewhere.uuid],
               nil
             ) ==
               :ok

      folder = folder_of(post)
      assert folder.parent_uuid == group_folder.uuid
      assert reload(loose).folder_uuid == folder.uuid
      assert reload(in_group).folder_uuid == folder.uuid
      assert reload(elsewhere).folder_uuid != folder.uuid
      assert linked?(elsewhere, folder.uuid)
    end

    test "an unsaved or trashed post, or post folders off: the group's folder" do
      group = group!("News")
      trashed = post!(group, slug: "old", trashed_at: DateTime.utc_now(:second))
      [a, b, c] = [file!(), file!(), file!()]

      :ok = MediaFolders.file_for_post(group.slug, nil, [a.uuid], nil)
      :ok = MediaFolders.file_for_post(group.slug, trashed.uuid, [b.uuid], nil)
      Application.delete_env(@app, :post_media_folders)
      :ok = MediaFolders.file_for_post(group.slug, post!(group).uuid, [c.uuid], nil)

      group_folder_uuid = reload(group).data["media_folder_uuid"]
      assert Enum.map([a, b, c], &reload(&1).folder_uuid) == List.duplicate(group_folder_uuid, 3)
      assert folder_of(trashed) == nil
    end
  end

  describe "adoption with post folders" do
    test "files each live post's media into its folder, the first post homing a shared file" do
      group = group!("News")
      group_folder = group_folder!(group)
      [own, shared, of_trashed] = for _ <- 1..3, do: file!()
      # Filed into the group's folder before post folders were on.
      in_group = file!(%{folder_uuid: group_folder.uuid})
      image = &~s(<Image file_uuid="#{&1.uuid}"/>)

      first =
        post!(group,
          slug: "first",
          version_data: %{"featured_image_uuid" => own.uuid, "audio_uuid" => in_group.uuid},
          contents: [{"en", image.(shared), %{}}]
        )
        |> backdate!()

      second = post!(group, slug: "second", contents: [{"en", image.(shared), %{}}])

      post!(group,
        slug: "old",
        trashed_at: DateTime.utc_now(:second),
        version_data: %{"featured_image_uuid" => of_trashed.uuid}
      )

      folders_before = Repo.aggregate(Folder, :count)
      {:ok, dry} = MediaAdoption.run(nil)

      assert %{adopt: adopt, rehome: [rehome_uuid], link: []} = entry(dry, first)
      assert Enum.sort(adopt) == Enum.sort([own.uuid, shared.uuid])
      assert rehome_uuid == in_group.uuid
      assert %{adopt: [], rehome: [], link: [linked_uuid]} = entry(dry, second)
      assert linked_uuid == shared.uuid
      assert %{adopt: [trashed_uuid]} = group_entry(dry, group)
      assert trashed_uuid == of_trashed.uuid
      assert Repo.aggregate(Folder, :count) == folders_before
      assert MediaAdoption.format_report(dry) =~ "News / first"

      {:ok, applied} = MediaAdoption.run(nil, apply?: true)
      assert %{rehomed: 1, adopted: 2, failed: []} = entry(applied, first).result

      first_folder = folder_of(first)
      second_folder = folder_of(second)

      assert {first_folder.parent_uuid, second_folder.parent_uuid} ==
               {group_folder.uuid, group_folder.uuid}

      assert {first_folder.name, second_folder.name} == {"first", "second"}

      assert Enum.map([own, shared, in_group], &reload(&1).folder_uuid) ==
               List.duplicate(first_folder.uuid, 3)

      assert linked?(shared, second_folder.uuid)
      assert reload(of_trashed).folder_uuid == group_folder.uuid

      {:ok, again} = MediaAdoption.run(nil)
      assert Enum.all?(again.entries, &(&1.adopt == [] and &1.link == [] and &1.rehome == []))
    end

    test "a post folder left under another group's folder moves under its own group's" do
      old_group = group!("Old")
      new_group = group!("News")
      old_folder = group_folder!(old_group)

      post =
        post!(old_group, slug: "fair", version_data: %{"featured_image_uuid" => file!().uuid})

      {:ok, folder} = MediaFolders.ensure_post_folder(post, old_folder, nil)
      # The post changed group (the module offers no such move; a script may).
      Repo.update_all(from(p in PublishingPost, where: p.uuid == ^post.uuid),
        set: [group_uuid: new_group.uuid]
      )

      {:ok, dry} = MediaAdoption.run(nil)
      assert %{relocate: true} = entry(dry, post)
      assert reload(folder).parent_uuid == old_folder.uuid

      {:ok, applied} = MediaAdoption.run(nil, apply?: true)
      assert %{relocated: true, failed: []} = entry(applied, post).result
      assert reload(folder).parent_uuid == reload(new_group).data["media_folder_uuid"]
    end
  end

  describe "the reorganizer source" do
    defp run_source(opts \\ []) do
      {:ok, report} = Reorganizer.run(nil, Keyword.merge([sources: [MediaReorganizer]], opts))
      report.actions
    end

    test "a trashed post's folder is reported once and left in place; a live post's is not" do
      group = group!("News")
      group_folder = group_folder!(group)
      trashed = post!(group, slug: "old", versions: 2)
      live = post!(group, slug: "live")
      {:ok, trashed_folder} = MediaFolders.ensure_post_folder(trashed, group_folder, nil)
      {:ok, _} = MediaFolders.ensure_post_folder(live, group_folder, nil)
      {:ok, _} = DBStorage.update_post(trashed, %{trashed_at: DateTime.utc_now(:second)})

      assert [%{kind: :orphan, folder: %{uuid: uuid}, reason: reason}] =
               Enum.filter(run_source(apply?: true), &(&1.kind == :orphan))

      assert uuid == trashed_folder.uuid
      assert reason =~ "post old is trashed"
      assert reload(trashed_folder).parent_uuid == group_folder.uuid
    end

    test "names a post whose media is outside its folder" do
      group = group!("News")
      post!(group, slug: "fair", version_data: %{"featured_image_uuid" => file!().uuid})

      assert [%{kind: :unfiled, label: label}] = run_source()
      assert label =~ "post News / fair"
    end
  end
end
