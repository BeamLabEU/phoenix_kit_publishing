defmodule PhoenixKit.Modules.Publishing.Web.Controller.VersionAccessGateTest do
  @moduledoc """
  `/<group>/<slug>/v/<N>` shows a live post's past. Both halves matter, and
  each was reachable on its own:

    * a post taken down still served every old version, because the archived
      row kept the `published_at` the gate read as "was public once";
    * a draft that never shipped could be given a publish date and set to
      Archived from an ordinary save — only `"published"` is reserved to
      `publish_version/4` — forging that same shape.

  Both handed the full body to an anonymous reader. The tests below are the
  withdrawn-content cases; the first one pins that ordinary history still
  works, since the cheap fix for the others is to close version browsing
  altogether.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostRendering
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)

    {:ok, group} = Groups.add_group("vgate-#{System.unique_integer([:positive])}", mode: "slug")
    slug = group["slug"]

    {:ok, post} =
      Posts.create_post(slug, %{title: "Gate", slug: "gate", content: "FIRST-CUT"})

    :ok = Versions.publish_version(slug, post.uuid, 1)

    {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)
    {:ok, _} = Posts.update_post(slug, read, %{"allow_version_access" => "true"}, %{})

    %{slug: slug, post: post}
  end

  defp get_version(ctx, n), do: build_conn() |> get("/#{ctx.slug}/gate/v/#{n}")

  # The version segment used to reach the int4 column unbounded and 500 with
  # DBConnection.EncodeError; it is the same invalid-version outcome as "v/0".
  test "a version number beyond int4 is the invalid-version fallback, not a 500", ctx do
    conn = get_version(ctx, 99_999_999_999)

    assert conn.status == 302
    assert redirected_to(conn) =~ "/#{ctx.slug}"
  end

  test "a superseded version stays readable behind the live one", ctx do
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)
    {:ok, v2} = Publishing.read_post_by_uuid(ctx.post.uuid, "en", 2)
    {:ok, _} = Posts.update_post(ctx.slug, v2, %{"content" => "SECOND-CUT"}, %{})
    :ok = Versions.publish_version(ctx.slug, ctx.post.uuid, 2)

    older = get_version(ctx, 1)
    assert older.status == 200
    assert older.resp_body =~ "FIRST-CUT"
  end

  test "history stays readable with the listing cache disabled", ctx do
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)
    :ok = Versions.publish_version(ctx.slug, ctx.post.uuid, 2)
    {:ok, _} = Settings.update_boolean_setting("publishing_memory_cache_enabled", false)

    assert get_version(ctx, 1).status == 200
  end

  test "cache misses use the live access setting instead of the historical one", ctx do
    {:ok, v2} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)
    {:ok, _} = Posts.update_post(ctx.slug, v2, %{"allow_version_access" => "false"})
    :ok = Versions.publish_version(ctx.slug, ctx.post.uuid, 2)
    {:ok, old} = Publishing.read_post_by_uuid(ctx.post.uuid, "en", 1)
    {:ok, _} = Settings.update_boolean_setting("publishing_memory_cache_enabled", false)

    assert PostRendering.get_cached_version_info(ctx.slug, old) == {false, 2}
    refute PostRendering.publicly_browsable_version?(ctx.slug, old, 1)
  end

  test "the version dropdown leaves out an archived draft that never shipped", ctx do
    {:ok, v2} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)
    {:ok, _} = Posts.update_post(ctx.slug, v2, %{"status" => "archived"})
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)
    :ok = Versions.publish_version(ctx.slug, ctx.post.uuid, 3)
    {:ok, live} = Publishing.read_post_by_uuid(ctx.post.uuid, "en", 3)

    dropdown = PostRendering.build_version_dropdown(ctx.slug, live, "en")
    assert Enum.map(dropdown.versions, & &1.version) == [3, 1]
  end

  test "taking the post down closes its version history", ctx do
    assert get_version(ctx, 1).status == 200

    :ok = Versions.unpublish_post(ctx.slug, ctx.post.uuid, target_status: "archived")

    withdrawn = get_version(ctx, 1)
    refute withdrawn.status == 200
    refute withdrawn.resp_body =~ "FIRST-CUT"
  end

  test "a draft dressed up as history is not history", ctx do
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post.uuid, 1)
    {:ok, v2} = Publishing.read_post_by_uuid(ctx.post.uuid, "en", 2)

    # Both fields an ordinary save is allowed to write.
    {:ok, _} =
      Posts.update_post(
        ctx.slug,
        v2,
        %{
          "content" => "NEVER-SHIPPED",
          "status" => "archived",
          "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        %{}
      )

    forged = get_version(ctx, 2)
    refute forged.status == 200
    refute forged.resp_body =~ "NEVER-SHIPPED"
  end
end
