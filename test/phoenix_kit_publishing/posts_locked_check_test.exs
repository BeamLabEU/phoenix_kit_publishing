defmodule PhoenixKit.Modules.Publishing.PostsLockedCheckTest do
  # async: false: the stale-row test attaches a global telemetry handler.
  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.{Groups, Posts, Versions}
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  @uuid "00000000-0000-7000-8000-000000000001"
  @api [actor_uuid: @uuid, activity_mode: "auto", log_metadata: %{"via" => "api"}]

  setup do
    {:ok, g} = Groups.add_group("Lock #{System.unique_integer([:positive])}", mode: "slug")
    {:ok, post} = Posts.create_post(g["slug"], %{title: "T", slug: "t"})
    {:ok, post} = Posts.read_post_by_uuid(post[:uuid])
    %{group: g["slug"], post: post}
  end

  test "an error from the hook changes nothing, returns the error and leaves one failed-mutation row",
       %{group: g, post: post} do
    before = Posts.read_post_by_uuid(post[:uuid]) |> elem(1)

    assert {:error, :refused} =
             Posts.update_post(
               g,
               post,
               %{"title" => "Changed"},
               [{:locked_check, fn _p, _v -> {:error, :refused} end}, {:publish, false}] ++ @api
             )

    {:ok, after_} = Posts.read_post_by_uuid(post[:uuid])
    assert after_[:metadata][:title] == before[:metadata][:title]
    row = assert_activity_logged("publishing.post.updated", resource_uuid: post[:uuid])
    assert row.metadata["db_pending"] == true
    assert row.mode == "auto"
    assert row.metadata["via"] == "api"
  end

  test "without the option behaviour is unchanged", %{group: g, post: post} do
    assert {:ok, _} = Posts.update_post(g, post, %{"title" => "Changed"}, publish: false)
  end

  test "the hook receives the locked post row and the fresh version", %{group: g, post: post} do
    test_pid = self()

    hook = fn locked, version ->
      send(test_pid, {:hook, locked.uuid, version.version_number})
      :ok
    end

    assert {:ok, _} =
             Posts.update_post(g, post, %{"title" => "X"}, locked_check: hook, publish: false)

    assert_received {:hook, uuid, 1}
    assert uuid == post[:uuid]
  end

  test "a lock that returns nil with a hook answers :not_found before the hook runs", %{
    group: g,
    post: post
  } do
    # The post row vanishes between the pre-read and the lock: simulate by
    # deleting the row inside the telemetry window of the version read.
    {:ok, stale} = Posts.read_post_by_uuid(post[:uuid])
    ref = make_ref()
    me = self()
    handler = "locked-nil-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      TestRepo.config()[:telemetry_prefix] ++ [:query],
      fn _e, _m, meta, _c ->
        if meta.source == "phoenix_kit_publishing_versions" and Process.get(ref) == nil do
          Process.put(ref, true)

          TestRepo.query!("DELETE FROM phoenix_kit_publishing_posts WHERE uuid = $1", [
            Ecto.UUID.dump!(post[:uuid])
          ])
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    hook = fn _p, _v ->
      send(me, :hook_ran)
      :ok
    end

    result = Posts.update_post(g, stale, %{"title" => "X"}, locked_check: hook, publish: false)
    assert {:error, _} = result
    refute_received :hook_ran
  end

  describe "the stale-row interleaving (review 3)" do
    # `ctx.db_post` is read at the START of update_post_in_db; the window is between that
    # read and lock_post_row! inside the transaction, and one statement sits in it:
    # DBStorage.get_version/2. A telemetry handler on the repo's query event runs in the
    # calling process on the same sandbox connection; on the FIRST versions query after
    # the post read it publishes a second draft of the same post.
    test "the hook sees the row published inside the window, not the pre-transaction struct", %{
      group: g,
      post: post
    } do
      {:ok, v2_post} = Versions.create_new_version(g, post, %{}, %{})
      {:ok, base} = Posts.read_post_by_uuid(post[:uuid], nil, 1)
      assert v2_post[:version] == 2

      me = self()
      flag = make_ref()
      handler = "stale-row-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        TestRepo.config()[:telemetry_prefix] ++ [:query],
        fn _e, _m, meta, _c ->
          if meta.source == "phoenix_kit_publishing_versions" and Process.get(flag) == nil do
            Process.put(flag, true)
            :ok = Versions.publish_version(g, post[:uuid], 2, [])
            send(me, :interleaved)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      hook = fn locked, _version ->
        send(me, {:locked_active, locked.active_version_uuid})
        :ok
      end

      assert {:ok, _} =
               Posts.update_post(g, base, %{"title" => "Edit"},
                 locked_check: hook,
                 publish: false
               )

      # (1) the interleaving ran: a test whose window never opened is vacuous.
      assert_received :interleaved
      # (2) the hook was fed the LOCKED row, which carries the version published in the window.
      assert_received {:locked_active, active}
      assert is_binary(active)
    end
  end
end
