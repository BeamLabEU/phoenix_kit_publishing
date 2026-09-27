defmodule PhoenixKit.Modules.Publishing.Web.Controller.ViewsTest do
  @moduledoc """
  Pins the view-counting contract: gated on views_enabled, bot-filtered,
  session-deduped per day, counts stored as daily rollups, and the optional
  "N views" chip.
  """

  # async: false — mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Views
  alias PhoenixKit.Settings

  defp unique_name, do: "vw-#{System.unique_integer([:positive])}"

  @browser_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    slug = group["slug"]

    {:ok, post} =
      Posts.create_post(slug, %{title: "Counted", slug: "counted", content: "Body."})

    :ok = Versions.publish_version(slug, post.uuid, 1)

    %{slug: slug, post: post}
  end

  defp browse(conn, path) do
    conn |> put_req_header("user-agent", @browser_ua) |> get(path)
  end

  defp drain(post_uuid) do
    # record_async fires through the task supervisor — give it a beat.
    Process.sleep(50)
    Views.total(post_uuid)
  end

  test "no counting while views_enabled is off", %{conn: conn, slug: slug, post: post} do
    browse(conn, "/#{slug}/counted") |> html_response(200)
    assert drain(post.uuid) == 0
  end

  test "counts a browser view once per session-day; another visitor counts again", %{
    conn: conn,
    slug: slug,
    post: post
  } do
    {:ok, _} = Groups.update_group(slug, %{"views_enabled" => "true"})

    first = browse(conn, "/#{slug}/counted")
    html_response(first, 200)
    assert drain(post.uuid) == 1

    # Same session (recycled conn keeps the cookie) — deduped.
    first |> recycle() |> browse("/#{slug}/counted") |> html_response(200)
    assert drain(post.uuid) == 1

    # A fresh session from ANOTHER address counts again (same-address
    # cookieless repeats are the unique-views case below).
    from_ip({10, 0, 0, 2}) |> browse("/#{slug}/counted") |> html_response(200)
    assert drain(post.uuid) == 2
  end

  describe "publishing_unique_views" do
    setup %{slug: slug} do
      {:ok, _} = Groups.update_group(slug, %{"views_enabled" => "true"})

      on_exit(fn ->
        {:ok, _} = Settings.update_boolean_setting("publishing_unique_views", true)
      end)

      :ok
    end

    test "on (the default): a cookieless address counts once per post per day", %{
      slug: slug,
      post: post
    } do
      assert Settings.get_boolean_setting("publishing_unique_views", true)

      from_ip({10, 1, 1, 1}) |> browse("/#{slug}/counted") |> html_response(200)
      from_ip({10, 1, 1, 1}) |> browse("/#{slug}/counted") |> html_response(200)
      assert drain(post.uuid) == 1

      # A different post is a different visit.
      {:ok, other} = Posts.create_post(slug, %{title: "Other", slug: "other", content: "x"})
      :ok = Versions.publish_version(slug, other.uuid, 1)
      from_ip({10, 1, 1, 1}) |> browse("/#{slug}/other") |> html_response(200)
      assert drain(other.uuid) == 1
    end

    test "off: every page open counts", %{slug: slug, post: post} do
      {:ok, _} = Settings.update_boolean_setting("publishing_unique_views", false)

      from_ip({10, 1, 1, 2}) |> browse("/#{slug}/counted") |> html_response(200)
      from_ip({10, 1, 1, 2}) |> browse("/#{slug}/counted") |> html_response(200)
      assert drain(post.uuid) == 2
    end

    test "off: the same browser session counts on every open too", %{slug: slug, post: post} do
      {:ok, _} = Settings.update_boolean_setting("publishing_unique_views", false)

      # The session marker is a dedup as well; off means it is not consulted.
      first = from_ip({10, 1, 1, 3}) |> browse("/#{slug}/counted")
      assert first.status == 200
      first |> Phoenix.ConnTest.recycle() |> browse("/#{slug}/counted") |> html_response(200)
      assert drain(post.uuid) == 2
    end

    test "two spellings of one IPv6 address are one visitor", %{slug: slug, post: post} do
      forwarded("2001:db8::1") |> browse("/#{slug}/counted") |> html_response(200)
      forwarded("2001:0db8:0:0:0:0:0:1") |> browse("/#{slug}/counted") |> html_response(200)
      assert drain(post.uuid) == 1
    end

    test "the last forwarded hop — the proxy's own word — is the visitor", %{
      slug: slug,
      post: post
    } do
      # The first hop is the client's to write: a loop that rotates it must
      # not mint a new visitor per request. The last hop is what the proxy
      # saw, so the same peer counts once.
      forwarded("203.0.113.5, 10.0.0.1") |> browse("/#{slug}/counted") |> html_response(200)
      forwarded("203.0.113.6, 10.0.0.1") |> browse("/#{slug}/counted") |> html_response(200)
      forwarded("198.51.100.9, 10.0.0.1") |> browse("/#{slug}/counted") |> html_response(200)
      assert drain(post.uuid) == 1

      # A different peer behind the proxy is a new visitor.
      forwarded("203.0.113.5, 10.0.0.9") |> browse("/#{slug}/counted") |> html_response(200)
      assert drain(post.uuid) == 2
    end

    test "the digest is keyed, not a plain hash of the address", %{slug: slug} do
      from_ip({192, 0, 2, 78}) |> browse("/#{slug}/counted") |> html_response(200)

      plain = :crypto.hash(:sha256, inspect({192, 0, 2, 78})) |> binary_part(0, 16)
      hashes = Enum.map(Views.VisitorTable.entries(), fn {{_, _, hash}, _} -> hash end)

      assert hashes != []
      refute plain in hashes
      assert is_binary(Views.VisitorTable.pepper())
    end

    test "the visitor table never holds a raw address", %{slug: slug, post: post} do
      from_ip({192, 0, 2, 77}) |> browse("/#{slug}/counted") |> html_response(200)
      forwarded("198.51.100.42, 10.0.0.1") |> browse("/#{slug}/counted") |> html_response(200)

      dump = inspect(Views.VisitorTable.entries(), limit: :infinity)
      assert dump =~ post.uuid
      refute dump =~ "192.0.2.77"
      refute dump =~ "198.51.100.42"
      refute dump =~ "{192, 0, 2, 77}"
    end
  end

  defp from_ip(ip), do: %{Phoenix.ConnTest.build_conn() | remote_ip: ip}

  defp forwarded(header) do
    Phoenix.ConnTest.build_conn() |> put_req_header("x-forwarded-for", header)
  end

  test "bots never count", %{conn: conn, slug: slug, post: post} do
    {:ok, _} = Groups.update_group(slug, %{"views_enabled" => "true"})

    conn
    |> put_req_header("user-agent", "Googlebot/2.1 (+http://www.google.com/bot.html)")
    |> get("/#{slug}/counted")
    |> html_response(200)

    # Absent UA is treated as a bot too.
    get(conn, "/#{slug}/counted") |> html_response(200)

    assert drain(post.uuid) == 0
  end

  test "the view-count chip is off by default and renders when enabled", %{
    conn: conn,
    slug: slug,
    post: post
  } do
    {:ok, _} = Groups.update_group(slug, %{"views_enabled" => "true"})
    :ok = Views.record_view(post.uuid)
    :ok = Views.record_view(post.uuid)

    refute browse(conn, "/#{slug}/counted") |> html_response(200) =~ ~r/\d+ views?/

    {:ok, _} = Groups.update_group(slug, %{"show_view_counts" => "true"})
    html = browse(Phoenix.ConnTest.build_conn(), "/#{slug}/counted") |> html_response(200)
    assert html =~ ~r/\d+ views/
  end

  test "rollups accumulate per day and top_posts ranks the window", %{slug: slug, post: post} do
    {:ok, second} =
      Posts.create_post(slug, %{title: "Quiet", slug: "quiet", content: "x"})

    :ok = Versions.publish_version(slug, second.uuid, 1)

    :ok = Views.record_view(post.uuid)
    :ok = Views.record_view(post.uuid)
    :ok = Views.record_view(post.uuid, Date.add(Date.utc_today(), -2))
    :ok = Views.record_view(second.uuid)

    assert Views.total(post.uuid) == 3
    assert [{first_uuid, 3}, {second_uuid, 1}] = Views.top_posts(slug, 7, 5)
    assert first_uuid == post.uuid
    assert second_uuid == second.uuid

    # A 1-day window excludes the older rollup.
    assert [{_, 2}, {_, 1}] = Views.top_posts(slug, 1, 5)
  end
end
