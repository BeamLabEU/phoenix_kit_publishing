defmodule PhoenixKit.Modules.Publishing.Web.Controller.AccessCanaryTest do
  @moduledoc """
  The canary crawl: a protected post carries a unique marker in its title,
  slug, body, description, tag, category, comment and an old slug; a public
  post of the same group links to it. Every public surface is then fetched
  anonymously — listings and their pages, search (results and counts), the
  feeds, tag and category archives, the post URL in every form (plain,
  versioned, old slug, other language), the linking post, the sitemap source,
  the host-facing listing facade — and the marker must appear nowhere: not in
  a body, a header or a redirect target.

  A second pass with each secret-link and password variant proves the same
  surfaces stay clean, and that the post itself does open for the reader who
  holds the grant.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Comments, as: PublishingComments
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.PostAccess
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Sitemap.Sources.Publishing, as: SitemapSource
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  @marker "zqcanary"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("comments_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group("canary-#{System.unique_integer([:positive])}", mode: "slug")
    slug = group["slug"]

    {:ok, _} =
      Groups.update_group(slug, %{
        "comments_enabled" => "true",
        "search_enabled" => "true",
        "listing_category_filter" => "true"
      })

    {:ok, category} =
      Categories.create_category(slug, %{"name" => "Reports", "slug" => "reports"})

    {:ok, secret} =
      Posts.create_post(slug, %{
        title: "Title #{@marker}",
        slug: "old-#{@marker}",
        content: "Body #{@marker} with #tag#{@marker} and more."
      })

    {:ok, read} = Publishing.read_post_by_uuid(secret.uuid, "en", 1)

    {:ok, _} =
      Posts.update_post(
        slug,
        read,
        %{
          "slug" => "post-#{@marker}",
          "description" => "Description #{@marker}",
          "category_uuids" => [category.uuid],
          "allow_version_access" => "true"
        },
        %{}
      )

    :ok = Versions.publish_version(slug, secret.uuid, 1)

    {:ok, public} =
      Posts.create_post(slug, %{
        title: "Public neighbour",
        slug: "public-neighbour",
        content: "See [[post:#{secret.uuid}|the report]] for details."
      })

    :ok = Versions.publish_version(slug, public.uuid, 1)

    user =
      TestRepo.insert!(%PhoenixKit.Users.Auth.User{
        email: "canary-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "x"
      })

    {:ok, _} = PublishingComments.create(secret.uuid, user.uuid, "Comment #{@marker}")

    %{slug: slug, secret: secret, public: public, owner: {:post, secret.uuid}}
  end

  defp surfaces(slug, secret) do
    [
      "/#{slug}",
      "/#{slug}?page=2",
      "/#{slug}?q=Title",
      "/#{slug}?q=Description",
      "/#{slug}?q=Body",
      "/#{slug}?category=reports",
      "/#{slug}/feed.xml",
      "/#{slug}/tag/tag#{@marker}",
      "/#{slug}/tag/tag#{@marker}/feed.xml",
      "/#{slug}/category/reports",
      "/#{slug}/category/reports/feed.xml",
      "/#{slug}/post-#{@marker}",
      "/#{slug}/post-#{@marker}/v/1",
      "/#{slug}/old-#{@marker}",
      "/en/#{slug}/post-#{@marker}",
      "/#{slug}/public-neighbour",
      "/#{slug}/#{secret.uuid}"
    ]
  end

  # Fetches every surface and returns the bodies, headers and redirect
  # targets the marker must not appear in.
  defp crawl(conn, slug, secret) do
    for path <- surfaces(slug, secret) do
      response = get(conn, path)

      headers =
        response.resp_headers
        |> Enum.reject(fn {k, _} -> k == "set-cookie" end)
        |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

      # The reader typed this URL, so a page echoing it back (a form's
      # action, a sign-in return_to) tells them nothing new: the echo is
      # taken out before looking for the marker.
      bare = path |> String.split("?") |> hd()

      text =
        "#{response.status}\n#{headers}\n#{response.resp_body}"
        |> String.replace(URI.encode_www_form(bare), "<requested>")
        |> String.replace(bare, "<requested>")

      {path, text}
    end
  end

  defp assert_clean(crawled) do
    for {path, text} <- crawled do
      refute String.contains?(String.downcase(text), @marker),
             "#{path} leaked the protected post:\n" <> excerpt(text)
    end
  end

  defp excerpt(text) do
    case :binary.match(String.downcase(text), @marker) do
      {pos, _} ->
        binary_part(text, max(pos - 200, 0), min(400, byte_size(text) - max(pos - 200, 0)))

      :nomatch ->
        ""
    end
  end

  defp assert_facades_clean(slug) do
    sitemap = SitemapSource.collect(base_url: "https://canary.test") |> Enum.map(& &1.loc)

    refute Enum.any?(sitemap, &String.contains?(&1, @marker)),
           "sitemap leaked: #{inspect(sitemap)}"

    {:ok, page} = Publishing.list_published(slug)
    refute inspect(page) =~ @marker

    {:ok, counts} = Publishing.category_counts(slug)
    assert counts["reports"] in [nil, 0]
  end

  test "the post is public before any rule — the crawl does find the marker", %{
    conn: conn,
    slug: slug,
    secret: secret
  } do
    crawled = crawl(conn, slug, secret)
    assert Enum.any?(crawled, fn {_p, text} -> String.contains?(text, @marker) end)
  end

  for {name, setup_fun} <- [
        {"a password", :password},
        {"a secret link", :token},
        {"a role", :role},
        {"signed-in readers", :signed_in},
        {"a password, with protected posts listed to permitted readers", :listed}
      ] do
    test "behind #{name}, no public surface shows a trace of it", %{
      conn: conn,
      slug: slug,
      secret: secret,
      owner: owner
    } do
      protect(unquote(setup_fun), owner, slug)

      conn |> crawl(slug, secret) |> assert_clean()
      assert_facades_clean(slug)

      # The protected post never enters the sitemap list core reads.
      assert %{metadata: %{sitemap_exclude: true}, access_protected: true} =
               Enum.find(Publishing.list_posts(slug, "en"), &(&1.uuid == secret.uuid))
    end
  end

  test "the reader holding the grant sees the post, and nothing leaks beside it", %{
    conn: conn,
    slug: slug,
    secret: secret,
    owner: owner
  } do
    {:ok, _rule, key} = PostAccess.create_link(owner, %{"note" => "client"})
    redeemed = get(conn, "/#{slug}/post-#{@marker}?key=#{key}")
    granted = recycle(redeemed)

    assert granted |> get("/#{slug}/post-#{@marker}") |> html_response(200) =~ "Title #{@marker}"

    # The public listing is shared and cacheable: without list_protected the
    # holder sees exactly what everyone sees.
    refute granted |> recycle() |> get("/#{slug}") |> html_response(200) =~ @marker

    # The link key appears in no page the reader is sent to.
    refute redeemed.resp_body =~ key
  end

  test "rule secrets never appear in the maps hosts and the API read", %{slug: slug, owner: owner} do
    {:ok, rule, key} = PostAccess.create_link(owner)
    {:ok, pw} = PostAccess.set_password(owner, "canary password")

    texts = [
      inspect(Publishing.list_posts(slug)),
      inspect(Publishing.list_posts(slug, "en")),
      inspect(Publishing.list_published(slug))
    ]

    for text <- texts do
      refute text =~ key
      refute text =~ rule.config["digest"]
      refute text =~ pw.config["hash"]
      refute text =~ "canary password"
    end
  end

  defp protect(:password, owner, _slug),
    do: {:ok, _} = PostAccess.set_password(owner, "canary pw")

  defp protect(:token, owner, _slug), do: {:ok, _, _} = PostAccess.create_link(owner)

  defp protect(:role, owner, _slug) do
    {:ok, role} =
      PhoenixKit.Users.Roles.create_role(%{name: "Canary #{System.unique_integer([:positive])}"})

    {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "role", "role_uuids" => [role.uuid]})
  end

  defp protect(:signed_in, owner, _slug),
    do: {:ok, _} = PostAccess.add_rule(owner, %{"kind" => "signed_in"})

  defp protect(:listed, owner, slug) do
    {:ok, group} = Publishing.fetch_group(slug)
    {:ok, _} = PostAccess.put_settings({:group, group["uuid"]}, %{"list_protected" => true})
    protect(:password, owner, slug)
  end
end
