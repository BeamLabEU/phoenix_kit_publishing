defmodule PhoenixKit.Modules.Publishing.Web.Controller.ModeConversionTest do
  @moduledoc """
  Converting a timestamp group to slug URLs (`Publishing.convert_to_slug_mode/2`):
  every post gets a unique slug from its title, the new URLs serve, and the
  old date URLs answer with a 301 to them.
  """

  # async: false — mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.{DBStorage, Errors, Groups, Posts}
  alias PhoenixKit.Modules.Publishing.{PublishingGroup, PublishingPost}
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")
    {:ok, _} = Settings.update_setting("time_zone", "0")

    {:ok, group} =
      Groups.add_group("conv-#{System.unique_integer([:positive])}", mode: "timestamp")

    slug = group["slug"]

    import! = fn title, at ->
      {:ok, post} =
        Publishing.import_post(slug, %{title: title, content: "Body.", published_at: at})

      post
    end

    posts = %{
      a: import!.("Projects 0.33.0", "2026-11-06T01:13:00Z"),
      # same title: the second gets a suffix
      b: import!.("Projects 0.33.0", "2026-11-07T09:00:00Z"),
      # alone on its date: its old URL is the date only
      c: import!.("2026-11-08", "2026-11-08T12:00:00Z"),
      d: import!.("!!!", "2026-11-09T15:30:00Z")
    }

    %{slug: slug, posts: posts}
  end

  test "posts get unique, routable slugs; the old date URLs 301 to the new ones", %{
    conn: conn,
    slug: slug,
    posts: posts
  } do
    old_a = get(conn, "/#{slug}/2026-11-06") |> html_response(200)
    assert old_a =~ "Projects 0.33.0"

    assert {:ok, %{converted: 4, slugs: slugs}} = Publishing.convert_to_slug_mode(slug)
    assert slugs[posts.a[:uuid]] == "projects-0-33-0"
    assert slugs[posts.b[:uuid]] == "projects-0-33-0-2"
    # a date-shaped title would be read as a date URL
    assert slugs[posts.c[:uuid]] == "2026-11-08-post"
    assert slugs[posts.d[:uuid]] == "post-2026-11-09-1530"

    assert Groups.get_group_mode(slug) == "slug"
    assert DBStorage.get_post_by_uuid(posts.a[:uuid]).mode == "slug"

    assert get(build_conn(), "/#{slug}/projects-0-33-0") |> html_response(200) =~ "Body."
    assert get(build_conn(), "/#{slug}/2026-11-08-post") |> html_response(200) =~ "Body."

    for {old, new} <- [
          {"/#{slug}/2026-11-06", "/#{slug}/projects-0-33-0"},
          {"/#{slug}/2026-11-07/09:00", "/#{slug}/projects-0-33-0-2"},
          {"/#{slug}/2026-11-09", "/#{slug}/post-2026-11-09-1530"}
        ] do
      conn = get(build_conn(), old)
      assert conn.status == 301, "#{old} answered #{conn.status}"
      assert redirected_to(conn, 301) == new
    end

    # the listing links the new URLs
    html = get(build_conn(), "/#{slug}") |> html_response(200)
    assert html =~ ~s(href="/#{slug}/projects-0-33-0")
    refute html =~ ~s(href="/#{slug}/2026-11-06")
  end

  test "a slug group, or an unknown one, is refused", %{slug: slug} do
    {:ok, _} = Publishing.convert_to_slug_mode(slug)
    assert {:error, :invalid_mode} = Publishing.convert_to_slug_mode(slug)
    assert {:error, :group_not_found} = Publishing.convert_to_slug_mode("no-such-group")
    assert {:ok, _} = Posts.read_post(slug, "projects-0-33-0")
  end

  test "a draft's old URL does not reveal its new one; a date-shaped slug is remade", %{
    slug: slug
  } do
    {:ok, draft} =
      Publishing.import_post(slug, %{title: "Secret plans", published_at: "2026-11-10T08:00:00Z"},
        publish: false
      )

    {:ok, dated} =
      Publishing.import_post(slug, %{title: "Dated", published_at: "2026-11-11T08:00:00Z"})

    # a timestamp post's slug was never in its URL; one shaped like a date
    # would be read as a date after the conversion
    {1, _} =
      TestRepo.update_all(
        from(p in PublishingPost,
          where: p.uuid == ^dated[:uuid]
        ),
        set: [slug: "2026-11-11"]
      )

    {:ok, %{slugs: slugs}} = Publishing.convert_to_slug_mode(slug)
    assert slugs[dated[:uuid]] == "dated"

    conn = get(build_conn(), "/#{slug}/2026-11-10/08:00")
    assert conn.status != 301
    refute (get_resp_header(conn, "location") |> List.first() || "") =~ "secret-plans"
    assert slugs[draft[:uuid]] == "secret-plans"
  end

  test "is refused while a live post is scheduled ahead: a slug post has no embargo", %{
    slug: slug
  } do
    future = DateTime.utc_now() |> DateTime.add(10 * 86_400) |> DateTime.to_iso8601()

    {:ok, _} =
      Publishing.import_post(slug, %{title: "Embargoed", content: "x", published_at: future})

    {:ok, %{total: before}} = Publishing.list_published(slug)

    assert {:error, :scheduled_posts} = Publishing.convert_to_slug_mode(slug)
    assert Groups.get_group_mode(slug) == "timestamp"
    assert {:ok, %{total: ^before}} = Publishing.list_published(slug)
    assert Errors.message(:scheduled_posts) =~ "scheduled"
  end

  test "no post is given a slug another post answers to through a url_slug", %{slug: slug} do
    {:ok, alpha} =
      Publishing.import_post(slug, %{title: "Alpha", published_at: "2026-10-01T10:00:00Z"})

    {:ok, alpha} = Posts.read_post_by_uuid(alpha[:uuid])
    {:ok, _} = Posts.update_post(slug, alpha, %{"url_slug" => "hello"}, %{publish: false})

    {:ok, hello} =
      Publishing.import_post(slug, %{title: "Hello", published_at: "2026-10-02T10:00:00Z"})

    {:ok, %{slugs: slugs}} = Publishing.convert_to_slug_mode(slug)
    assert slugs[alpha[:uuid]] == "alpha"
    assert slugs[hello[:uuid]] == "hello-2"

    {:ok, %{entries: entries}} = Publishing.list_published(slug)
    urls = Enum.map(entries, & &1.url)
    assert urls == Enum.uniq(urls)
  end

  test "a title that is a language code or a route word gets a routable slug", %{slug: slug} do
    {:ok, admin} =
      Publishing.import_post(slug, %{title: "Admin", published_at: "2026-10-03T10:00:00Z"})

    {:ok, %{slugs: slugs}} = Publishing.convert_to_slug_mode(slug)
    assert slugs[admin[:uuid]] == "admin-post"
    assert {:ok, _} = Posts.read_post(slug, "admin-post")
  end

  test "an editor opened before the conversion still saves", %{slug: slug, posts: posts} do
    {:ok, stale} = Posts.read_post_by_uuid(posts.a[:uuid])
    {:ok, _} = Publishing.convert_to_slug_mode(slug)

    assert {:ok, saved} =
             Posts.update_post(slug, stale, %{"title" => "Projects 0.34", "content" => "New."}, %{
               publish: false
             })

    assert saved.metadata.title == "Projects 0.34"
    assert DBStorage.get_post_by_uuid(posts.a[:uuid]).slug == "projects-0-33-0"
  end

  test "the audit row names the group", %{slug: slug} do
    import PhoenixKitPublishing.ActivityLogAssertions

    {:ok, _} = Publishing.convert_to_slug_mode(slug)
    group = TestRepo.get_by!(PublishingGroup, slug: slug)

    row = assert_activity_logged("publishing.group.updated", resource_uuid: group.uuid)
    assert row.metadata["mode_converted"] == "timestamp_to_slug"
    assert row.metadata["slug"] == slug
  end
end
