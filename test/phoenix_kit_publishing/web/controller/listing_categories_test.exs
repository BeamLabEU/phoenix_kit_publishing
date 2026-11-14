defmodule PhoenixKit.Modules.Publishing.Web.Controller.ListingCategoriesTest do
  @moduledoc """
  Categories on the public pages: chips on the listing cards, the listing's
  category filter, the post page's chip position and "more from this
  category", the archive's SEO title and description, and a heading order
  that never skips a level.
  """

  # async: false — mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")
    {:ok, _} = Settings.update_setting("publishing_posts_per_page", "20")

    {:ok, group} = Groups.add_group("cats-#{System.unique_integer([:positive])}", mode: "slug")
    slug = group["slug"]

    {:ok, billing} =
      Categories.create_category(slug, %{
        "name" => "Billing",
        "color" => "#4f46e5",
        "icon" => "hero-banknotes",
        "seo_title" => "Billing releases",
        "seo_description" => "Every billing release."
      })

    {:ok, invoices} =
      Categories.create_category(slug, %{"name" => "Invoices", "parent_uuid" => billing.uuid})

    {:ok, crm} = Categories.create_category(slug, %{"name" => "CRM", "color" => "accent"})
    {:ok, other} = Categories.create_category(slug, %{"name" => "Other"})

    post = fn title, categories ->
      {:ok, p} =
        Posts.create_post(slug, %{title: title, slug: slugify(title), content: "Body."})

      {:ok, _} = Categories.replace_post_categories(p.uuid, Enum.map(categories, & &1.uuid))
      :ok = Versions.publish_version(slug, p.uuid, 1)
      p
    end

    posts = %{
      b1: post.("Billing one", [billing]),
      b2: post.("Billing two", [billing]),
      inv: post.("Invoice post", [invoices]),
      crm: post.("CRM post", [crm]),
      none: post.("Plain post", [])
    }

    _ = other

    %{slug: slug, cats: %{billing: billing, invoices: invoices, crm: crm}, posts: posts}
  end

  defp slugify(title), do: title |> String.downcase() |> String.replace(" ", "-")

  defp settings!(slug, attrs), do: {:ok, _} = Groups.update_group(slug, attrs)

  defp doc(html), do: LazyHTML.from_document(html)
  defp q(html, selector), do: html |> doc() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> q(selector) |> Enum.count()
  defp texts(html, selector), do: html |> q(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))

  describe "chips on the listing cards" do
    test "off by default; on, each card shows its categories in colour", %{conn: conn, slug: slug} do
      html = get(conn, "/#{slug}") |> html_response(200)
      assert count(html, "article [data-category]") == 0

      settings!(slug, %{"listing_show_categories" => "true"})
      html = get(build_conn(), "/#{slug}") |> html_response(200)

      [chip] =
        q(html, "article:has(a[href$='/billing-one']) [data-category=billing]") |> Enum.to_list()

      assert LazyHTML.attribute(chip, "style") == ["--pk-cat: #4f46e5"]
      assert LazyHTML.attribute(chip, "href") == ["/#{slug}/category/billing"]

      assert count(
               html,
               "article:has(a[href$='/billing-one']) [data-category=billing] .hero-banknotes"
             ) == 1

      assert count(html, "article:has(a[href$='/plain-post']) [data-category]") == 0
    end

    test "the minimal layout shows them as labels inside its row link", %{conn: conn, slug: slug} do
      settings!(slug, %{"listing_show_categories" => "true", "listing_layout" => "minimal"})
      html = get(conn, "/#{slug}") |> html_response(200)

      assert count(html, "li a span[data-category=crm]") == 1
      assert count(html, "li a a") == 0
    end
  end

  describe "the category filter" do
    setup %{slug: slug} do
      settings!(slug, %{"listing_category_filter" => "true", "newest_enabled" => "true"})
      :ok
    end

    test "one category shows its posts and its subcategories' posts, without bands", %{
      conn: conn,
      slug: slug
    } do
      html = get(conn, "/#{slug}?category=billing") |> html_response(200)

      titles = texts(html, "article h2")
      assert Enum.sort(titles) == ["Billing one", "Billing two", "Invoice post"]
      refute html =~ ~s(>\n              Latest\n)

      assert texts(html, "[data-category-filter] a[aria-current=true]")
             |> Enum.map(&String.split(&1))
             |> Enum.map(&hd/1) == ["Billing"]
    end

    test "several categories at once show any of them; the filter row has counts", %{
      conn: conn,
      slug: slug
    } do
      html = get(conn, "/#{slug}?category=crm,invoices") |> html_response(200)
      assert Enum.sort(texts(html, "article h2")) == ["CRM post", "Invoice post"]

      # Billing counts its subcategory's post; Other has no posts and is left out
      filter = texts(html, "[data-category-filter] a[data-category]")
      assert "Billing 3" in Enum.map(filter, &String.replace(&1, ~r/\s+/, " "))
      refute Enum.any?(filter, &(&1 =~ "Other"))

      # a selected link removes itself; an unselected one adds itself
      assert count(
               html,
               "[data-category-filter] a[data-category=crm][href='/#{slug}?category=invoices']"
             ) == 1

      assert count(
               html,
               "[data-category-filter] a[data-category=billing][href='/#{slug}?category=crm%2Cinvoices%2Cbilling']"
             ) == 1
    end

    test "the pager and the page box keep the filter", %{conn: conn, slug: slug} do
      {:ok, _} = Settings.update_setting("publishing_posts_per_page", "1")
      {:ok, _} = Settings.update_setting("publishing_pagination_style", "compact")

      on_exit(fn ->
        Settings.update_setting("publishing_posts_per_page", "20")
        Settings.update_setting("publishing_pagination_style", "numbered")
      end)

      html = get(conn, "/#{slug}?category=billing") |> html_response(200)

      assert count(html, "nav[data-pager] a[rel=next][href='/#{slug}?page=2&category=billing']") ==
               1

      assert count(html, "nav[data-pager] form input[type=hidden][name=category][value=billing]") ==
               1

      html = get(build_conn(), "/#{slug}?page=2&category=billing") |> html_response(200)
      assert length(texts(html, "article h2")) == 1
    end

    test "a pick past twenty drops the oldest, never the new one" do
      current = Enum.map(1..20, &"c#{&1}")

      href =
        PublishingHTML.category_filter_href(
          %{category_filter: current, current_language: "en", group: %{"slug" => "news"}},
          "new"
        )

      [_, query] = String.split(href, "?")
      slugs = URI.decode_query(query)["category"] |> String.split(",")
      assert length(slugs) == 20 and List.last(slugs) == "new" and hd(slugs) == "c2"
    end

    test "unknown slugs are dropped; with the filter off the parameter is ignored", %{
      conn: conn,
      slug: slug
    } do
      html = get(conn, "/#{slug}?category=nope,crm") |> html_response(200)
      assert texts(html, "article h2") == ["CRM post"]

      settings!(slug, %{"listing_category_filter" => "false"})
      html = get(build_conn(), "/#{slug}?category=crm") |> html_response(200)
      assert length(texts(html, "article h2, section h3")) == 5
      assert count(html, "[data-category-filter]") == 0
    end
  end

  describe "the post page" do
    test "chips go above the title, beside the date, or after the content", %{
      conn: conn,
      slug: slug
    } do
      settings!(slug, %{"show_categories" => "true"})

      for {position, selector} <- [
            {"top", "header > div[data-category] ~ h1, header > div:has(> [data-category]) + h1"},
            {"date", "header div:has(time) > div > [data-category=billing]"},
            {"bottom", "article > div:has(> [data-category=billing]):not(header *)"}
          ] do
        settings!(slug, %{"category_chips_position" => position})
        html = get(build_conn(), "/#{slug}/billing-one") |> html_response(200)
        assert count(html, "[data-category=billing]") == 1, position
        assert count(html, selector) >= 1, "#{position}: #{selector}"
      end

      _ = conn
    end

    test "more from this category: newest first, this post left out, only shared categories", %{
      conn: conn,
      slug: slug
    } do
      html = get(conn, "/#{slug}/billing-one") |> html_response(200)
      assert count(html, "[data-related-posts]") == 0

      settings!(slug, %{"related_posts" => "3"})
      html = get(build_conn(), "/#{slug}/billing-one") |> html_response(200)

      assert texts(html, "[data-related-posts] h2") == ["More from Billing"]
      assert texts(html, "[data-related-posts] li") == ["Billing two"]
    end
  end

  test "a category archive uses the category's SEO title and description", %{
    conn: conn,
    slug: slug
  } do
    html = get(conn, "/#{slug}/category/billing") |> html_response(200)
    assert html =~ ~s(<meta property="og:title" content="Billing releases">)
    assert html =~ ~s(content="Every billing release.")

    html = get(build_conn(), "/#{slug}/category/crm") |> html_response(200)
    assert html =~ ~r/og:title" content="[^"]+ · CRM"/
  end

  describe "headings" do
    test "never skip a level, in every layout and band style", %{
      conn: conn,
      slug: slug,
      posts: posts
    } do
      {:ok, _} = Posts.update_post(slug, posts.b1, %{"featured" => "true"}, %{})

      for layout <- ~w(grid list minimal), style <- ~w(classic cover cover_panel minimal top) do
        settings!(slug, %{
          "listing_layout" => layout,
          "featured_style" => style,
          "newest_enabled" => "true",
          "newest_style" => style
        })

        levels =
          get(build_conn(), "/#{slug}")
          |> html_response(200)
          |> q("main h1, main h2, main h3, main h4")
          |> Enum.map(&(&1 |> LazyHTML.tag() |> hd() |> String.at(1) |> String.to_integer()))

        assert hd(levels) == 1

        levels
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [a, b] ->
          assert b <= a + 1, "#{layout}/#{style}: h#{a} followed by h#{b} (#{inspect(levels)})"
        end)
      end

      _ = conn
    end
  end
end
