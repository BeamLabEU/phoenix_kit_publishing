defmodule PhoenixKit.Modules.Publishing.Web.CategoriesPickerTest do
  @moduledoc """
  The editor's category field.

  Two things here are easy to break and silent when broken: the route out to
  the management page (a category needs a parent, a slug and translations
  that a search box can't supply), and the picker noticing a category that
  was created while the editor sat open.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  setup do
    slug = "picker-#{System.unique_integer([:positive])}"
    {:ok, group} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "Filed", slug: "filed", content: "Body"})
    {:ok, news} = Categories.create_category(slug, %{"name" => "News"})

    %{slug: slug, group: group, post: post, news: news}
  end

  defp open_editor(ctx) do
    {:ok, view, html} =
      build_conn()
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{ctx.slug}/#{ctx.post[:uuid]}/edit")

    {view, html}
  end

  test "offers a way to make a category, in a new tab", ctx do
    {_view, html} = open_editor(ctx)

    assert html =~ "/admin/publishing/categories/#{ctx.slug}"

    # New tab specifically: the writer is mid-post with unsaved changes, and
    # navigating away to create a category must not cost them that.
    link =
      html
      |> String.split(~r/<a\s/)
      |> Enum.find(fn chunk -> chunk =~ "/admin/publishing/categories/#{ctx.slug}" end)

    assert link =~ ~s(target="_blank"), "must open in a new tab, not replace the editor"
    assert link =~ ~s(rel="noopener")
  end

  test "a category created while the editor is open becomes findable", ctx do
    {view, _html} = open_editor(ctx)

    # Made in the other tab, after this editor already loaded its list.
    {:ok, _} = Categories.create_category(ctx.slug, %{"name" => "Made Later"})

    render_hook(element(view, "#post-categories-picker-search"), "category_search", %{
      "q" => "made",
      "limit" => 8
    })

    assert_push_event(view, "category_results", %{results: results})

    assert Enum.any?(results, &(&1.label == "Made Later")),
           "searching a list loaded at mount makes the trip to the management " <>
             "page look like it failed"
  end

  test "already-filed categories aren't offered again", ctx do
    {view, _html} = open_editor(ctx)

    render_hook(element(view, "#post-categories-picker-search"), "category_search", %{
      "q" => "",
      "limit" => 8
    })

    assert_push_event(view, "category_results", %{results: before_pick})
    assert Enum.any?(before_pick, &(&1.uuid == ctx.news.uuid))

    render_hook(element(view, "#post-categories-picker-search"), "category_pick", %{
      "kind" => "category",
      "uuid" => ctx.news.uuid,
      "label" => "News"
    })

    render_hook(element(view, "#post-categories-picker-search"), "category_search", %{
      "q" => "",
      "limit" => 8
    })

    assert_push_event(view, "category_results", %{results: after_pick})

    refute Enum.any?(after_pick, &(&1.uuid == ctx.news.uuid)),
           "picking it twice does nothing, so offering it again is just noise"
  end

  test "a suggestion carries its parent chain", ctx do
    {:ok, parent} = Categories.create_category(ctx.slug, %{"name" => "Parent"})

    {:ok, _child} =
      Categories.create_category(ctx.slug, %{"name" => "Child", "parent_uuid" => parent.uuid})

    {view, _html} = open_editor(ctx)

    render_hook(element(view, "#post-categories-picker-search"), "category_search", %{
      "q" => "child",
      "limit" => 8
    })

    assert_push_event(view, "category_results", %{results: results})

    child_row = Enum.find(results, &(&1.label == "Child"))

    # Two categories can share a name under different parents; without this
    # the dropdown shows two identical rows.
    assert child_row.sublabel == "Parent"
  end
end
