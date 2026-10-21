defmodule PhoenixKit.Modules.Publishing.API.ListPostsTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.{Groups, Posts, Versions}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo

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

    assert page3 != []
  end

  defp walk(g, extra, limit) do
    Stream.unfold(nil, fn
      :done ->
        nil

      cursor ->
        input = Map.merge(extra, %{"limit" => limit})
        input = if cursor, do: Map.put(input, "cursor", cursor), else: input
        assert {:ok, %{"posts" => posts, "next_cursor" => next}} = list(g, input)
        {posts, next || :done}
    end)
    |> Enum.to_list()
    |> List.flatten()
    |> Enum.map(& &1["id"])
  end

  test "walking the pages gives every post once, in the order of a single page, ties included",
       %{g: g} do
    for i <- 1..12, do: Fx.post!(g["slug"], %{title: "P#{i}", slug: "p#{i}"})
    ts = Fx.group!(mode: "timestamp")
    for i <- 1..8, do: Fx.post!(ts["slug"], %{title: "T#{i}"})

    for group <- [g, ts] do
      assert {:ok, %{"posts" => all, "count" => count}} = list(group, %{"limit" => 100})
      ids = Enum.map(all, & &1["id"])
      assert length(ids) == count and length(Enum.uniq(ids)) == count
      assert walk(group, %{}, 3) == ids
      assert walk(group, %{"status" => "draft"}, 5) == ids
    end
  end

  test "the posts of a page are cut in the query: no query loads more than limit + 1 post rows",
       %{g: g} do
    for i <- 1..25, do: Fx.post!(g["slug"], %{title: "P#{i}", slug: "p#{i}"})
    {:ok, %{"next_cursor" => cursor}} = list(g, %{"limit" => 5})

    for extra <- [%{}, %{"status" => "draft"}, %{"status" => "all", "cursor" => cursor}] do
      rows =
        queries_with_rows(fn ->
          assert {:ok, %{"posts" => posts}} = list(g, Map.merge(%{"limit" => 5}, extra))
          assert length(posts) == 5
        end)

      post_rows = for {"phoenix_kit_publishing_posts", n} <- rows, do: n
      assert post_rows != [] and Enum.max(post_rows) <= 6, inspect(extra)
    end
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

  for {label, raw} <- [
        {"text", "not-a-uuid"},
        {"36 characters that are not a uuid", String.duplicate("z", 36)},
        {"one byte", "x"},
        {"16 raw bytes", <<1::128>>}
      ],
      status <- [nil, "all", "draft", "trashed", "published", "scheduled"] do
    test "a garbage cursor (#{label}) with status #{inspect(status)} is cursor_stale", %{g: g} do
      Fx.post!(g["slug"], %{title: "A", slug: "a"})
      cursor = Base.url_encode64(unquote(Macro.escape(raw)), padding: false)
      extra = if unquote(status), do: %{"status" => unquote(status)}, else: %{}

      assert {:error, :validation_failed, _, %{errors: [%{reason: "cursor_stale"}]}} =
               list(g, Map.put(extra, "cursor", cursor))
    end
  end

  test "a cursor that is not base64url is cursor_stale on every status", %{g: g} do
    Fx.post!(g["slug"], %{title: "A", slug: "a"})

    for status <- ["all", "draft", "trashed", "published"] do
      assert {:error, :validation_failed, _, %{errors: [%{reason: "cursor_stale"}]}} =
               list(g, %{"status" => status, "cursor" => "!!not base64!!"})
    end
  end

  test "an unknown group is not_found; a trashed group still lists" do
    assert {:error, :not_found, _, _} =
             ApiCase.call("publishing.list_posts", %{"group" => "nope"})

    g = Fx.group!()
    Fx.post!(g["slug"], %{title: "T", slug: "t"})
    {:ok, _} = Groups.trash_group(g["slug"])
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

  defp file!(g, post, version, category_uuids) do
    {:ok, p} = Posts.read_post_by_uuid(post[:uuid], nil, version)

    {:ok, _} =
      Posts.update_post(g["slug"], p, %{"category_uuids" => category_uuids}, publish: false)
  end

  test "without a limit a page holds 20 posts and says there are more", %{g: g} do
    for i <- 1..21, do: Fx.post!(g["slug"], %{title: "P#{i}", slug: "p#{i}"})

    assert {:ok, %{"posts" => posts, "count" => 21, "next_cursor" => cursor}} = list(g)
    assert length(posts) == 20 and is_binary(cursor)
  end

  test "the category filter follows the live version when there is one, even when a newer draft is filed elsewhere",
       %{g: g} do
    a = Fx.category!(g["slug"], "Alpha")
    b = Fx.category!(g["slug"], "Beta")
    post = Fx.post!(g["slug"], %{title: "Moving", slug: "moving"})
    file!(g, post, 1, [a.uuid])
    Fx.publish!(g["slug"], post[:uuid])
    {:ok, _} = Versions.create_new_version(g["slug"], post, %{}, %{})
    file!(g, post, 2, [b.uuid])

    assert {:ok, %{"posts" => [%{"slug" => "moving"}]}} = list(g, %{"category_id" => a.uuid})
    assert {:ok, %{"posts" => [], "count" => 0}} = list(g, %{"category_id" => b.uuid})
  end

  test "the category filter follows the latest version when nothing is live", %{g: g} do
    a = Fx.category!(g["slug"], "Alpha")
    b = Fx.category!(g["slug"], "Beta")
    post = Fx.post!(g["slug"], %{title: "Drafty", slug: "drafty"})
    file!(g, post, 1, [a.uuid])
    {:ok, _} = Versions.create_new_version(g["slug"], post, %{}, %{})
    file!(g, post, 2, [b.uuid])

    assert {:ok, %{"posts" => [%{"slug" => "drafty"}]}} = list(g, %{"category_id" => b.uuid})
    assert {:ok, %{"posts" => [], "count" => 0}} = list(g, %{"category_id" => a.uuid})
  end

  # Runs `fun` and returns the SQL texts of the queries it issued (the raw category query has no source).
  defp queries(fun) do
    agent = start_supervised!({Agent, fn -> [] end}, id: make_ref())
    handler = "lp-q-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      Repo.config()[:telemetry_prefix] ++ [:query],
      fn _e, _m, meta, _c -> Agent.update(agent, &[meta.query | &1]) end,
      nil
    )

    fun.()
    :telemetry.detach(handler)
    Agent.get(agent, & &1)
  end

  # Runs `fun` and returns `{source, rows returned}` of every query it issued.
  defp queries_with_rows(fun) do
    agent = start_supervised!({Agent, fn -> [] end}, id: make_ref())
    handler = "lp-r-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      Repo.config()[:telemetry_prefix] ++ [:query],
      fn _e, _m, meta, _c ->
        case meta.result do
          {:ok, %{num_rows: n}} -> Agent.update(agent, &[{meta.source, n} | &1])
          _ -> :ok
        end
      end,
      nil
    )

    fun.()
    :telemetry.detach(handler)
    Agent.get(agent, & &1)
  end

  test "the category filter is one query, however deep the subtree", %{g: g} do
    parent = Fx.category!(g["slug"], "Parent")
    child = Fx.category!(g["slug"], "Child", %{parent_uuid: parent.uuid})
    grandchild = Fx.category!(g["slug"], "Grandchild", %{parent_uuid: child.uuid})
    post = Fx.post!(g["slug"], %{title: "Deep", slug: "deep"})
    file!(g, post, 1, [grandchild.uuid])

    sql =
      queries(fn -> assert {:ok, %{"count" => 1}} = list(g, %{"category_id" => parent.uuid}) end)

    assert Enum.count(sql, &(&1 =~ "jsonb_exists_any")) == 1
  end

  test "the date counts of a timestamp group are computed once per page, not once per post" do
    g = Fx.group!(mode: "timestamp")

    for i <- 1..5 do
      post = Fx.post!(g["slug"], %{title: "P#{i}"})
      Fx.publish!(g["slug"], post[:uuid])
    end

    mfa = {PhoenixKit.Modules.Publishing.Web.Controller.Listing, :group_date_counts, 1}
    test_pid = self()

    tracer =
      spawn_link(fn ->
        forward = fn forward ->
          receive do
            {:trace, _pid, :call, {_module, :group_date_counts, _args}} ->
              send(test_pid, :date_counts_computed)
              forward.(forward)
          end
        end

        forward.(forward)
      end)

    # a module that is not loaded yet takes no trace pattern
    {:module, _} = Code.ensure_loaded(elem(mfa, 0))
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    on_exit(fn -> :erlang.trace_pattern(mfa, false, [:local]) end)

    assert {:ok, %{"posts" => posts}} =
             ApiCase.call("publishing.list_posts", %{"group" => g["slug"]})

    :erlang.trace(self(), false, [:call])
    assert length(posts) == 5
    assert_receive :date_counts_computed, 1000
    refute_receive :date_counts_computed, 100
  end

  test "a page of a timestamp group issues the same number of queries in a 30-post and a 60-post group" do
    count_queries = fn n ->
      g = Fx.group!(mode: "timestamp")

      for i <- 1..n do
        post = Fx.post!(g["slug"], %{title: "P#{i}"})
        Fx.publish!(g["slug"], post[:uuid])
      end

      queries(fn ->
        assert {:ok, %{"posts" => posts}} =
                 ApiCase.call("publishing.list_posts", %{"group" => g["slug"], "limit" => 20})

        assert length(posts) == 20
      end)
      |> length()
    end

    assert count_queries.(30) == count_queries.(60)
  end

  test "a page of 20 issues the same number of version and content queries in a 30-post and a 60-post group" do
    count_queries = fn n ->
      g = Fx.group!()
      for i <- 1..n, do: Fx.post!(g["slug"], %{title: "P#{i}", slug: "p#{i}"})
      agent = start_supervised!({Agent, fn -> 0 end}, id: {:q, n})
      handler = "lp-#{n}-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
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
