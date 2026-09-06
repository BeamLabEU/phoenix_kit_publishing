defmodule PhoenixKit.Modules.Publishing.ScheduledReleaseTest do
  @moduledoc """
  Pins the clock a scheduled timestamp-mode post is released on.

  `post_date`/`post_time` are stamped and edited on the SITE's wall clock
  (`Posts.maybe_add_initial_timestamp/3`) and rendered with no display
  conversion. `scheduled_ahead?/3` therefore reads them back as the instant
  they name in the site's zone before comparing with true UTC now —
  comparing the raw fields against UTC released an embargoed post `offset`
  hours early on a site west of UTC, and comparing wall clock to wall clock
  was not monotonic across a fall-back hour.

  Pure tier on purpose: `scheduled_ahead?/3` takes `now` and the zone
  explicitly, so the release rule is pinned without a settings row or a
  database. The
  conversions themselves are `Constants.to_site_wall/2` and
  `from_site_wall/3`, shared with the stamping and feed paths so the three
  clocks cannot drift.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Constants

  # A site three hours east of UTC (a fixed legacy offset): 18:00 on its
  # clock is 15:00 UTC. `now` is TRUE UTC; the post's date/time is the site
  # wall clock.
  @tz "3"
  @now ~U[2026-08-01 15:30:00Z]

  defp post(date, time),
    do: %{mode: "timestamp", date: date, time: time}

  describe "scheduled_ahead?/3" do
    test "a post timed later today on the site's clock is still held back" do
      assert Constants.scheduled_ahead?(post(~D[2026-08-01], ~T[19:00:00]), @now, @tz)
    end

    test "a post timed earlier today on the site's clock is public" do
      refute Constants.scheduled_ahead?(post(~D[2026-08-01], ~T[18:00:00]), @now, @tz)
    end

    test "the post's time is the site's wall clock, not UTC" do
      # 18:00 site-local is 15:00 UTC, so at 15:30 UTC it is already out —
      # read as UTC it would look three hours in the future and stay hidden.
      scheduled = post(~D[2026-08-01], ~T[18:00:00])

      refute Constants.scheduled_ahead?(scheduled, @now, @tz)
      assert Constants.scheduled_ahead?(scheduled, @now, "0")
    end

    test "no time means the whole day is public from its first minute" do
      refute Constants.scheduled_ahead?(post(~D[2026-08-01], nil), @now, @tz)
      assert Constants.scheduled_ahead?(post(~D[2026-08-02], nil), @now, @tz)
      # 00:00 on the 2nd site-local is 21:00 UTC on the 1st
      refute Constants.scheduled_ahead?(post(~D[2026-08-02], nil), ~U[2026-08-01 21:00:00Z], @tz)
    end

    test "release is monotonic across a fall-back hour" do
      # Warsaw repeats 02:00–02:59 on 2026-10-25. A post set for 02:45 goes
      # out at its first occurrence (00:45Z) and STAYS out through the
      # repeated hour — comparing wall clocks flipped it back to "scheduled"
      # at 01:00Z, when the clock read 02:00 again.
      scheduled = post(~D[2026-10-25], ~T[02:45:00])
      assert Constants.scheduled_ahead?(scheduled, ~U[2026-10-25 00:40:00Z], "Europe/Warsaw")
      refute Constants.scheduled_ahead?(scheduled, ~U[2026-10-25 00:50:00Z], "Europe/Warsaw")
      refute Constants.scheduled_ahead?(scheduled, ~U[2026-10-25 01:10:00Z], "Europe/Warsaw")
      refute Constants.scheduled_ahead?(scheduled, ~U[2026-10-25 01:50:00Z], "Europe/Warsaw")
    end

    test "a post set for an hour the clocks skip goes out when they jump" do
      # Warsaw skips 02:00–02:59 on 2026-03-29; 02:30 resolves to 03:30
      # (01:30Z), the instant right after the jump — the same instant the
      # feed stamps it with.
      scheduled = post(~D[2026-03-29], ~T[02:30:00])
      assert Constants.scheduled_ahead?(scheduled, ~U[2026-03-29 00:59:00Z], "Europe/Warsaw")
      refute Constants.scheduled_ahead?(scheduled, ~U[2026-03-29 01:00:00Z], "Europe/Warsaw")
    end

    test "slug-mode posts and dateless rows are never scheduled" do
      refute Constants.scheduled_ahead?(
               %{mode: "slug", date: ~D[2027-01-01], time: nil},
               @now,
               @tz
             )

      refute Constants.scheduled_ahead?(%{mode: "timestamp", date: nil, time: nil}, @now, @tz)
      refute Constants.scheduled_ahead?(%{}, @now, @tz)
    end
  end

  describe "to_site_wall/2 and from_site_wall/3" do
    # Europe/Tallinn is UTC+2 in January and UTC+3 in July: each conversion
    # must resolve the zone on the date converted. The old integer parse read
    # an IANA id as 0 (UTC everywhere) and could not follow a season at all.
    test "an IANA zone follows daylight saving on the date, both ways" do
      assert Constants.to_site_wall(~U[2026-01-15 08:00:00Z], "Europe/Tallinn") ==
               ~U[2026-01-15 10:00:00Z]

      assert Constants.to_site_wall(~U[2026-07-15 08:00:00Z], "Europe/Tallinn") ==
               ~U[2026-07-15 11:00:00Z]

      assert Constants.from_site_wall(~D[2026-01-15], ~T[10:00:00], "Europe/Tallinn") ==
               ~U[2026-01-15 08:00:00Z]

      assert Constants.from_site_wall(~D[2026-07-15], ~T[10:00:00], "Europe/Tallinn") ==
               ~U[2026-07-15 07:00:00Z]
    end

    test "a legacy offset is fixed, fractional ones included" do
      assert Constants.to_site_wall(~U[2026-07-15 08:00:00Z], "2") == ~U[2026-07-15 10:00:00Z]
      assert Constants.to_site_wall(~U[2026-07-15 08:00:00Z], "5.5") == ~U[2026-07-15 13:30:00Z]

      assert Constants.from_site_wall(~D[2026-07-15], ~T[10:00:00], "-5") ==
               ~U[2026-07-15 15:00:00Z]
    end

    test "no time means the day's first minute; an unresolvable zone degrades to UTC" do
      assert Constants.from_site_wall(~D[2026-07-15], nil, "2") == ~U[2026-07-14 22:00:00Z]
      # Santiago has no 00:00 on 2026-09-06 (clocks jump to 01:00): the day
      # starts at 01:00 local, 04:00Z
      assert Constants.from_site_wall(~D[2026-09-06], nil, "America/Santiago") ==
               ~U[2026-09-06 04:00:00Z]

      assert Constants.from_site_wall(~D[2026-07-15], ~T[10:00:00], "nonsense") ==
               ~U[2026-07-15 10:00:00Z]
    end

    test "the two are inverses across seasons" do
      for utc <- [~U[2026-01-15 21:30:00Z], ~U[2026-07-15 21:30:00Z]],
          tz <- ["Europe/Tallinn", "America/New_York", "5.5", "0"] do
        wall = Constants.to_site_wall(utc, tz)

        assert Constants.from_site_wall(DateTime.to_date(wall), DateTime.to_time(wall), tz) ==
                 utc,
               "#{tz} #{utc}"
      end
    end
  end

  describe "site_now/0" do
    test "is now on the site's wall clock, never raising" do
      before_call = DateTime.utc_now()
      now = Constants.site_now()
      expected = Constants.to_site_wall(before_call, Constants.site_tz())
      assert DateTime.diff(now, expected, :second) in 0..5
    end
  end
end
