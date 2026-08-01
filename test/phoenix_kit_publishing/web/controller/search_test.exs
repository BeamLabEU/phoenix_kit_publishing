defmodule PhoenixKit.Modules.Publishing.Web.Controller.SearchTest do
  @moduledoc """
  Pins the public listing search contract: `?q=` on a search-enabled group
  renders matching published posts (title OR body, case-insensitive, the
  reader's language), ILIKE metacharacters are literal, and a disabled group
  ignores the param entirely.
  """

  # async: false — mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "search-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    {:ok, _} = Groups.update_group(group["slug"], %{"search_enabled" => "true"})

    publish = fn title, slug, content ->
      {:ok, post} =
        Posts.create_post(group["slug"], %{title: title, slug: slug, content: content})

      :ok = Versions.publish_version(group["slug"], post.uuid, 1)
      post
    end

    publish.("Elixir Pipelines", "elixir-pipelines", "All about the |> operator.")
    publish.("Cooking Rice", "cooking-rice", "A 50% water ratio works best.")

    {:ok, draft} =
      Posts.create_post(group["slug"], %{
        title: "Elixir Draft",
        slug: "elixir-draft",
        content: "Unpublished elixir text."
      })

    _ = draft

    %{group_slug: group["slug"]}
  end

  test "matches by title, case-insensitively", %{conn: conn, group_slug: slug} do
    html = get(conn, "/#{slug}?q=elixir") |> html_response(200)

    assert html =~ "Elixir Pipelines"
    refute html =~ "Cooking Rice"
    # Drafts never match.
    refute html =~ "Elixir Draft"
    assert html =~ "result"
    assert html =~ "Clear search"
  end

  test "matches by body text", %{conn: conn, group_slug: slug} do
    html = get(conn, "/#{slug}?q=water+ratio") |> html_response(200)
    assert html =~ "Cooking Rice"
    refute html =~ "Elixir Pipelines"
  end

  test "ILIKE metacharacters are literal", %{conn: conn, group_slug: slug} do
    # "%" would match everything if unescaped; escaped it only matches the
    # literal "50%" in the rice post.
    html = get(conn, "/#{slug}?q=50%25") |> html_response(200)
    assert html =~ "Cooking Rice"
    refute html =~ "Elixir Pipelines"
  end

  test "no matches renders the search empty state", %{conn: conn, group_slug: slug} do
    html = get(conn, "/#{slug}?q=zzzznope") |> html_response(200)
    assert html =~ "No posts match your search."
    refute html =~ "No published posts yet."
  end

  test "blank q renders the normal listing", %{conn: conn, group_slug: slug} do
    html = get(conn, "/#{slug}?q=++") |> html_response(200)
    refute html =~ "Clear search"
    assert html =~ "Elixir Pipelines"
    assert html =~ "Cooking Rice"
  end

  test "search box renders only when enabled; ?q= is ignored when disabled", %{
    conn: conn,
    group_slug: slug
  } do
    assert get(conn, "/" <> slug) |> html_response(200) =~ ~s(name="q")

    {:ok, _} = Groups.update_group(slug, %{"search_enabled" => "false"})

    html = get(conn, "/#{slug}?q=elixir") |> html_response(200)
    refute html =~ ~s(name="q")
    refute html =~ "Clear search"
    # Both posts render — the param was ignored, not applied.
    assert html =~ "Cooking Rice"
  end
end
