defmodule PhoenixKit.Modules.Publishing.API.PostsLockedCheckApiTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.API.{Common, Danger}
  alias PhoenixKit.Modules.Publishing.{DBStorage, Posts, Versions}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    Fx.languages!()
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "T", slug: "t"})
    %{g: g, post: post}
  end

  defp closure(ctx),
    do:
      Common.locked_check(ctx, fn locked, version ->
        Danger.live_condition(locked, version, nil)
      end)

  defp locked_rows(uuid) do
    TestRepo.transaction(fn ->
      locked = DBStorage.lock_post_row!(TestRepo, uuid)
      {locked, DBStorage.get_version(uuid, 1)}
    end)
    |> elem(1)
  end

  test "the closure answers went_live after an out-of-band publish, passes with a confirmation, and refuses a trashed post",
       %{g: g, post: post} do
    Fx.publish!(g["slug"], post[:uuid])
    {locked, version} = locked_rows(post[:uuid])
    assert {:error, :went_live} = closure(ApiCase.ctx()).(locked, version)
    assert :ok = closure(ApiCase.ctx(%{confirmation_uuid: "c"})).(locked, version)

    {:ok, _} = Posts.trash_post(g["slug"], post[:uuid])
    {trashed, version} = locked_rows(post[:uuid])

    assert {:error, :post_trashed} =
             closure(ApiCase.ctx(%{confirmation_uuid: "c"})).(trashed, version)
  end

  test "went_live reaches the caller as revision_mismatch with its reason" do
    assert {:error, :revision_mismatch, _, %{reason: "went_live"}} = Common.error(:went_live)
  end

  # The window opens at the first statement on versions that Posts.update_post ITSELF issues
  # (DBStorage.get_version/2 at the start of do_update_post_in_db); the handler's own reads of
  # versions come before it. @fire_on is the 1-based number of that statement among the SELECTs on
  # versions in the whole call. @fire_before_recheck is the SELECT just before the handler's own recheck, so a
  # publish landing there is caught by the recheck, before Posts.update_post is called at all.
  # CALIBRATE both if a change moves the statements: print `meta.query` for every versions SELECT.
  @fire_on 5
  @fire_before_recheck 3

  defp publish_on_select(g, post, fire_on) do
    counter = :counters.new(1, [])
    me = self()
    handler = "api-locked-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      TestRepo.config()[:telemetry_prefix] ++ [:query],
      fn _event, _measurements, meta, _config ->
        count_select(meta, counter, fire_on, fn -> publish_now(g, post, me) end)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp count_select(meta, counter, fire_on, fire) do
    if versions_select?(meta) do
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) == fire_on, do: fire.()
    end
  end

  defp versions_select?(meta),
    do: meta.source == "phoenix_kit_publishing_versions" and meta.query =~ "SELECT"

  defp publish_now(g, post, notify) do
    :ok = Versions.publish_version(g["slug"], post[:uuid], 1, [])
    send(notify, :interleaved)
  end

  defp failed_update_rows do
    Enum.filter(
      list_activities(),
      &(&1.action == "publishing.post.updated" and &1.metadata["db_pending"] == true)
    )
  end

  test "end to end: a publish landing inside the window refuses an unconfirmed edit, changes nothing and leaves one failed-mutation row",
       %{g: g, post: post} do
    publish_on_select(g, post, @fire_on)
    before = Fx.content(post[:uuid]).title

    result =
      ApiCase.call("publishing.update_post", %{"post" => Fx.ref(post), "title" => "Edited"})

    # (1) the interleaving ran: a test whose window never opened is vacuous.
    assert_received :interleaved
    assert {:error, :revision_mismatch, _, %{reason: "went_live"}} = result
    assert Fx.content(post[:uuid]).title == before

    # (2) the refusal came from the HOOK under the lock, not from the handler's own earlier recheck:
    # only the hook leaves a failed-mutation row.
    assert [%{mode: "auto", metadata: %{"via" => "api"}}] = failed_update_rows()
  end

  test "a publish landing before the handler's own recheck is refused there: nothing is written and no failed-mutation row is left",
       %{g: g, post: post} do
    publish_on_select(g, post, @fire_before_recheck)
    before = Fx.content(post[:uuid]).title

    result =
      ApiCase.call("publishing.update_post", %{"post" => Fx.ref(post), "title" => "Edited"})

    assert_received :interleaved
    assert {:error, :revision_mismatch, _, %{reason: "went_live"}} = result
    assert Fx.content(post[:uuid]).title == before
    assert failed_update_rows() == []
  end
end
