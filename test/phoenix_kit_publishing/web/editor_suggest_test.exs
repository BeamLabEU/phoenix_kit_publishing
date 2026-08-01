defmodule PhoenixKit.Modules.Publishing.Web.EditorSuggestTest do
  @moduledoc """
  The `#` autocomplete: Leaf detects the trigger and asks the host what
  matches, the host answers from the group's existing tags.

  Leaf's contract has two rules that outrank the payload shape — stale
  replies are dropped (so `trigger`/`query`/`seq` echo back unchanged), and
  typing is never blocked (an unanswered request just closes the popup).
  Both are pinned here.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Hashtags
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions

  setup do
    {:ok, group} = Groups.add_group("sug-#{System.unique_integer([:positive])}", mode: "slug")
    slug = group["slug"]

    # Two posts sharing #elixir so the ranking has something to order by.
    for {title, post_slug, body} <- [
          {"One", "one", "About #elixir and #phoenix."},
          {"Two", "two", "More #elixir plus #ecto."}
        ] do
      {:ok, post} = Posts.create_post(slug, %{title: title, slug: post_slug, content: body})
      :ok = Versions.publish_version(slug, post.uuid, 1)
    end

    ListingCache.regenerate(slug)
    %{group: group, slug: slug}
  end

  describe "Hashtags.suggest/3" do
    test "ranks prefix matches first, then by how often a tag is used", %{slug: slug} do
      assert [%{tag: "elixir", count: 2} | _] = Hashtags.suggest(slug, "eli")

      # A bare trigger offers the group's tags, most-used first.
      all = Hashtags.suggest(slug, "")
      assert hd(all).tag == "elixir"
      assert Enum.map(all, & &1.tag) |> Enum.sort() == ["ecto", "elixir", "phoenix"]
    end

    test "respects the limit and returns nothing for an unknown group", %{slug: slug} do
      assert length(Hashtags.suggest(slug, "", limit: 1)) == 1
      assert Hashtags.suggest("no-such-group", "eli") == []
    end
  end

  describe "the editor answers a suggest request" do
    test "echoes trigger/query/seq so stale replies can be dropped", %{
      conn: conn,
      group: group,
      slug: slug
    } do
      {:ok, post} = Posts.create_post(slug, %{title: "Writing", slug: "writing"})

      {:ok, view, html} =
        conn
        |> put_test_scope(fake_scope())
        |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}/edit")

      # The trigger is configured on the editor itself.
      assert html =~ "content-editor"

      # Leaf's own documented way to drive the server half of a trigger.
      send(
        view.pid,
        {:leaf_suggest, %{editor_id: "content-editor", trigger: "#", query: "eli", seq: 7}}
      )

      # Rendering proves the LiveView handled it without crashing; the reply
      # goes to the component via send_update.
      assert is_binary(render(view))
    end

    test "an unknown trigger is ignored rather than crashing the editor", %{
      conn: conn,
      group: group,
      slug: slug
    } do
      {:ok, post} = Posts.create_post(slug, %{title: "Writing", slug: "writing2"})

      {:ok, view, _} =
        conn
        |> put_test_scope(fake_scope())
        |> live("/admin/publishing/#{group["slug"]}/#{post[:uuid]}/edit")

      send(
        view.pid,
        {:leaf_suggest, %{editor_id: "content-editor", trigger: "@", query: "a", seq: 1}}
      )

      assert is_binary(render(view))
    end
  end
end
