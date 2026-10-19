defmodule PhoenixKit.Modules.Publishing.API.SchedulePostTest do
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.{
    Constants,
    Groups,
    Posts,
    PublishingContent,
    PublishingPost,
    Versions
  }

  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    Fx.languages!()
    g = Fx.group!(mode: "timestamp")
    post = Fx.post!(g["slug"], %{title: "Soon"})
    Fx.body!(g["slug"], post[:uuid], "# Body")
    %{g: g, post: post}
  end

  defp at(days, time \\ "09:30"), do: "#{Date.utc_today() |> Date.add(days)}T#{time}"

  defp schedule(ctx, publish_at, extra \\ %{}, overrides \\ %{}),
    do:
      ApiCase.call(
        "publishing.schedule_post",
        Map.merge(%{"post" => Fx.ref(ctx.post), "publish_at" => publish_at}, extra),
        overrides
      )

  test "schedules: date and time are the input digits, the version is published, the status is scheduled",
       ctx do
    when_ = at(10)

    assert {:ok,
            %{
              "action" => "scheduled",
              "publish_at" => ^when_,
              "time_zone" => tz,
              "post" => %{"status" => "scheduled"}
            }} = schedule(ctx, when_)

    assert tz == Constants.site_tz()
    db = Fx.db_post(ctx.post[:uuid])
    assert "#{db.post_date}T#{Calendar.strftime(db.post_time, "%H:%M")}" == when_
    assert db.active_version_uuid == Fx.version(ctx.post[:uuid]).uuid
  end

  defp assert_attributed(row) do
    assert row.mode == "auto"

    assert Map.take(row.metadata, ~w(via key_prefix request_id tool)) == %{
             "via" => "api",
             "key_prefix" => "abcd1234",
             "request_id" => "req-test",
             "tool" => "publishing.schedule_post"
           }
  end

  # The rows the tool wrote (fixtures write their own, unattributed ones).
  defp rows(action),
    do:
      Enum.filter(
        list_activities(),
        &(&1.action == action and &1.metadata["tool"] == "publishing.schedule_post")
      )

  test "both writes of a schedule, the move and the publish, are attributed to the key", ctx do
    assert {:ok, %{"action" => "scheduled"}} = schedule(ctx, at(10))

    assert [moved] = rows("publishing.post.updated")
    assert [published] = rows("publishing.version.published")
    assert_attributed(moved)
    assert_attributed(published)
  end

  test "a slug-mode group cannot schedule" do
    slug_group = Fx.group!(mode: "slug")
    p = Fx.post!(slug_group["slug"], %{title: "T", slug: "t"})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "not_timestamp_group"}]}} =
             ApiCase.call("publishing.schedule_post", %{
               "post" => %{"id" => p[:uuid]},
               "publish_at" => at(5)
             })
  end

  test "the past is schedule_in_past, today earlier on the site clock too", ctx do
    assert {:error, :validation_failed, _, %{errors: [%{reason: "schedule_in_past"}]}} =
             schedule(ctx, at(-1))

    assert {:error, :validation_failed, _, %{errors: [%{reason: "schedule_in_past"}]}} =
             schedule(ctx, at(0, "00:00"))
  end

  test "a minute held by another post (also a trashed one) is slot_taken", ctx do
    other = Fx.post!(ctx.g["slug"], %{title: "Other"})
    Fx.body!(ctx.g["slug"], other[:uuid], "x")

    {:ok, _} =
      ApiCase.call("publishing.schedule_post", %{
        "post" => %{"id" => other[:uuid]},
        "publish_at" => at(10)
      })

    assert {:error, :validation_failed, _, %{errors: [%{reason: "slot_taken"}]}} =
             schedule(ctx, at(10))

    {:ok, _} = Posts.trash_post(ctx.g["slug"], other[:uuid])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "slot_taken"}]}} =
             schedule(ctx, at(10))
  end

  test "rescheduling to the post's own minute is unchanged and a retry is safe", ctx do
    assert {:ok, %{"action" => "scheduled"}} = schedule(ctx, at(10))
    n = length(list_activities())

    # A plain retry names no version: the only draft went live, so the live version is the one.
    assert {:ok, %{"action" => "unchanged", "version" => 1}} = schedule(ctx, at(10))
    assert {:ok, %{"action" => "unchanged"}} = schedule(ctx, at(10), %{"version" => 1})
    assert length(list_activities()) == n
  end

  test "a plain call on a live post with no draft acts on the live version", ctx do
    assert {:ok, %{"action" => "scheduled"}} = schedule(ctx, at(10))

    assert {:ok, %{"action" => "scheduled", "version" => 1, "publish_at" => later}} =
             schedule(ctx, at(11))

    assert later == at(11)
    assert Fx.db_post(ctx.post[:uuid]).post_date == Date.add(Date.utc_today(), 11)
  end

  test "malformed publish_at values are refused with the path", ctx do
    for bad <- ["2026-13-45T25:61", "2026-10-18T09:30:00", "2026-10-18T09:30Z", "tomorrow", ""] do
      assert {:error, :validation_failed, _, %{errors: [%{path: "publish_at"}]}} =
               schedule(ctx, bad)
    end
  end

  # Runs `fun` once, right after the first query of `source` (nil: any) matching `pattern`, in the
  # calling process.
  defp after_query(pattern, source, fun) do
    flag = make_ref()
    handler = "schedule-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      TestRepo.config()[:telemetry_prefix] ++ [:query],
      fn _event, _measurements, meta, _config ->
        if (source == nil or meta.source == source) and meta.query =~ pattern and
             Process.get(flag) == nil do
          Process.put(flag, true)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Right after step 1 (the first activity row of the call).
  defp after_step_one(fun), do: after_query(~r/^INSERT/, "phoenix_kit_activities", fun)

  defp stamp(ctx) do
    db = Fx.db_post(ctx.post[:uuid])
    {db.post_date, db.post_time}
  end

  test "a failure of the publish step puts the old date and time back", ctx do
    old = stamp(ctx)
    version = Fx.version(ctx.post[:uuid])

    # The primary title is emptied after step 1: the publish refuses it, the post itself stays reachable.
    after_step_one(fn ->
      TestRepo.update_all(from(c in PublishingContent, where: c.version_uuid == ^version.uuid),
        set: [title: ""]
      )
    end)

    assert {:error, :validation_failed, _, %{errors: [%{reason: "title_required"}]} = context} =
             schedule(ctx, at(10))

    refute Map.has_key?(context, :left_behind)
    assert stamp(ctx) == old
    assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == nil

    # the move and its undo are both attributed
    assert [_move, _undo] = moves = rows("publishing.post.updated")
    Enum.each(moves, &assert_attributed/1)

    # The undo goes through update_post, which also writes the version's published_at: it follows
    # the restored date and time, not the scheduled value step 1 had written.
    {date, time} = old
    assert Fx.version(ctx.post[:uuid]).published_at == DateTime.new!(date, time, "Etc/UTC")
  end

  test "when the old date cannot be put back the error says what is left behind", ctx do
    old = stamp(ctx)

    # A trashed post cannot be updated, so the second update_post finds nothing.
    after_step_one(fn -> {:ok, _} = Posts.trash_post(ctx.g["slug"], ctx.post[:uuid]) end)

    assert {:error, :validation_failed, _,
            %{errors: [%{reason: "post_trashed"}], left_behind: ["date", "time"]}} =
             schedule(ctx, at(10))

    refute stamp(ctx) == old
  end

  test "a minute taken between the check and the move answers slot_taken and moves nothing",
       ctx do
    other = Fx.post!(ctx.g["slug"], %{title: "Other"})
    old = stamp(ctx)
    date = Date.add(Date.utc_today(), 10)

    # Right after the slot check, another writer takes the minute.
    after_query(~r/^SELECT TRUE/, nil, fn ->
      TestRepo.update_all(from(p in PublishingPost, where: p.uuid == ^other[:uuid]),
        set: [post_date: date, post_time: ~T[09:30:00]]
      )
    end)

    assert {:error, :validation_failed, _, %{errors: [%{reason: "slot_taken"}]} = context} =
             schedule(ctx, at(10))

    refute Map.has_key?(context, :left_behind)
    assert stamp(ctx) == old
    assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == nil
  end

  test "the preview states the URL change, the time zone and that a live post disappears until then",
       ctx do
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid])
    before = Fx.table_state()

    assert {:preview, %{"requires_confirmation" => true, "rows" => [row]}, _} =
             schedule(ctx, at(10), %{}, %{dry_run?: true})

    assert Fx.table_state() == before

    assert row["public_url_changes_with_date"] == true and row["disappears_until"] == at(10) and
             row["time_zone"] == Constants.site_tz()
  end

  test "a live post that already waits for a future date does not disappear; the preview shows the old stamp",
       ctx do
    assert {:ok, %{"action" => "scheduled"}} = schedule(ctx, at(10))

    assert {:preview, %{"rows" => [row]}, _} =
             schedule(ctx, at(11), %{}, %{dry_run?: true})

    assert row["disappears_until"] == nil and row["from"] == at(10)
  end

  test "the preview shows the text that goes live and a body change changes the fingerprint",
       ctx do
    Fx.body!(ctx.g["slug"], ctx.post[:uuid], "line one\n<b>stored html</b>")

    assert {:preview, %{"rows" => [row]}, first} = schedule(ctx, at(10), %{}, %{dry_run?: true})

    assert %{"goes_live" => %{"version" => 1, "languages" => [language]}} = row
    assert language["head"] =~ "line one" and language["body_bytes"] > 0
    assert [%{"language" => "en-US", "kind" => "html"} | _] = row["contains_raw_html"]

    Fx.body!(ctx.g["slug"], ctx.post[:uuid], "<script>alert(1)</script>")
    assert {:preview, %{"rows" => [row2]}, second} = schedule(ctx, at(10), %{}, %{dry_run?: true})

    assert first != second
    assert hd(row2["goes_live"]["languages"])["head"] =~ "<script>"
  end

  test "the fingerprint follows the scheduled minute and the version", ctx do
    fingerprint = fn extra, publish_at ->
      assert {:preview, _, fingerprint} = schedule(ctx, publish_at, extra, %{dry_run?: true})
      fingerprint
    end

    assert fingerprint.(%{}, at(10)) == fingerprint.(%{}, at(10))
    refute fingerprint.(%{}, at(10)) == fingerprint.(%{}, at(11))
    refute fingerprint.(%{}, at(10, "09:30")) == fingerprint.(%{}, at(10, "09:31"))

    {:ok, _} = Versions.create_new_version(ctx.g["slug"], ctx.post, %{}, %{})
    refute fingerprint.(%{"version" => 1}, at(10)) == fingerprint.(%{"version" => 2}, at(10))
  end

  test "a failing publish step on a post that already sits on the slot undoes nothing", ctx do
    assert {:ok, %{"action" => "scheduled"}} = schedule(ctx, at(10))
    {:ok, _} = Versions.create_new_version(ctx.g["slug"], ctx.post, %{}, %{})
    Fx.body!(ctx.g["slug"], ctx.post[:uuid], "second", 2)
    v2 = Fx.version(ctx.post[:uuid], 2)
    old = stamp(ctx)
    updates = fn -> Enum.count(list_activities(), &(&1.action == "publishing.post.updated")) end
    n = updates.()

    # The publish locks the post row first; the title is emptied right after, before it is checked.
    after_query(~r/FOR UPDATE/, "phoenix_kit_publishing_posts", fn ->
      TestRepo.update_all(from(c in PublishingContent, where: c.version_uuid == ^v2.uuid),
        set: [title: ""]
      )
    end)

    assert {:error, :validation_failed, _, %{errors: [%{reason: "title_required"}]} = context} =
             schedule(ctx, at(10), %{"version" => 2})

    refute Map.has_key?(context, :left_behind)
    assert stamp(ctx) == old
    assert updates.() == n
  end

  test "a trashed post and a trashed group are refused; if_revision is checked", ctx do
    assert {:error, :revision_mismatch, _, %{current_revision: _}} =
             schedule(ctx, at(10), %{"if_revision" => String.duplicate("0", 64)})

    {:ok, _} = Posts.trash_post(ctx.g["slug"], ctx.post[:uuid])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "post_trashed"}]}} =
             schedule(ctx, at(10))

    {:ok, _} = Groups.trash_group(ctx.g["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: reason}]}} =
             schedule(ctx, at(11))

    assert reason in ["group_trashed", "post_trashed"]
  end
end
