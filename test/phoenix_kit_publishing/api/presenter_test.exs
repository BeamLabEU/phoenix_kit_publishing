defmodule PhoenixKit.Modules.Publishing.API.PresenterTest do
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.API.Presenter
  alias PhoenixKit.Modules.Publishing.{DBStorage, Posts, Versions}
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

  setup do
    Fx.languages!()
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "Hello", slug: "hello"})
    Fx.body!(g["slug"], post[:uuid], "# Body")
    %{g: g, post: post}
  end

  defp load(uuid) do
    db = DBStorage.get_post_by_uuid(uuid, [:group])
    versions = DBStorage.list_versions(uuid)
    shown = Enum.find(versions, &(&1.uuid == db.active_version_uuid)) || List.last(versions)
    {db, versions, DBStorage.list_contents(shown.uuid)}
  end

  test "status: draft, published, scheduled, trashed", %{g: g, post: post} do
    {db, versions, _} = load(post[:uuid])
    assert Presenter.status(db, versions) == "draft"
    Fx.publish!(g["slug"], post[:uuid])
    {db, versions, _} = load(post[:uuid])
    assert Presenter.status(db, versions) == "published"
    {:ok, _} = Posts.trash_post(g["slug"], post[:uuid])
    {db, versions, _} = load(post[:uuid])
    assert Presenter.status(db, versions) == "trashed"

    ts = Fx.group!(mode: "timestamp")
    p = Fx.post!(ts["slug"], %{title: "Soon"})
    Fx.publish!(ts["slug"], p[:uuid])
    {:ok, full} = Posts.read_post_by_uuid(p[:uuid])
    future = Date.utc_today() |> Date.add(10)

    {:ok, _} =
      Posts.update_post(ts["slug"], full, %{"published_at" => "#{future}T09:30:00Z"},
        publish: false
      )

    {db, versions, _} = load(p[:uuid])
    assert Presenter.status(db, versions) == "scheduled"
  end

  test "post_summary: a draft has no public_paths, a published post has one per language", %{
    g: g,
    post: post
  } do
    {db, versions, contents} = load(post[:uuid])
    summary = Presenter.post_summary(db, db.group, versions, contents)

    assert %{
             "id" => _,
             "group" => _,
             "slug" => "hello",
             "mode" => "slug",
             "status" => "draft",
             "title" => "Hello",
             "languages" => ["en-US"],
             "active_version" => nil,
             "latest_version" => 1
           } = summary

    refute Map.has_key?(summary, "public_paths")

    Fx.translation!(g["slug"], post[:uuid], "de-DE", "Hallo", "Inhalt")
    Fx.publish!(g["slug"], post[:uuid])
    {db, versions, contents} = load(post[:uuid])
    summary = Presenter.post_summary(db, db.group, versions, contents)
    assert summary["status"] == "published" and summary["active_version"] == 1
    assert %{"en-US" => en, "de-DE" => de} = summary["public_paths"]
    assert en =~ "hello" and de =~ "hello"
  end

  test "public_paths starts with the site origin when the site_url setting is set", %{
    g: g,
    post: post
  } do
    Fx.publish!(g["slug"], post[:uuid])
    {:ok, _} = PhoenixKit.Settings.update_setting("site_url", "https://example.test")
    {db, _versions, contents} = load(post[:uuid])
    assert %{"en-US" => "https://example.test" <> _} = Presenter.public_paths(db, contents)
  end

  test "write_summary has no title, slug or public_paths and nothing that starts with pk_ (a post titled pk_sale)",
       %{g: g} do
    post = Fx.post!(g["slug"], %{title: "pk_sale", slug: "pk-sale"})
    Fx.publish!(g["slug"], post[:uuid])
    {db, versions, contents} = load(post[:uuid])
    summary = Presenter.write_summary(db, db.group, versions, contents)

    refute Map.has_key?(summary, "title") or Map.has_key?(summary, "slug") or
             Map.has_key?(summary, "public_paths")

    refute inspect(summary) =~ "pk_"
  end

  test "public_state: active, history, none", %{g: g, post: post} do
    Fx.publish!(g["slug"], post[:uuid], 1)

    {:ok, _} =
      Versions.create_new_version(g["slug"], post, %{}, %{})

    Fx.publish!(g["slug"], post[:uuid], 2)

    {:ok, _} =
      Versions.create_new_version(g["slug"], post, %{}, %{})

    db = DBStorage.get_post_by_uuid(post[:uuid])
    assert Presenter.public_state(db, DBStorage.get_version(post[:uuid], 2)) == "active"
    assert Presenter.public_state(db, DBStorage.get_version(post[:uuid], 1)) == "history"
    assert Presenter.public_state(db, DBStorage.get_version(post[:uuid], 3)) == "none"
  end
end
