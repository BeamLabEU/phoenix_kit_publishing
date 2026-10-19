defmodule PhoenixKit.Modules.Publishing.API.PresenterTest.Resolver do
  @moduledoc false
  # Core hands the language over as given, so the dialects are mapped here: en-GB shares the en domain.
  def host_for("en-US"), do: "en.example.test"
  def host_for("en-GB"), do: "en.example.test"
  def host_for("de-DE"), do: "de.example.test"
  def host_for(_), do: nil

  def host_for_dialect("en-GB"), do: "gb.example.test"
  def host_for_dialect(language), do: host_for(language)

  def host_for_counted(language) do
    Process.put(:resolver_calls, Process.get(:resolver_calls, 0) + 1)
    host_for(language)
  end
end

defmodule PhoenixKit.Modules.Publishing.API.PresenterTest do
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.API.Presenter
  alias PhoenixKit.Modules.Publishing.API.PresenterTest.Resolver
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

  describe "public_paths on language domains" do
    setup %{g: g, post: post} do
      Fx.languages!(["en-US", "en-GB", "de-DE", "fr-FR"])
      Fx.translation!(g["slug"], post[:uuid], "en-GB", "Hello UK", "Body")
      Fx.translation!(g["slug"], post[:uuid], "de-DE", "Hallo", "Inhalt")
      Fx.translation!(g["slug"], post[:uuid], "fr-FR", "Salut", "Contenu")
      Fx.publish!(g["slug"], post[:uuid])
      {:ok, _} = PhoenixKit.Settings.update_setting("site_url", "https://example.test")
      on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)

      {db, _versions, contents} = load(post[:uuid])
      %{db: db, contents: contents}
    end

    defp resolver!(fun \\ :host_for),
      do: Application.put_env(:phoenix_kit, :canonical_host_resolver, {Resolver, fun})

    test "without a resolver every language keeps the site origin and its prefix",
         %{db: db, contents: contents} do
      assert Presenter.public_paths(db, contents) == %{
               "en-US" => "https://example.test/en/#{db.group.slug}/hello",
               "en-GB" => "https://example.test/en-gb/#{db.group.slug}/hello",
               "de-DE" => "https://example.test/de/#{db.group.slug}/hello",
               "fr-FR" => "https://example.test/fr/#{db.group.slug}/hello"
             }
    end

    @tag :canonical_urls
    test "a language with a domain gets it, without its base language segment",
         %{db: db, contents: contents} do
      resolver!()
      slug = db.group.slug

      paths = Presenter.public_paths(db, contents)
      assert paths["de-DE"] == "https://de.example.test/#{slug}/hello"
      assert paths["en-US"] == "https://en.example.test/#{slug}/hello"
    end

    @tag :canonical_urls
    test "a sibling dialect on the base domain keeps its own segment",
         %{db: db, contents: contents} do
      resolver!()

      assert Presenter.public_paths(db, contents)["en-GB"] ==
               "https://en.example.test/en-gb/#{db.group.slug}/hello"
    end

    @tag :canonical_urls
    test "a sibling dialect with a domain of its own gets that domain and keeps its segment",
         %{db: db, contents: contents} do
      resolver!(:host_for_dialect)
      slug = db.group.slug

      paths = Presenter.public_paths(db, contents)
      assert paths["en-GB"] == "https://gb.example.test/en-gb/#{slug}/hello"
      assert paths["en-US"] == "https://en.example.test/#{slug}/hello"
    end

    @tag :canonical_urls
    test "a language without a domain falls back to the site origin and the prefix",
         %{db: db, contents: contents} do
      resolver!()

      assert Presenter.public_paths(db, contents)["fr-FR"] ==
               "https://example.test/fr/#{db.group.slug}/hello"
    end

    @tag :canonical_urls
    test "with no site origin configured a language without a domain stays root-relative",
         %{db: db, contents: contents} do
      resolver!()
      {:ok, _} = PhoenixKit.Settings.update_setting("site_url", "")
      slug = db.group.slug

      paths = Presenter.public_paths(db, contents)
      assert paths["fr-FR"] == "/fr/#{slug}/hello"
      assert paths["de-DE"] == "https://de.example.test/#{slug}/hello"
    end

    @tag :canonical_urls
    test "the resolver is asked once per language", %{db: db, contents: contents} do
      resolver!(:host_for_counted)
      Process.put(:resolver_calls, 0)

      Presenter.public_paths(db, contents)

      assert Process.get(:resolver_calls) == length(contents)
    end

    # Pins today's behaviour, not a goal: core cannot tell that the module emitted no language
    # prefix, so a group slug equal to the prefixless primary language's code loses its segment.
    @tag :canonical_urls
    test "a prefixless primary language and a group slugged like its code lose the group segment" do
      resolver!()
      {:ok, _} = PhoenixKit.Settings.update_boolean_setting("default_language_no_prefix", true)
      g = Fx.group!(name: "En")
      assert g["slug"] == "en"
      post = Fx.post!("en", %{title: "Hello", slug: "hello"})
      Fx.publish!("en", post[:uuid])
      {en_db, _versions, en_contents} = load(post[:uuid])

      assert Presenter.public_paths(en_db, en_contents) ==
               %{"en-US" => "https://en.example.test/hello"}
    end
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
