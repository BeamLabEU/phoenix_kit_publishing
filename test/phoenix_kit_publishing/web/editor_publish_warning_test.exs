defmodule PhoenixKit.Modules.Publishing.Web.EditorPublishWarningTest do
  @moduledoc """
  The warning that saving will take the live version down.

  It fired whenever the status select read "published" and the post had more
  than one version, and claimed every other version was about to be archived.
  Both halves were wrong.

  `archive_other_published_versions!` only touches versions whose own status
  is "published", and only one can hold that at a time — so a post with five
  versions loses ONE, not four. And on the version that is ALREADY live there
  is nothing to take down: it is its own target. The warning fired hardest on
  the save that changes nothing about publication.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions

  @warning "which is live now"

  setup do
    slug = "publishwarn-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "P", slug: "p", content: "Body"})
    %{slug: slug, post: post}
  end

  defp open(ctx, version) do
    {:ok, view, html} =
      build_conn()
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{ctx.slug}/#{ctx.post[:uuid]}/edit?v=#{version}")

    {view, html}
  end

  # The warning is about what SAVING would do, so it only appears once the
  # status select actually reads "published".
  defp choose_published(view) do
    render_change(view, "update_meta", %{
      "status" => "published",
      "_target" => ["status"]
    })
  end

  test "no warning while editing the version that is already live", ctx do
    :ok = Versions.publish_version(ctx.slug, ctx.post[:uuid], 1)
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post[:uuid], 1)
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post[:uuid], 1)

    {view, _} = open(ctx, 1)
    html = choose_published(view)

    refute html =~ @warning,
           "saving the live version publishes nothing new and archives nothing"
  end

  test "warns, and names the one version it will take down", ctx do
    :ok = Versions.publish_version(ctx.slug, ctx.post[:uuid], 1)
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post[:uuid], 1)
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post[:uuid], 1)
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post[:uuid], 1)

    {view, _} = open(ctx, 4)
    html = choose_published(view)

    assert html =~ @warning, "taking down the live version deserves saying so"

    # Only the live version is archived — never "the other 3".
    assert html =~ "archive v1"
    refute html =~ "the other"
  end

  test "no warning when nothing is published yet", ctx do
    {:ok, _} = Versions.create_version_from(ctx.slug, ctx.post[:uuid], 1)

    {view, _} = open(ctx, 2)
    html = choose_published(view)

    refute html =~ @warning, "there is nothing live to take down"
  end
end
