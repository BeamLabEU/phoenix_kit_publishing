defmodule PhoenixKit.Modules.Publishing.Web.Controller.AccessPreV4Test do
  @moduledoc """
  Code deployed before the module chain's V4 has run: no access-rules table.
  Every surface must answer as before the feature (every post public), never
  a 500. The table is renamed inside the test's sandbox transaction, so the
  rollback brings it back.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.PostAccess
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group("prev4-#{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{title: "Old world", slug: "old-world", content: "Body."})

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    {:ok, ts} =
      Groups.add_group("prev4ts-#{System.unique_integer([:positive])}", mode: "timestamp")

    {:ok, news} = Posts.create_post(ts["slug"], %{title: "Old news", content: "News."})
    :ok = Versions.publish_version(ts["slug"], news.uuid, 1)

    TestRepo.query!("ALTER TABLE phoenix_kit_publishing_access_rules RENAME TO zz_rules_away")
    PostAccess.reset_rules_table_probe()
    on_exit(&PostAccess.reset_rules_table_probe/0)

    %{slug: group["slug"], ts_slug: ts["slug"], news: news, group: group}
  end

  test "the probe says the table is missing, and every read answers 'no rules'", %{
    slug: slug
  } do
    refute PostAccess.rules_table?()
    assert PostAccess.list_rules({:post, Ecto.UUID.generate()}) == []
    assert PostAccess.protected_post_uuids([Ecto.UUID.generate()]) == %{}
    assert {:ok, _} = Publishing.list_published(slug)
  end

  test "the first read after migration sees the rules table" do
    refute PostAccess.rules_table?()
    TestRepo.query!("ALTER TABLE zz_rules_away RENAME TO phoenix_kit_publishing_access_rules")
    assert PostAccess.rules_table?()
  end

  test "post, listing, feed and date-only pages render as public", %{
    conn: conn,
    slug: slug,
    ts_slug: ts_slug,
    news: news
  } do
    assert conn |> get("/#{slug}/old-world") |> html_response(200) =~ "Old world"
    assert conn |> get("/#{slug}") |> html_response(200) =~ "Old world"
    assert conn |> get("/#{slug}/feed.xml") |> response(200) =~ "Old world"

    day = Date.to_iso8601(news.date)
    date_only = get(conn, "/#{ts_slug}/#{day}")
    assert date_only.status in [200, 302]
    if date_only.status == 200, do: assert(date_only.resp_body =~ "Old news")
  end

  test "creating a post in a group still works", %{group: group} do
    assert {:ok, _} = Posts.create_post(group["slug"], %{title: "Brand new", slug: "brand-new"})
  end
end
