defmodule PhoenixKit.Modules.Publishing.API.RefsTest do
  use PhoenixKitPublishing.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.API.Refs

  alias PhoenixKit.Modules.Publishing.{
    Constants,
    DBStorage,
    Groups,
    Posts,
    PublishingContent,
    PublishingGroup,
    PublishingPost,
    Versions
  }

  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    Fx.languages!()
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "T", slug: "t"})
    %{g: g, post: post}
  end

  describe "resolve_post/2" do
    test "the id form and the group+slug form find the same post", %{g: g, post: post} do
      assert {:ok, %{db_post: %{uuid: uuid}, group: %{slug: slug}}} =
               Refs.resolve_post(%{"id" => post[:uuid]}, [])

      assert uuid == post[:uuid] and slug == g["slug"]

      assert {:ok, %{db_post: %{uuid: ^uuid}}} =
               Refs.resolve_post(%{"group" => g["slug"], "slug" => "t"}, [])
    end

    test "an uncastable or unknown id and an unknown slug are not_found, never a raise", %{g: g} do
      assert {:error, :not_found} = Refs.resolve_post(%{"id" => "not-a-uuid"}, [])
      assert {:error, :not_found} = Refs.resolve_post(%{"id" => Ecto.UUID.generate()}, [])

      assert {:error, :not_found} =
               Refs.resolve_post(%{"group" => g["slug"], "slug" => "nope"}, [])

      assert {:error, :not_found} = Refs.resolve_post(%{"group" => "nope", "slug" => "t"}, [])
    end

    test "anything but exactly one form is invalid_ref", %{g: g, post: post} do
      for ref <- [
            %{},
            %{"id" => post[:uuid], "group" => g["slug"]},
            %{"id" => post[:uuid], "extra" => 1},
            %{"group" => g["slug"]},
            nil,
            "string",
            5
          ] do
        assert {:error, :invalid_ref} = Refs.resolve_post(ref, []), inspect(ref)
      end
    end

    test "a NUL byte or invalid UTF-8 in the group or slug is invalid_ref, never a raise", %{
      g: g
    } do
      for bad <- ["a\u0000b", <<0xFF, 0xFE>>] do
        assert {:error, :invalid_ref} =
                 Refs.resolve_post(%{"group" => g["slug"], "slug" => bad}, [])

        assert {:error, :invalid_ref} =
                 Refs.resolve_post(%{"group" => bad, "slug" => "t"}, include_trashed: true)

        assert {:error, :not_found} = Refs.resolve_group(bad)
      end
    end

    test "a trashed post: the slug form needs include_trashed, the id form reports post_trashed",
         %{g: g, post: post} do
      {:ok, _} = Posts.trash_post(g["slug"], post[:uuid])
      ref = %{"group" => g["slug"], "slug" => "t"}
      assert {:error, :not_found} = Refs.resolve_post(ref, [])
      assert {:ok, %{db_post: %{uuid: uuid}}} = Refs.resolve_post(ref, include_trashed: true)
      assert uuid == post[:uuid]

      assert {:error, {:post_trashed, %{uuid: ^uuid}}} =
               Refs.resolve_post(%{"id" => post[:uuid]}, [])

      assert {:ok, _} = Refs.resolve_post(%{"id" => post[:uuid]}, include_trashed: true)
    end

    test "the trashed slug lookup stays inside its group and ignores live posts", %{
      g: g,
      post: post
    } do
      other = Fx.group!()
      {:ok, _} = Posts.trash_post(g["slug"], post[:uuid])

      assert {:error, :not_found} =
               Refs.resolve_post(%{"group" => other["slug"], "slug" => "t"},
                 include_trashed: true
               )

      live = Fx.post!(g["slug"], %{title: "L", slug: "live"})

      assert {:ok, %{db_post: %{uuid: live_uuid}}} =
               Refs.resolve_post(%{"group" => g["slug"], "slug" => "live"}, include_trashed: true)

      assert live_uuid == live[:uuid]
      assert DBStorage.get_trashed_post(g["slug"], "live") == nil
      assert %{uuid: trashed_uuid} = DBStorage.get_trashed_post(g["slug"], "t")
      assert trashed_uuid == post[:uuid]
    end

    test "a timestamp post has no slug: the slug form is not_found and the id form works (Review Focus 2)" do
      ts = Fx.group!(mode: "timestamp")
      p = Fx.post!(ts["slug"], %{title: "Stamp"})

      assert {:error, :not_found} =
               Refs.resolve_post(%{"group" => ts["slug"], "slug" => "anything"}, [])

      assert {:ok, %{db_post: %{uuid: uuid}}} = Refs.resolve_post(%{"id" => p[:uuid]}, [])
      assert uuid == p[:uuid]
    end
  end

  describe "resolve_version/3" do
    test "reads default to the active version, else the latest; writes to the highest draft", %{
      g: g,
      post: post
    } do
      db = fn -> DBStorage.get_post_by_uuid(post[:uuid]) end
      assert {:ok, %{version_number: 1}} = Refs.resolve_version(db.(), nil, :read)
      assert {:ok, %{version_number: 1}} = Refs.resolve_version(db.(), nil, :write)
      Fx.publish!(g["slug"], post[:uuid])
      assert {:error, :no_draft_version} = Refs.resolve_version(db.(), nil, :write)
      assert {:ok, %{version_number: 1}} = Refs.resolve_version(db.(), nil, :read)
      {:ok, _} = Versions.create_new_version(g["slug"], post, %{}, %{})
      assert {:ok, %{version_number: 2}} = Refs.resolve_version(db.(), nil, :write)

      assert {:ok, %{version_number: 1}} = Refs.resolve_version(db.(), nil, :read),
             "the active version wins for reads"
    end

    test "an explicit number that exists is legal even when live or archived; one that does not is version_not_found",
         %{g: g, post: post} do
      Fx.publish!(g["slug"], post[:uuid])
      db = DBStorage.get_post_by_uuid(post[:uuid])
      assert {:ok, %{version_number: 1}} = Refs.resolve_version(db, 1, :write)
      assert {:error, :version_not_found} = Refs.resolve_version(db, 9, :write)
      assert {:error, :version_not_found} = Refs.resolve_version(db, 9, :read)
    end
  end

  describe "resolve_language/2" do
    test "a full code, a bare code matching exactly one enabled code, and nil for the primary" do
      assert {:ok, "de-DE"} = Refs.resolve_language("de-DE")
      assert {:ok, "de-DE"} = Refs.resolve_language("de")
      assert {:ok, "en-US"} = Refs.resolve_language(nil)
    end

    test "an unknown code lists the enabled codes; a code the post has is accepted through extra" do
      assert {:error, {:language_not_enabled, ["en-US", "de-DE"]}} = Refs.resolve_language("xx")
      Fx.languages!(["en-US"])
      assert {:error, {:language_not_enabled, ["en-US"]}} = Refs.resolve_language("de-DE")
      assert {:ok, "de-DE"} = Refs.resolve_language("de-DE", ["de-DE"])
    end

    test "a bare code that matches several enabled dialects is refused" do
      Fx.languages!(["en-US", "en-GB"])
      assert {:error, {:language_not_enabled, _}} = Refs.resolve_language("en")
    end
  end

  describe "read_post_for_preview/3" do
    test "reads the requested language and version without healing a stale post", %{post: post} do
      version = Fx.version(post[:uuid])

      TestRepo.update_all(from(p in PublishingPost, where: p.uuid == ^post[:uuid]),
        set: [active_version_uuid: version.uuid]
      )

      assert {:ok, %{language: "en-US", version: 1}} =
               Refs.read_post_for_preview(post[:uuid], "en-US", 1)

      assert Fx.db_post(post[:uuid]).active_version_uuid == version.uuid,
             "the preview read must not heal"

      {:ok, _} = Posts.read_post_by_uuid(post[:uuid])

      assert Fx.db_post(post[:uuid]).active_version_uuid == nil,
             "the fixture is not stale: this test would be vacuous"
    end

    test "an unknown post is not_found" do
      assert {:error, :not_found} = Refs.read_post_for_preview(Ecto.UUID.generate(), nil, nil)
    end
  end

  describe "group_map/1" do
    test "is the map Groups.fetch_group/1 builds for a group that needs no repair", %{g: g} do
      {:ok, _} = Groups.update_group(g["slug"], %{"show_breadcrumbs" => true})
      {:ok, fetched} = Groups.fetch_group(g["slug"])
      assert {:ok, db_group} = Refs.resolve_group(g["slug"])

      assert Refs.group_map(db_group) == fetched
    end

    test "reads a stale group as stored, without healing it", %{g: g} do
      TestRepo.update_all(from(r in PublishingGroup, where: r.slug == ^g["slug"]),
        set: [mode: "bogus"]
      )

      assert {:ok, db_group} = Refs.resolve_group(g["slug"])
      assert %{"mode" => "bogus", "slug" => slug} = Refs.group_map(db_group)
      assert slug == g["slug"]
      assert DBStorage.get_group_by_slug(g["slug"]).mode == "bogus", "the read must not heal"

      {:ok, healed} = Groups.fetch_group(g["slug"])
      refute healed["mode"] == "bogus", "the fixture is not stale: this test would be vacuous"
    end
  end

  describe "primary_title_ok?/1" do
    test "false for an empty and for the default title, true for a real one; the legacy base-code row counts",
         %{g: g, post: post} do
      version = Fx.version(post[:uuid])
      assert Refs.primary_title_ok?(version)

      {:ok, p} = Posts.read_post_by_uuid(post[:uuid])

      {:ok, _} =
        Posts.update_post(
          g["slug"],
          p,
          %{"title" => Constants.default_title()},
          publish: false
        )

      refute Refs.primary_title_ok?(version)
      {:ok, _} = Posts.update_post(g["slug"], p, %{"title" => ""}, publish: false)
      refute Refs.primary_title_ok?(version)
      {:ok, _} = Posts.update_post(g["slug"], p, %{"title" => "Real"}, publish: false)

      TestRepo.update_all(
        from(c in PublishingContent,
          where: c.version_uuid == ^version.uuid
        ),
        set: [language: "en"]
      )

      assert Refs.primary_title_ok?(version)
    end
  end

  describe "resolve_category/2" do
    test "by id, by slug, both naming the same category, and both naming different ones", %{g: g} do
      a = Fx.category!(g["slug"], "A", %{slug: "a"})
      b = Fx.category!(g["slug"], "B", %{slug: "b"})
      all = [a, b]
      assert {:ok, ^a} = Refs.resolve_category(%{"id" => a.uuid}, all)
      assert {:ok, ^b} = Refs.resolve_category(%{"slug" => "b"}, all)
      assert {:ok, ^a} = Refs.resolve_category(%{"id" => a.uuid, "slug" => "a"}, all)
      assert {:error, :invalid_ref} = Refs.resolve_category(%{"id" => a.uuid, "slug" => "b"}, all)
      assert {:error, :not_found} = Refs.resolve_category(%{"slug" => "nope"}, all)
      assert {:error, :invalid_ref} = Refs.resolve_category(%{}, all)
      assert {:error, :invalid_ref} = Refs.resolve_category("a", all)
    end
  end

  describe "error helpers" do
    test "post_error, group_error, group_missing and version_error map each failure and pass {:ok, x} through",
         %{g: g} do
      assert {:ok, :x} = Refs.post_error({:ok, :x})

      assert {:error, :validation_failed, _, %{errors: [%{reason: "invalid_ref"}]}} =
               Refs.post_error({:error, :invalid_ref})

      assert {:error, :validation_failed, _, %{errors: [%{reason: "post_trashed"}]}} =
               Refs.post_error({:error, {:post_trashed, %{}}})

      assert {:error, :not_found, _, _} = Refs.post_error({:error, :not_found})
      assert :ok = Refs.group_error(:ok)

      assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
               Refs.group_error({:error, :group_trashed})

      assert {:error, :not_found, _, _} = Refs.group_missing({:error, :not_found})
      assert {:ok, :g} = Refs.group_missing({:ok, :g})
      assert {:ok, :v} = Refs.version_error({:ok, :v})

      assert {:error, :validation_failed, _, %{errors: [%{reason: "version_not_found"}]}} =
               Refs.version_error({:error, :version_not_found})

      assert {:error, :validation_failed, _, %{errors: [%{reason: "no_draft_version"}]}} =
               Refs.version_error({:error, :no_draft_version})

      {:ok, _} = Groups.trash_group(g["slug"])
      {:ok, group} = Refs.resolve_group(g["slug"])
      assert {:error, :group_trashed} = Refs.ensure_group_active(group)
    end
  end
end
