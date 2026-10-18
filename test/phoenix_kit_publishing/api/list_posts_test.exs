defmodule PhoenixKit.Modules.Publishing.API.ListPostsTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx

  setup do
    Fx.languages!()
    %{g: Fx.group!()}
  end

  defp list(g, extra \\ %{}),
    do: ApiCase.call("publishing.list_posts", Map.merge(%{"group" => g["slug"]}, extra))

  test "an empty group answers an empty page", %{g: g} do
    assert {:ok, %{"posts" => [], "count" => 0, "next_cursor" => nil}} = list(g)
  end

  test "a group with only trashed posts lists empty by default and shows them under status trashed",
       %{g: g} do
    p = Fx.post!(g["slug"], %{title: "Gone", slug: "gone"})
    {:ok, _} = Posts.trash_post(g["slug"], p[:uuid])
    assert {:ok, %{"count" => 0}} = list(g)
    assert {:ok, %{"posts" => [row], "count" => 1}} = list(g, %{"status" => "trashed"})
    assert row["status"] == "trashed" and row["title"] == "Gone"
  end

  test "status filters: published, draft", %{g: g} do
    live = Fx.post!(g["slug"], %{title: "Live", slug: "live"})
    Fx.publish!(g["slug"], live[:uuid])
    _draft = Fx.post!(g["slug"], %{title: "Draft", slug: "draft"})

    assert {:ok,
            %{"posts" => [%{"slug" => "live", "status" => "published", "public_paths" => paths}]}} =
             list(g, %{"status" => "published"})

    assert is_map(paths) and map_size(paths) >= 1

    assert {:ok, %{"posts" => [%{"slug" => "draft", "status" => "draft"} = d]}} =
             list(g, %{"status" => "draft"})

    refute Map.has_key?(d, "public_paths")
    assert {:ok, %{"count" => 2}} = list(g)
  end

  test "a published timestamp post dated in the future is scheduled, not published" do
    ts = Fx.group!(mode: "timestamp")
    p = Fx.post!(ts["slug"], %{title: "Soon"})
    Fx.publish!(ts["slug"], p[:uuid])
    future = Date.utc_today() |> Date.add(10)
    {:ok, post} = Posts.read_post_by_uuid(p[:uuid])

    {:ok, _} =
      Posts.update_post(ts["slug"], post, %{"published_at" => "#{future}T09:30:00Z"},
        publish: false
      )

    assert {:ok, %{"posts" => [%{"status" => "scheduled"}]}} =
             ApiCase.call("publishing.list_posts", %{
               "group" => ts["slug"],
               "status" => "scheduled"
             })

    assert {:ok, %{"posts" => []}} =
             ApiCase.call("publishing.list_posts", %{
               "group" => ts["slug"],
               "status" => "published"
             })
  end

  test "a timestamp post is addressed by id: the row carries it and no slug", _ do
    ts = Fx.group!(mode: "timestamp")
    p = Fx.post!(ts["slug"], %{title: "Stamp"})

    assert {:ok, %{"posts" => [row]}} =
             ApiCase.call("publishing.list_posts", %{"group" => ts["slug"]})

    assert row["id"] == p[:uuid] and row["mode"] == "timestamp"
  end

  test "pagination: limit, cursor, exact count, stable under an insert", %{g: g} do
    for i <- 1..5, do: Fx.post!(g["slug"], %{title: "P#{i}", slug: "p#{i}"})

    assert {:ok, %{"posts" => page1, "count" => 5, "next_cursor" => cursor}} =
             list(g, %{"limit" => 2})

    assert length(page1) == 2 and is_binary(cursor)
    Fx.post!(g["slug"], %{title: "Late", slug: "late"})

    assert {:ok, %{"posts" => page2, "next_cursor" => c2}} =
             list(g, %{"limit" => 2, "cursor" => cursor})

    assert length(page2) == 2
    assert MapSet.disjoint?(MapSet.new(page1, & &1["id"]), MapSet.new(page2, & &1["id"]))

    assert {:ok, %{"posts" => page3, "next_cursor" => nil}} =
             list(g, %{"limit" => 100, "cursor" => c2})

    assert length(page3) >= 1
  end

  test "limit above 100 is trimmed with a warning", %{g: g} do
    assert {:error, :validation_failed, _, _} = list(g, %{"limit" => 0})
    assert {:ok, %{"warnings" => [%{"code" => "limit_trimmed"}]}} = list(g, %{"limit" => 500})
  end

  test "a cursor whose post vanished from the filtered list is cursor_stale", %{g: g} do
    a = Fx.post!(g["slug"], %{title: "A", slug: "a"})
    for i <- 1..3, do: Fx.post!(g["slug"], %{title: "B#{i}", slug: "b#{i}"})
    {:ok, %{"next_cursor" => cursor, "posts" => [first | _]}} = list(g, %{"limit" => 1})
    {:ok, _} = Posts.trash_post(g["slug"], first["id"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "cursor_stale"}]}} =
             list(g, %{"limit" => 1, "cursor" => cursor})

    _ = a
  end

  test "an unknown group is not_found; a trashed group still lists" do
    assert {:error, :not_found, _, _} =
             ApiCase.call("publishing.list_posts", %{"group" => "nope"})

    g = Fx.group!()
    Fx.post!(g["slug"], %{title: "T", slug: "t"})
    {:ok, _} = PhoenixKit.Modules.Publishing.Groups.trash_group(g["slug"])
    assert {:ok, %{"count" => 1}} = ApiCase.call("publishing.list_posts", %{"group" => g["slug"]})
  end

  test "category_id filters by the active version's filing, including the subtree", %{g: g} do
    parent = Fx.category!(g["slug"], "Parent")
    child = Fx.category!(g["slug"], "Child", %{parent_uuid: parent.uuid})
    filed = Fx.post!(g["slug"], %{title: "Filed", slug: "filed"})
    _other = Fx.post!(g["slug"], %{title: "Other", slug: "other"})
    {:ok, p} = Posts.read_post_by_uuid(filed[:uuid])

    {:ok, _} =
      Posts.update_post(g["slug"], p, %{"category_uuids" => [child.uuid]}, publish: false)

    assert {:ok, %{"posts" => [%{"slug" => "filed"}], "count" => 1}} =
             list(g, %{"category_id" => parent.uuid})

    assert {:ok, %{"count" => 1}} = list(g, %{"category_id" => child.uuid})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "unknown_category"}]}} =
             list(g, %{"category_id" => Ecto.UUID.generate()})

    other_group = Fx.group!()
    foreign = Fx.category!(other_group["slug"], "Foreign")

    assert {:error, :validation_failed, _, %{errors: [%{reason: "unknown_category"}]}} =
             list(g, %{"category_id" => foreign.uuid})
  end

  test "a page of 20 issues the same number of version and content queries in a 30-post and a 60-post group" do
    count_queries = fn n ->
      g = Fx.group!()
      for i <- 1..n, do: Fx.post!(g["slug"], %{title: "P#{i}", slug: "p#{i}"})
      agent = start_supervised!({Agent, fn -> 0 end}, id: {:q, n})
      handler = "lp-#{n}-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        PhoenixKitPublishing.Test.Repo.config()[:telemetry_prefix] ++ [:query],
        fn _e, _m, meta, _c ->
          if meta.source in ["phoenix_kit_publishing_versions", "phoenix_kit_publishing_contents"],
            do: Agent.update(agent, &(&1 + 1))
        end,
        nil
      )

      {:ok, _} = ApiCase.call("publishing.list_posts", %{"group" => g["slug"], "limit" => 20})
      :telemetry.detach(handler)
      Agent.get(agent, & &1)
    end

    assert count_queries.(30) == count_queries.(60)
  end
end
