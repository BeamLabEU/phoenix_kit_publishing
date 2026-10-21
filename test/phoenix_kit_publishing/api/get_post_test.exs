defmodule PhoenixKit.Modules.Publishing.API.GetPostTest do
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Publishing.{
    Constants,
    Posts,
    PublishingContent,
    PublishingPost,
    PublishingVersion,
    Versions
  }

  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo

  setup do
    Fx.languages!()
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "Hello", slug: "hello"})
    Fx.body!(g["slug"], post[:uuid], "# Body\n\ntext")
    %{g: g, post: post}
  end

  defp get(ref, extra \\ %{}),
    do: ApiCase.call("publishing.get_post", Map.merge(%{"post" => ref}, extra))

  test "by id and by group+slug: markdown, language, fields, revision", %{g: g, post: post} do
    for ref <- [%{"id" => post[:uuid]}, %{"group" => g["slug"], "slug" => "hello"}] do
      assert {:ok, body} = get(ref)
      assert body["id"] == post[:uuid] and body["title"] == "Hello" and body["status"] == "draft"
      assert body["markdown"] =~ "# Body"
      assert body["language"] == "en-US" and body["version"] == 1
      assert %{"og" => %{}, "tags" => [], "category_ids" => []} = body["fields"]
      assert body["revision"] =~ ~r/\A[0-9a-f]{64}\z/
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(body["content_updated_at"])
      refute Map.has_key?(body, "warnings")
    end
  end

  test "fields carry each stored value under its own key", %{g: g, post: post} do
    category = Fx.category!(g["slug"], "Fields Cat")
    image = Ecto.UUID.generate()
    og_image = Ecto.UUID.generate()

    {:ok, current} = Posts.read_post_by_uuid(post[:uuid], nil, 1)

    {:ok, _} =
      Posts.update_post(
        g["slug"],
        current,
        %{
          "description" => "desc-value",
          "seo_title" => "seo-value",
          "excerpt" => "excerpt-value",
          "featured" => true,
          "sitemap_exclude" => true,
          "featured_image_uuid" => image,
          "og_title" => "og-title-value",
          "og_description" => "og-description-value",
          "og_image_uuid" => og_image,
          "url_slug" => "url-slug-value",
          "category_uuids" => [category.uuid]
        },
        publish: false
      )

    assert {:ok, %{"fields" => fields}} = get(%{"id" => post[:uuid]})

    assert fields == %{
             "description" => "desc-value",
             "seo_title" => "seo-value",
             "excerpt" => "excerpt-value",
             "featured" => true,
             "sitemap_exclude" => true,
             "featured_image_id" => image,
             "og" => %{
               "title" => "og-title-value",
               "description" => "og-description-value",
               "image_id" => og_image
             },
             "tags" => [],
             "category_ids" => [category.uuid],
             "url_slug" => "url-slug-value"
           }
  end

  test "fields of a fresh post are empty or false, not shifted", %{post: post} do
    assert {:ok, %{"fields" => fields}} = get(%{"id" => post[:uuid]})
    assert fields["featured"] == false and fields["sitemap_exclude"] == false
    assert fields["og"] == %{"title" => nil, "description" => nil, "image_id" => nil}
    assert fields["seo_title"] == nil and fields["excerpt"] == nil
    assert fields["featured_image_id"] == nil
  end

  test "include_content false omits the markdown", %{post: post} do
    assert {:ok, body} = get(%{"id" => post[:uuid]}, %{"include_content" => false})
    refute Map.has_key?(body, "markdown")
  end

  test "the revision follows the values: changes with the body, not with a no-op read", %{
    g: g,
    post: post
  } do
    {:ok, %{"revision" => r1}} = get(%{"id" => post[:uuid]})
    {:ok, %{"revision" => r1b}} = get(%{"id" => post[:uuid]})
    assert r1 == r1b
    Fx.body!(g["slug"], post[:uuid], "changed")
    {:ok, %{"revision" => r2}} = get(%{"id" => post[:uuid]})
    refute r1 == r2
  end

  test "a missing language falls back with a warning, never as the requested language", %{
    post: post
  } do
    assert {:ok, body} = get(%{"id" => post[:uuid]}, %{"language" => "de-DE"})
    assert body["language"] == "en-US"
    assert body["title"] == "Hello"
    assert body["markdown"] =~ "# Body"
    assert [%{"code" => "language_missing", "message" => message}] = body["warnings"]
    assert message =~ "de-DE" and message =~ "en-US"
  end

  test "no language asked and the primary row missing: the fallback names the primary language",
       %{g: g, post: post} do
    Fx.translation!(g["slug"], post[:uuid], "de-DE", "Hallo", "Inhalt")
    drop_content(post[:uuid], "en-US")

    assert {:ok, body} = get(%{"id" => post[:uuid]})
    assert body["language"] == "de-DE" and body["title"] == "Hallo"
    assert [%{"code" => "language_missing", "message" => message}] = body["warnings"]
    assert message =~ "primary language en-US"
  end

  test "no language asked and only a legacy base-code row: the row is shown as stored and nothing is repaired",
       %{post: post} do
    Repo.update_all(
      from(c in PublishingContent, where: c.version_uuid == ^Fx.version(post[:uuid]).uuid),
      set: [language: "en"]
    )

    before = Fx.table_state()
    assert {:ok, body} = get(%{"id" => post[:uuid]})
    assert body["title"] == "Hello" and body["markdown"] =~ "# Body"
    assert Fx.table_state() == before
    assert Fx.content(post[:uuid], "en") != nil and Fx.content(post[:uuid], "en-US") == nil
  end

  test "a language that is not enabled and not present is language_not_enabled with allowed", %{
    post: post
  } do
    assert {:error, :validation_failed, _,
            %{errors: [%{reason: "language_not_enabled", allowed: allowed}]}} =
             get(%{"id" => post[:uuid]}, %{"language" => "xx"})

    assert "en-US" in allowed
  end

  test "a language the post has stays readable after it is disabled", %{
    g: g,
    post: post
  } do
    Fx.translation!(g["slug"], post[:uuid], "de-DE", "Hallo", "Inhalt")
    Fx.languages!(["en-US"])

    assert {:ok, %{"language" => "de-DE", "title" => "Hallo"}} =
             get(%{"id" => post[:uuid]}, %{"language" => "de-DE"})
  end

  test "version: default is the active one, else the latest; an explicit missing one is version_not_found",
       %{g: g, post: post} do
    {:ok, _} = Versions.create_new_version(g["slug"], post, %{}, %{})
    assert {:ok, %{"version" => 2}} = get(%{"id" => post[:uuid]})
    Fx.publish!(g["slug"], post[:uuid], 1)
    assert {:ok, %{"version" => 1, "status" => "published"}} = get(%{"id" => post[:uuid]})
    assert {:ok, %{"version" => 2}} = get(%{"id" => post[:uuid]}, %{"version" => 2})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "version_not_found"}]}} =
             get(%{"id" => post[:uuid]}, %{"version" => 9})
  end

  test "an explicit draft version with an extra language leaves the summary on the live version",
       %{
         g: g,
         post: post
       } do
    Fx.publish!(g["slug"], post[:uuid], 1)
    {:ok, _} = Versions.create_new_version(g["slug"], post, %{}, %{})
    Fx.translation!(g["slug"], post[:uuid], "de-DE", "Hallo", "Inhalt", 2)

    assert {:ok, draft} = get(%{"id" => post[:uuid]}, %{"version" => 2, "language" => "de-DE"})
    assert {:ok, live} = get(%{"id" => post[:uuid]})

    assert draft["version"] == 2 and draft["language"] == "de-DE" and draft["title"] == "Hallo"
    assert draft["status"] == "published"
    assert draft["languages"] == ["en-US"] and draft["languages"] == live["languages"]
    assert draft["public_paths"] == live["public_paths"]
    assert Map.keys(draft["public_paths"]) == ["en-US"]
  end

  test "a trashed post by id is not_found with context.trashed; list_posts shows it", %{
    g: g,
    post: post
  } do
    {:ok, _} = Posts.trash_post(g["slug"], post[:uuid])
    assert {:error, :not_found, message, %{trashed: true}} = get(%{"id" => post[:uuid]})
    assert message =~ "trash"

    assert {:ok, %{"posts" => posts}} =
             ApiCase.call("publishing.list_posts", %{"group" => g["slug"], "status" => "trashed"})

    assert Enum.any?(posts, &(&1["id"] == post[:uuid]))
  end

  test "a trashed post by group+slug is a plain not_found (the slug lookup excludes trashed posts)",
       %{g: g, post: post} do
    {:ok, _} = Posts.trash_post(g["slug"], post[:uuid])
    assert {:error, :not_found, _, context} = get(%{"group" => g["slug"], "slug" => "hello"})
    refute Map.has_key?(context, :trashed)
  end

  test "a post without any version is not_found, not a version_not_found about a version nobody asked for",
       %{post: post} do
    Repo.delete_all(from(v in PublishingVersion, where: v.post_uuid == ^post[:uuid]))
    assert {:error, :not_found, message, _} = get(%{"id" => post[:uuid]})
    assert message =~ "no versions"

    assert {:error, :validation_failed, _, %{errors: [%{reason: "version_not_found"}]}} =
             get(%{"id" => post[:uuid]}, %{"version" => 1})
  end

  test "a stale active pointer is shown as stored: the read repairs nothing", %{g: g, post: post} do
    Fx.publish!(g["slug"], post[:uuid], 1)

    # The pointer now names a version that is not published; only a write would heal it.
    Repo.update_all(
      from(v in PublishingVersion, where: v.post_uuid == ^post[:uuid]),
      set: [status: "draft"]
    )

    before = Fx.table_state()
    assert {:ok, first} = get(%{"id" => post[:uuid]})
    assert {:ok, second} = get(%{"id" => post[:uuid]})
    assert Fx.table_state() == before
    assert Fx.db_post(post[:uuid]).active_version_uuid != nil
    assert first["revision"] == second["revision"]
  end

  test "an empty post older than the grace period is read, not auto-trashed", %{g: g} do
    empty = Fx.post!(g["slug"], %{title: Constants.default_title(), slug: "empty-one"})

    Repo.update_all(
      from(p in PublishingPost, where: p.uuid == ^empty[:uuid]),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -3_600, :second)]
    )

    before = Fx.table_state()
    assert {:ok, %{"status" => "draft"}} = get(%{"id" => empty[:uuid]})
    assert Fx.table_state() == before
    assert Fx.db_post(empty[:uuid]).trashed_at == nil
  end

  test "bad refs: invalid_ref, unknown id, uncastable id", %{post: post} do
    assert {:error, :validation_failed, _, %{errors: [%{reason: "invalid_ref"}]}} =
             get(%{"id" => post[:uuid], "group" => "x"})

    assert {:error, :not_found, _, _} = get(%{"id" => Ecto.UUID.generate()})
    assert {:error, :not_found, _, _} = get(%{"id" => "not-a-uuid"})
  end

  test "a timestamp post is read by id" do
    ts = Fx.group!(mode: "timestamp")
    p = Fx.post!(ts["slug"], %{title: "Stamp"})
    assert {:ok, %{"id" => id, "mode" => "timestamp"}} = get(%{"id" => p[:uuid]})
    assert id == p[:uuid]
    assert {:error, :not_found, _, _} = get(%{"group" => ts["slug"], "slug" => "anything"})
  end

  defp drop_content(post_uuid, language) do
    version = Fx.version(post_uuid)

    Repo.delete_all(
      from(c in PublishingContent,
        where: c.version_uuid == ^version.uuid and c.language == ^language
      )
    )
  end

  test "tags are derived from the body hashtags and read-only", %{g: g, post: post} do
    Fx.body!(g["slug"], post[:uuid], "text #alpha #beta")
    assert {:ok, %{"fields" => %{"tags" => tags}}} = get(%{"id" => post[:uuid]})
    assert Enum.sort(tags) == ["alpha", "beta"]
  end
end
