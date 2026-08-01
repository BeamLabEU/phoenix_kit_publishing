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

  test "counts a browser view once per session-day; second session counts again", %{
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

    # A fresh session counts again.
    Phoenix.ConnTest.build_conn() |> browse("/#{slug}/counted") |> html_response(200)
    assert drain(post.uuid) == 2
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
