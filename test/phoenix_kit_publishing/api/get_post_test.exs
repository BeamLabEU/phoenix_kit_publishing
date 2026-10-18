defmodule PhoenixKit.Modules.Publishing.API.GetPostTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.{Posts, Versions}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

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
      assert is_binary(body["content_updated_at"]) or body["content_updated_at"] == nil
    end
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
    assert [%{"code" => "language_missing"}] = body["warnings"]
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

  test "a trashed post is not_found with context.trashed; list_posts shows it", %{
    g: g,
    post: post
  } do
    {:ok, _} = Posts.trash_post(g["slug"], post[:uuid])
    assert {:error, :not_found, message, %{trashed: true}} = get(%{"id" => post[:uuid]})
    assert message =~ "trash"
    assert {:error, :not_found, _, _} = get(%{"group" => g["slug"], "slug" => "hello"})
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

  test "tags are derived from the body hashtags and read-only", %{g: g, post: post} do
    Fx.body!(g["slug"], post[:uuid], "text #alpha #beta")
    assert {:ok, %{"fields" => %{"tags" => tags}}} = get(%{"id" => post[:uuid]})
    assert Enum.sort(tags) == ["alpha", "beta"]
  end
end
