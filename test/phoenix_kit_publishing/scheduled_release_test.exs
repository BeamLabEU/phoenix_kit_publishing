defmodule PhoenixKit.Modules.Publishing.ScheduledReleaseTest do
  @moduledoc """
  Pins the clock a scheduled timestamp-mode post is released on.

  `post_date`/`post_time` are stamped and edited on the SITE's wall clock
  (`Posts.maybe_add_initial_timestamp/3` shifts by the `time_zone` setting)
  and rendered with no display conversion. `scheduled_ahead?/2` therefore
  has to compare them against the site's clock too — comparing them against
  UTC released an embargoed post `offset` hours early on a site west of
  UTC, which is the direction that matters.

  Pure tier on purpose: `scheduled_ahead?/2` takes `now` explicitly, so the
  release rule is pinned without a settings row or a database. The reading
  of the offset itself is `Constants.site_offset_seconds/0`, shared with the
  stamping path so the two clocks cannot drift.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Constants

  # A site three hours east of UTC: 18:00 on its clock is 15:00 UTC.
  defp site_now(~N[2026-08-01 15:30:00]), do: ~U[2026-08-01 18:30:00Z]

  defp post(date, time),
    do: %{mode: "timestamp", date: date, time: time}

  describe "scheduled_ahead?/2" do
    test "a post timed later today on the site's clock is still held back" do
      assert Constants.scheduled_ahead?(
               post(~D[2026-08-01], ~T[19:00:00]),
               site_now(~N[2026-08-01 15:30:00])
             )
    end

    test "a post timed earlier today on the site's clock is public" do
      refute Constants.scheduled_ahead?(
               post(~D[2026-08-01], ~T[18:00:00]),
               site_now(~N[2026-08-01 15:30:00])
             )
    end

    test "the comparison is the site's wall clock, not UTC" do
      # 18:00 site-local, and it is 18:30 site-local (15:30 UTC). Compared
      # against UTC this post would look three hours in the future and stay
      # hidden; against the site's own clock it is already out.
      now = site_now(~N[2026-08-01 15:30:00])
      scheduled = post(~D[2026-08-01], ~T[18:00:00])

      refute Constants.scheduled_ahead?(scheduled, now)
      assert Constants.scheduled_ahead?(scheduled, ~U[2026-08-01 15:30:00Z])
    end

    test "no time means the whole day is public from its first minute" do
      refute Constants.scheduled_ahead?(
               post(~D[2026-08-01], nil),
               site_now(~N[2026-08-01 15:30:00])
             )

      assert Constants.scheduled_ahead?(
               post(~D[2026-08-02], nil),
               site_now(~N[2026-08-01 15:30:00])
             )
    end

    test "slug-mode posts and dateless rows are never scheduled" do
      now = site_now(~N[2026-08-01 15:30:00])

      refute Constants.scheduled_ahead?(%{mode: "slug", date: ~D[2027-01-01], time: nil}, now)
      refute Constants.scheduled_ahead?(%{mode: "timestamp", date: nil, time: nil}, now)
      refute Constants.scheduled_ahead?(%{}, now)
    end
  end

  describe "site_offset_seconds/0" do
    test "degrades to UTC rather than raising when settings are unreachable" do
      assert is_integer(Constants.site_offset_seconds())
    end
  end

  describe "site_now/0" do
    test "is utc_now shifted by the site offset" do
      before_call = DateTime.utc_now()
      now = Constants.site_now()
      offset = Constants.site_offset_seconds()

      drift =
        now
        |> DateTime.add(-offset, :second)
        |> DateTime.diff(before_call, :second)

      assert drift >= 0 and drift <= 5
    end
  end
end
