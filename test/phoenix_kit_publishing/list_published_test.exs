defmodule PhoenixKit.Modules.Publishing.ListPublishedTest do
  @moduledoc """
  `Publishing.list_published/2` and `category_counts/2`: the listing as data
  for a host that draws its own, and `url_context/1`, which lets it build
  every URL without re-reading the settings.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.{Categories, Groups, Posts, Versions}
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group("lp-#{System.unique_integer([:positive])}", mode: "slug")
    slug = group["slug"]

    {:ok, billing} =
      Categories.create_category(slug, %{
        "name" => "Billing",
        "color" => "primary",
        "icon" => "hero-banknotes"
      })

    {:ok, invoices} =
      Categories.create_category(slug, %{"name" => "Invoices", "parent_uuid" => billing.uuid})

    {:ok, crm} = Categories.create_category(slug, %{"name" => "CRM"})

    publish = fn title, cats, extra ->
      {:ok, p} =
        Posts.create_post(slug, %{
          title: title,
          slug: title |> String.downcase() |> String.replace(" ", "-"),
          content: "Body of #{title}."
        })

      {:ok, _} = Categories.replace_post_categories(p.uuid, Enum.map(cats, & &1.uuid))
      {:ok, p} = Posts.read_post(slug, p.uuid)
      {:ok, _} = Posts.update_post(slug, p, extra, %{publish: false})
      :ok = Versions.publish_version(slug, p.uuid, 1)
      p
    end

    for i <- 1..5, do: publish.("Billing #{i}", [billing], %{})
    publish.("Invoice run", [invoices], %{"custom_fields" => %{"version" => "1.2.0"}})
    publish.("CRM news", [crm], %{"description" => "Customers, managed."})
    publish.("Plain", [], %{})

    %{slug: slug}
  end

  test "a page of entries with URLs, categories and custom fields", %{slug: slug} do
    assert {:ok, %{entries: entries, total: 8, page: 1, total_pages: 1}} =
             Publishing.list_published(slug)

    invoice = Enum.find(entries, &(&1.title == "Invoice run"))
    assert invoice.url == "/#{slug}/invoice-run"
    assert invoice.custom == %{"version" => "1.2.0"}

    archive = "/#{slug}/category/invoices"
    assert [%{slug: "invoices", name: "Invoices", url: ^archive}] = invoice.categories

    billing = Enum.find(entries, &(&1.title == "Billing 1"))

    assert [
             %{
               slug: "billing",
               color: "primary",
               color_css: "var(--color-primary)",
               icon: "hero-banknotes"
             }
           ] =
             billing.categories

    crm = Enum.find(entries, &(&1.title == "CRM news"))
    assert crm.excerpt == "Customers, managed." and crm.description == "Customers, managed."
    assert Enum.find(entries, &(&1.title == "Plain")).excerpt =~ "Body of Plain"
  end

  test "categories (any of, subcategories included), search, paging and sort", %{slug: slug} do
    {:ok, %{entries: e, total: 6}} = Publishing.list_published(slug, categories: ["billing"])
    assert "Invoice run" in Enum.map(e, & &1.title)

    {:ok, %{total: 2}} = Publishing.list_published(slug, categories: ["invoices", "crm", "nope"])

    {:ok, %{total: 1, entries: [%{title: "CRM news"}]}} =
      Publishing.list_published(slug, search: "MANAGED")

    {:ok, page} = Publishing.list_published(slug, per_page: 3, page: 2)
    assert page.page == 2 and page.total_pages == 3 and length(page.entries) == 3

    # a page past the end is the last one
    {:ok, %{page: 3, entries: [_, _]}} = Publishing.list_published(slug, per_page: 3, page: 99)

    {:ok, %{entries: newest}} = Publishing.list_published(slug)
    {:ok, %{entries: oldest}} = Publishing.list_published(slug, sort: "oldest")
    assert Enum.map(oldest, & &1.uuid) == Enum.reverse(Enum.map(newest, & &1.uuid))

    assert {:error, _} = Publishing.list_published("no-such-group")
  end

  test "category_counts counts each category's subtree in the language", %{slug: slug} do
    assert {:ok, %{"billing" => 6, "invoices" => 1, "crm" => 1}} =
             Publishing.category_counts(slug)
  end

  test "url_context/1 builds the same URLs as the language does", %{slug: slug} do
    {:ok, %{entries: [entry | _]}} = Publishing.list_published(slug)
    {:ok, post} = Posts.read_post(slug, entry.uuid)

    assert PublishingHTML.build_post_url(slug, post, PublishingHTML.url_context("en")) ==
             PublishingHTML.build_post_url(slug, post, "en")

    assert PublishingHTML.build_post_url(slug, post, PublishingHTML.url_context(nil)) ==
             PublishingHTML.build_post_url(slug, post, nil)
  end

  test "a blank description gives way to the excerpt of the body", %{slug: slug} do
    {:ok, post} =
      Posts.create_post(slug, %{title: "Blank description", content: "Body text here."})

    {:ok, read} = Posts.read_post_by_uuid(post[:uuid])
    {:ok, _} = Posts.update_post(slug, read, %{"description" => ""}, %{publish: false})
    :ok = Versions.publish_version(slug, post[:uuid], 1)

    {:ok, %{entries: entries}} = Publishing.list_published(slug, per_page: 100)
    assert %{excerpt: "Body text here."} = Enum.find(entries, &(&1.uuid == post[:uuid]))
  end
end
