defmodule PhoenixKit.Modules.Publishing.Web.PagerTest do
  @moduledoc """
  The listing pager (`Web.HTML.pager/1`) in each `publishing_pagination_style`.
  The bug it replaces: one button per page, so a group with 62 pages pushed
  the page into a horizontal scroll.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML

  defp pager(style, page, total) do
    rendered_to_string(
      PublishingHTML.pager(%{
        style: style,
        page: page,
        total_pages: total,
        path: &"/news?page=#{&1}",
        form_action: "/news",
        __changed__: nil
      })
    )
  end

  # The page numbers a window links to, in order (the current page included).
  defp numbers(html, window) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-window=\"#{window}\"] .join-item")
    |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))
  end

  defp classes(html, window) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-window=\"#{window}\"]")
    |> LazyHTML.attribute("class")
    |> hd()
    |> String.split()
  end

  defp count(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  describe "pagination_window/3" do
    test "radius 1 keeps the first, the last and one either side" do
      assert PublishingHTML.pagination_window(31, 62, 1) == [1, :gap, 30, 31, 32, :gap, 62]
      assert PublishingHTML.pagination_window(1, 62, 1) == [1, 2, :gap, 62]
      assert PublishingHTML.pagination_window(3, 5, 1) == [1, 2, 3, 4, 5]
    end
  end

  describe "pagination_style/1" do
    test "a known style, else numbered" do
      for style <- PublishingHTML.pagination_styles(),
          do: assert(PublishingHTML.pagination_style(style) == style)

      for other <- [nil, "", "fancy", 3],
          do: assert(PublishingHTML.pagination_style(other) == "numbered")
    end
  end

  describe "numbered" do
    test "a window per screen width, never every page" do
      html = pager("numbered", 31, 62)

      assert numbers(html, "narrow") == ["1", "…", "30", "31", "32", "…", "62"]
      assert numbers(html, "wide") == ["1", "…", "29", "30", "31", "32", "33", "…", "62"]
      # the narrow window shows below `sm`, the wide one from it
      assert "sm:hidden" in classes(html, "narrow")
      assert "hidden" in classes(html, "wide") and "sm:inline-flex" in classes(html, "wide")
      refute html =~ "page=40"
    end

    test "previous and next only where there is a page to go to" do
      first = pager("numbered", 1, 62)
      assert count(first, "a[rel=prev]") == 0
      assert count(first, "a[rel=next][href=\"/news?page=2\"]") == 1

      last = pager("numbered", 62, 62)
      assert count(last, "a[rel=prev][href=\"/news?page=61\"]") == 1
      assert count(last, "a[rel=next]") == 0
    end

    test "the current page is marked and not a link" do
      html = pager("numbered", 7, 62)
      assert count(html, "[data-window=wide] [aria-current=page]") == 1
      assert count(html, "[data-window=wide] a[href=\"/news?page=7\"]") == 0
    end

    test "the row wraps instead of widening the page" do
      assert pager("numbered", 31, 62) =~ ~r/<nav[^>]*class="[^"]*flex-wrap/
    end
  end

  describe "compact" do
    test "page X of Y and a page box, no numbers" do
      html = pager("compact", 7, 62)

      assert html =~ "Page 7 of 62"
      assert count(html, ".join-item") == 0

      assert count(
               html,
               "form[method=get][action=\"/news\"] input[name=page][type=number][min=\"1\"][max=\"62\"][value=\"7\"]"
             ) == 1

      assert count(html, "a[rel=prev]") == 1
      assert count(html, "a[rel=next]") == 1
      # on a phone the arrows alone, so the row fits
      assert count(html, "a[rel=prev] span.hidden.sm\\:inline") == 1
    end
  end

  describe "simple" do
    test "previous and next as words, nothing else" do
      html = pager("simple", 7, 62)

      assert count(html, ".join-item") == 0
      assert count(html, "form") == 0
      refute html =~ "Page 7 of 62"
      assert html =~ ~r/<a[^>]*rel="prev"[^>]*>\s*« <span[^>]*>Previous page<\/span>/
      assert html =~ ~r/<a[^>]*rel="next"[^>]*>\s*<span[^>]*>Next page<\/span> »/
      # the words stay on every screen width
      assert count(html, "a span.hidden") == 0
    end
  end

  test "an unknown style draws the numbered pager; a page past the end draws the last" do
    html = pager("fancy", 99, 62)
    assert html =~ ~s(data-pager="numbered")
    assert count(html, "a[rel=next]") == 0
    assert numbers(html, "wide") |> List.last() == "62"
  end
end
