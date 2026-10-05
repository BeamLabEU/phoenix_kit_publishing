defmodule PhoenixKit.Modules.Publishing.UpdatePostPublishTest do
  @moduledoc """
  `update_post/4` with `"status" => "published"` publishes.

  It used to save the content, drop the status without a word and answer
  `{:ok, post}` — a draft. A caller that builds a post through the API (an
  AI agent writing one did) had no way to know the post never went live
  short of reading it back.

  The status is still never *written* by the save: which version is live is
  decided by `publish_version/4`, under the post's lock. The save now takes
  that step itself, and says so when the step is refused.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.Posts

  setup do
    slug = "updpub-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")

    {:ok, post} =
      Posts.create_post(slug, %{
        title: "Written by the API",
        slug: "written-by-agent",
        content: "v1"
      })

    %{slug: slug, post: post}
  end

  defp stored(post_uuid) do
    db_post = DBStorage.get_post_by_uuid(post_uuid)
    version = DBStorage.get_version(post_uuid, 1)
    {db_post.active_version_uuid, version.uuid, version.status}
  end

  test "asking for published makes the saved version the live one", ctx do
    assert ctx.post.metadata[:status] == "draft"

    assert {:ok, saved} =
             Publishing.update_post(ctx.slug, ctx.post, %{
               "content" => "the finished text",
               "status" => "published"
             })

    # what the caller is told
    assert saved.metadata[:status] == "published"
    assert saved.content =~ "the finished text"

    # and what is true: status and pointer moved together
    assert {active, version_uuid, "published"} = stored(ctx.post.uuid)
    assert active == version_uuid

    # a fresh read agrees
    {:ok, read} = Publishing.read_post_by_uuid(ctx.post.uuid, "en", 1)
    assert read.metadata[:status] == "published"
  end

  test "a save that does not ask leaves a draft a draft", ctx do
    assert {:ok, saved} = Publishing.update_post(ctx.slug, ctx.post, %{"content" => "more"})

    assert saved.metadata[:status] == "draft"
    assert {nil, _version_uuid, "draft"} = stored(ctx.post.uuid)
  end

  test "publish: false saves only, whatever the params ask — the editor's contract", ctx do
    assert {:ok, saved} =
             Publishing.update_post(
               ctx.slug,
               ctx.post,
               %{"content" => "typed", "status" => "published"},
               %{publish: false}
             )

    assert saved.content =~ "typed"
    assert saved.metadata[:status] == "draft"
    assert {nil, _version_uuid, "draft"} = stored(ctx.post.uuid)
  end

  test "an already live version is saved, not published a second time", ctx do
    :ok = Publishing.publish_version(ctx.slug, ctx.post.uuid, 1)
    {:ok, live} = Publishing.read_post_by_uuid(ctx.post.uuid, "en", 1)
    before = stored(ctx.post.uuid)

    assert {:ok, saved} =
             Publishing.update_post(ctx.slug, live, %{
               "content" => "an edit to the live text",
               "status" => "published"
             })

    assert saved.metadata[:status] == "published"
    assert saved.content =~ "an edit to the live text"
    assert stored(ctx.post.uuid) == before
  end

  # A post that cannot go live is refused by the save itself, before
  # anything is written — the caller gets the reason, never an :ok and a
  # draft. (`{:publish_failed, reason}` is for a publish refused AFTER the
  # content saved; the save's own checks leave little that reaches it.)
  test "a post that cannot be published is an error, not a quiet draft", ctx do
    assert {:error, reason} =
             Publishing.update_post(ctx.slug, ctx.post, %{
               "title" => "",
               "content" => "",
               "status" => "published"
             })

    assert reason == :title_required
    assert {nil, _version_uuid, "draft"} = stored(ctx.post.uuid)
  end

  # The one refusal that comes AFTER the save: the translation's own title is
  # fine, but the primary language has none, so publish_version says no.
  test "a publish refused after the save is {:publish_failed, reason}, the save standing", ctx do
    primary = LanguageHelpers.get_primary_language()
    version = DBStorage.get_version(ctx.post.uuid, 1)
    primary_content = DBStorage.get_content(version.uuid, primary)
    {:ok, _} = DBStorage.update_content(primary_content, %{title: ""})

    {:ok, translation} = Publishing.add_language_to_post(ctx.slug, ctx.post.uuid, "et", 1)

    assert {:error, {:publish_failed, :title_required}} =
             Publishing.update_post(ctx.slug, translation, %{
               "title" => "Tõlge",
               "content" => "saved anyway",
               "status" => "published"
             })

    assert {nil, _version_uuid, "draft"} = stored(ctx.post.uuid)
    assert DBStorage.get_content(version.uuid, "et").content =~ "saved anyway"
  end
end
