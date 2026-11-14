defmodule PhoenixKit.Modules.Publishing.Web.Controller.PagerListingTest do
  @moduledoc """
  The public listing draws the pager the site's `publishing_pagination_style`
  names, and never one link per page.
  """

  # async: false — mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")
    {:ok, _} = Settings.update_setting("publishing_posts_per_page", "1")

    on_exit(fn ->
      Settings.update_setting("publishing_posts_per_page", "20")
      Settings.update_setting("publishing_pagination_style", "numbered")
    end)

    {:ok, group} = Groups.add_group("pager-#{System.unique_integer([:positive])}", mode: "slug")

    for i <- 1..12 do
      {:ok, post} =
        Posts.create_post(group["slug"], %{
          title: "Post #{i}",
          slug: "post-#{i}",
          content: "Body #{i}."
        })

      :ok = Versions.publish_version(group["slug"], post.uuid, 1)
    end

    %{slug: group["slug"]}
  end

  defp pager_links(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("nav[data-pager] a[href*=\"page=\"]")
    |> LazyHTML.attribute("href")
    |> Enum.uniq()
  end

  test "numbered by default, windowed", %{conn: conn, slug: slug} do
    {:ok, _} = Settings.update_setting("publishing_pagination_style", "fancy")
    html = get(conn, "/#{slug}?page=6") |> html_response(200)

    assert html =~ ~s(data-pager="numbered")
    links = pager_links(html)
    assert Enum.any?(links, &String.ends_with?(&1, "page=8"))
    # far pages are behind a gap, not one link each
    refute Enum.any?(links, &String.ends_with?(&1, "page=3"))
    assert length(links) < 10
  end

  test "compact and simple follow the setting", %{conn: conn, slug: slug} do
    {:ok, _} = Settings.update_setting("publishing_pagination_style", "compact")
    html = get(conn, "/#{slug}?page=2") |> html_response(200)
    assert html =~ ~s(data-pager="compact")
    assert html =~ ~r/<form[^>]*method="get"[^>]*action="\/#{slug}"/
    assert html =~ ~r/Page 2 of \d+/

    {:ok, _} = Settings.update_setting("publishing_pagination_style", "simple")
    html = get(conn, "/#{slug}?page=2") |> html_response(200)
    assert html =~ ~s(data-pager="simple")
    assert length(pager_links(html)) == 2
  end
end
