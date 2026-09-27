defmodule PhoenixKit.Modules.Publishing.Integration.SitemapSourceTest do
  @moduledoc """
  Boundary test against core's ACTUAL sitemap source
  (`PhoenixKit.Modules.Sitemap.Sources.Publishing`): the `sitemap_exclude`
  knobs publishing writes must land where core reads them —
  `group["sitemap_exclude"]` on `Publishing.list_groups/0` maps and
  `metadata.sitemap_exclude` on `Publishing.list_posts/2` maps. A shape
  drift here is invisible to every unit test, since core only pattern-matches.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Sitemap.Sources.Publishing, as: SitemapSource
  alias PhoenixKit.Settings

  @base_url "https://sitemap.example.test"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    :ok
  end

  defp published_post(group_slug, post_slug, params \\ %{}) do
    {:ok, post} =
      Posts.create_post(group_slug, %{title: post_slug, slug: post_slug, content: "body"})

    if params != %{} do
      {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)
      {:ok, _} = Posts.update_post(group_slug, read, params, %{})
    end

    :ok = Versions.publish_version(group_slug, post.uuid, 1)
    post
  end

  defp locs, do: SitemapSource.collect(base_url: @base_url) |> Enum.map(& &1.loc)

  defp has_loc?(locs, suffix), do: Enum.any?(locs, &String.ends_with?(&1, suffix))

  test "a flagged group's listing and posts are absent, an unflagged one's are present" do
    n = System.unique_integer([:positive])
    {:ok, kept} = Groups.add_group("kept-#{n}", mode: "slug")
    {:ok, gone} = Groups.add_group("gone-#{n}", mode: "slug")
    {:ok, _} = Groups.update_group(gone["slug"], %{"sitemap_exclude" => "true"})

    published_post(kept["slug"], "kept-post")
    published_post(gone["slug"], "gone-post")

    assert SitemapSource.enabled?()
    locs = locs()

    assert has_loc?(locs, "/#{kept["slug"]}")
    assert has_loc?(locs, "/#{kept["slug"]}/kept-post")
    refute has_loc?(locs, "/#{gone["slug"]}")
    refute has_loc?(locs, "/#{gone["slug"]}/gone-post")
  end

  test "a flagged post is absent while its group and an unflagged sibling stay" do
    {:ok, group} = Groups.add_group("mixed-#{System.unique_integer([:positive])}", mode: "slug")
    slug = group["slug"]

    published_post(slug, "listed-post")
    published_post(slug, "hidden-post", %{"sitemap_exclude" => "true"})

    # The boundary shapes core matches, checked directly before the URLs.
    assert %{"sitemap_exclude" => false} =
             Enum.find(Publishing.list_groups(), &(&1["slug"] == slug))

    assert %{metadata: %{sitemap_exclude: true, status: "published"}} =
             Enum.find(Publishing.list_posts(slug), &(&1.slug == "hidden-post"))

    locs = locs()
    assert has_loc?(locs, "/#{slug}")
    assert has_loc?(locs, "/#{slug}/listed-post")
    refute has_loc?(locs, "/#{slug}/hidden-post")
  end
end
