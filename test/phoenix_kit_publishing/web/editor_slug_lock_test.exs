defmodule PhoenixKit.Modules.Publishing.Web.EditorSlugLockTest do
  @moduledoc """
  Issue #54: fixing a typo in a published post rewrote its slug from the
  title, and the post-slug rename carried every translation along, so a live
  URL and the redirects pointing at it went to 404 without the editor
  noticing.

  Pins:

    * A stored slug follows the title only while the post was never public
      and the slug still is the title's; only a title change re-derives it.
    * A translation saved with an empty url_slug gets one from its own title.
    * A post-slug rename moves the primary language's url_slug only.
    * A slug change on a published post is announced before the save.
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  @saver_uuid "019cce93-0000-7000-8000-00000000ee54"

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English (United States)",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          },
          %{
            "code" => "de-DE",
            "name" => "German (Germany)",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          }
        ]
      })

    TestRepo.query!(
      """
      INSERT INTO phoenix_kit_users (uuid, email, hashed_password, inserted_at, updated_at)
      VALUES ($1::uuid, 'slug-lock-saver@example.com', 'x', now(), now())
      ON CONFLICT (email) DO NOTHING
      """,
      [Ecto.UUID.dump!(@saver_uuid)]
    )

    {:ok, group} =
      Groups.add_group("Slug Lock #{System.unique_integer([:positive])}", mode: "slug")

    %{group: group}
  end

  defp assigns_of(view) do
    view.pid |> :sys.get_state() |> get_in([Access.key(:socket), Access.key(:assigns)])
  end

  defp open(conn, group, post, query \\ "") do
    {:ok, view, html} =
      conn
      |> put_test_scope(fake_scope(user_uuid: @saver_uuid))
      |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}/edit#{query}")

    {view, html}
  end

  defp type_title(view, title),
    do: render_change(view, "update_meta", %{"title" => title, "_target" => ["title"]})

  defp contents(post) do
    [version | _] = DBStorage.list_versions(post[:uuid])
    Map.new(DBStorage.list_contents(version.uuid), &{&1.language, &1})
  end

  describe "the primary slug" do
    test "a published post keeps its slug when the title or another field changes",
         %{conn: conn, group: group} do
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Hello World"})
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      {view, _} = open(conn, group, post)
      assert assigns_of(view)[:form]["slug"] == "hello-world"

      # Another field of the meta form: the title rides along unchanged.
      render_change(view, "update_meta", %{
        "title" => "Hello World",
        "version_label" => "typo fix",
        "_target" => ["version_label"]
      })

      assert assigns_of(view)[:form]["slug"] == "hello-world"

      html = type_title(view, "Hello World, Corrected")
      assert assigns_of(view)[:form]["slug"] == "hello-world"
      refute html =~ "slug-move-notice"
    end

    test "a draft whose slug follows its title keeps following it", %{conn: conn, group: group} do
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Draft Title"})
      assert post[:slug] == "draft-title"

      {view, _} = open(conn, group, post)
      type_title(view, "Better Draft Title")

      assert assigns_of(view)[:form]["slug"] == "better-draft-title"
    end

    test "a draft with a hand-picked slug keeps it", %{conn: conn, group: group} do
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Draft Title", slug: "chosen"})

      {view, _} = open(conn, group, post)
      type_title(view, "Another Title")

      assert assigns_of(view)[:form]["slug"] == "chosen"
    end

    test "editing the slug of a published post says the URL moves", %{conn: conn, group: group} do
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Hello World"})
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      {view, html} = open(conn, group, post)
      refute html =~ "slug-move-notice"

      html = render_change(view, "update_meta", %{"slug" => "hello-there", "_target" => ["slug"]})

      assert html =~ "slug-move-notice"
      assert html =~ "hello-world"
      assert html =~ "hello-there"
    end

    test "a draft's slug change is not announced", %{conn: conn, group: group} do
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Draft Title"})

      {view, _} = open(conn, group, post)
      html = render_change(view, "update_meta", %{"slug" => "elsewhere", "_target" => ["slug"]})

      refute html =~ "slug-move-notice"
    end
  end

  describe "translation url_slugs" do
    test "a new translation saved with an empty url_slug gets one from its own title",
         %{conn: conn, group: group} do
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Hello World"})

      {view, _} = open(conn, group, post, "?lang=de-DE")
      assert assigns_of(view)[:form]["url_slug"] == ""

      type_title(view, "Hallo Welt")
      _ = render_click(view, "save", %{})

      assert contents(post)["de-DE"].url_slug == "hallo-welt"
      assert contents(post)["en-US"].url_slug == "hello-world"
    end

    test "a published translation serving the post slug keeps it when its title changes",
         %{conn: conn, group: group} do
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Hello World"})
      [version] = DBStorage.list_versions(post[:uuid])

      {:ok, _} =
        DBStorage.create_content(%{
          version_uuid: version.uuid,
          language: "de-DE",
          title: "Hallo Welt",
          content: "de body",
          url_slug: "hello-world"
        })

      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      {view, _} = open(conn, group, post, "?lang=de-DE")
      assert assigns_of(view)[:form]["url_slug"] == "hello-world"

      type_title(view, "Hallo Welt, korrigiert")
      assert assigns_of(view)[:form]["url_slug"] == "hello-world"

      _ = render_click(view, "save", %{})
      assert contents(post)["de-DE"].url_slug == "hello-world"
    end

    test "erasing a translation's url_slug saves one from its own title, not the post slug",
         %{conn: conn, group: group} do
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Hello World"})
      [version] = DBStorage.list_versions(post[:uuid])

      {:ok, _} =
        DBStorage.create_content(%{
          version_uuid: version.uuid,
          language: "de-DE",
          title: "Hallo Welt",
          content: "de body",
          url_slug: "eigener-slug"
        })

      {view, _} = open(conn, group, post, "?lang=de-DE")
      assert assigns_of(view)[:form]["url_slug"] == "eigener-slug"

      render_change(view, "update_meta", %{"url_slug" => "", "_target" => ["url_slug"]})
      _ = render_click(view, "save", %{})

      de = contents(post)["de-DE"]
      assert de.url_slug == "hallo-welt"
      assert "eigener-slug" in (de.data["previous_url_slugs"] || [])
    end

    test "renaming the post slug leaves a translation's url_slug alone", %{group: group} do
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Hello World"})
      [version] = DBStorage.list_versions(post[:uuid])

      {:ok, _} =
        DBStorage.create_content(%{
          version_uuid: version.uuid,
          language: "de-DE",
          title: "Hallo Welt",
          content: "de body",
          url_slug: "hello-world"
        })

      {:ok, _} =
        Posts.update_post(group["slug"], post, %{"slug" => "hello-again"}, %{})

      by_language = contents(post)
      assert by_language["en-US"].url_slug == "hello-again"
      assert "hello-world" in (by_language["en-US"].data["previous_url_slugs"] || [])
      assert by_language["de-DE"].url_slug == "hello-world"
    end
  end
end
