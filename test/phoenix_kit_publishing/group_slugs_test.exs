defmodule PhoenixKit.Modules.Publishing.GroupSlugsTest do
  # RouterDispatch's slug set: a request for no group costs no query, and the
  # set never misses a group that exists.
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.GroupSlugs
  alias PhoenixKit.Modules.Publishing.ListingCache.CacheSync
  alias PhoenixKitPublishing.RouterDispatch
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  @counter_key {GroupSlugs, :generation}
  @set_key {GroupSlugs, :set}

  setup do
    # The suite runs without the module's children, so without a counter;
    # each test here starts one and leaves none behind.
    on_exit(fn ->
      :persistent_term.erase(@counter_key)
      :persistent_term.erase(@set_key)
    end)

    :ok
  end

  defp group!(name) do
    {:ok, group} =
      Groups.add_group(name <> "-#{System.unique_integer([:positive])}", mode: "slug")

    group["slug"]
  end

  defp group_queries(fun) do
    handler = "group-slugs-#{System.unique_integer([:positive])}"
    me = self()

    :telemetry.attach(
      handler,
      TestRepo.config()[:telemetry_prefix] ++ [:query],
      fn _e, _m, meta, _c ->
        if meta.source == "phoenix_kit_publishing_groups",
          do: send(me, {:group_query, meta.query})
      end,
      nil
    )

    fun.()
    :telemetry.detach(handler)
    count_messages(0)
  end

  defp count_messages(n) do
    receive do
      {:group_query, _} -> count_messages(n + 1)
    after
      0 -> n
    end
  end

  test "without the counter every lookup asks the database" do
    assert GroupSlugs.member?("anything") == :unknown
    assert GroupSlugs.erase() == :ok
  end

  test "the set holds every group, a trashed one too, and nothing else" do
    live = group!("live")
    trashed = group!("trashed")
    {:ok, _} = Groups.trash_group(trashed)
    GroupSlugs.init()

    assert GroupSlugs.member?(live)
    assert GroupSlugs.member?(trashed)
    refute GroupSlugs.member?("about")
  end

  test "a group written through the module is seen at once; one written outside it after erase" do
    GroupSlugs.init()
    refute GroupSlugs.member?("late-group")

    slug = group!("new")
    assert GroupSlugs.member?(slug)

    {:ok, renamed} = Groups.update_group(slug, %{"name" => "Renamed", "slug" => slug <> "-r"})
    refute GroupSlugs.member?(slug)
    assert GroupSlugs.member?(renamed["slug"])

    TestRepo.query!(
      "INSERT INTO phoenix_kit_publishing_groups (uuid, name, slug, mode, status, position, data, inserted_at, updated_at) VALUES (gen_random_uuid(), 'Late', 'late-group', 'slug', 'active', 0, '{}', now(), now())"
    )

    refute GroupSlugs.member?("late-group")
    # a peer's (or this node's) groups broadcast reaches CacheSync
    CacheSync.handle_info({:group_created, %{"slug" => "late-group"}}, %{})
    assert GroupSlugs.member?("late-group")
  end

  test "a set built under an older generation is not used" do
    GroupSlugs.init()
    refute GroupSlugs.member?("raced")
    {generation, set, built_at} = :persistent_term.get(@set_key)

    TestRepo.query!(
      "INSERT INTO phoenix_kit_publishing_groups (uuid, name, slug, mode, status, position, data, inserted_at, updated_at) VALUES (gen_random_uuid(), 'Raced', 'raced', 'slug', 'active', 0, '{}', now(), now())"
    )

    GroupSlugs.erase()
    # a rebuild that read before the write stores its set after the erase
    :persistent_term.put(@set_key, {generation, set, built_at})
    assert GroupSlugs.member?("raced")
  end

  test "a request for no group makes no group query once the set is built" do
    slug = group!("news")
    GroupSlugs.init()
    conn = fn path -> Phoenix.ConnTest.build_conn(:get, path) end

    assert :pass = RouterDispatch.maybe_rewrite(conn.("/warm"), "/")

    assert group_queries(fn ->
             :pass = RouterDispatch.maybe_rewrite(conn.("/about/team"), "/")
           end) == 0

    assert group_queries(fn ->
             :pass = RouterDispatch.maybe_rewrite(conn.("/en/contact"), "/")
           end) == 0

    assert group_queries(fn ->
             assert {:rewrite, _} = RouterDispatch.maybe_rewrite(conn.("/#{slug}"), "/")
           end) > 0
  end
end
