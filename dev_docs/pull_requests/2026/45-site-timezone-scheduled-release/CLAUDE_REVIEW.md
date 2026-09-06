# PR #45 Review — Keep timestamp posts on the site's clock for an IANA timezone too

**Author:** Max Don <max@don.ee>
**Reviewer:** Claude (Anthropic)
**Status:** Merged — post-merge review, fixes applied on `main`
**Commit:** `debc542` (squashed: `85a1ead` + the release-by-instant follow-up)
**Date:** 2026-09-06

---

## Verdict

**The correctness work is right, and I found nothing wrong with the logic.** Reading the
`time_zone` setting with `Integer.parse/1` genuinely did read `Europe/Tallinn` (and
`"5.5"`) as `0`, which is every site that has touched the picker since core 2.13.9;
routing the three consumers through one pair of conversions — `to_site_wall/2` and
`from_site_wall/3`, both resolving the zone on the date converted — is the right
shape, and the second commit's move from wall-clock-vs-wall-clock to instant-vs-true-UTC
closes the fall-back-hour hole properly. The test tier pins both directions across
seasons, both DST discontinuities, the legacy and fractional offsets, and the
inverse property.

What it missed is everything around that logic. The new conversions depend on core
behaviour that this package's dependency requirement does not actually demand, so the
fix silently evaporates on an older core a host is still free to resolve. And resolving
a zone is roughly thirty times the cost of the `DateTime.new!` it replaced, which two
call sites now pay per post — one of them per post *and* a database round-trip per
post. Three fixes applied, one test added, one existing guard moved with the floor it
guards.

---

## Findings

### BUG — HIGH: the fix is a silent no-op on any core a host is still allowed to resolve

`mix.exs` declares `pk_dep(:phoenix_kit, "~> 2.4")`. The PR bumped `mix.lock` to
phoenix_kit 2.14.2 — which only governs **this repository's own test runs**. A host
application resolves against the *requirement*, and `~> 2.4` permits everything from
2.4.0 up.

`to_site_wall/2` and `from_site_wall/3` are thin wrappers over core's
`Utils.Date.shift_to_offset/2` and `parse_datetime_local/2`. Both of those became
IANA-aware in core **2.13.9**; I checked the published tarballs rather than the
changelog, and 2.13.8 has:

```elixir
# phoenix_kit 2.13.8 — lib/phoenix_kit/utils/date.ex
def shift_to_offset(%DateTime{} = dt, tz_offset) do
  DateTime.add(dt, offset_to_seconds(tz_offset), :second)
end

def parse_datetime_local(str, tz_offset) when is_binary(str) do
  case parse_naive_datetime_local(str) do
    {:ok, naive} ->
      utc = NaiveDateTime.add(naive, -offset_to_seconds(tz_offset), :second)
```

`offset_to_seconds/1` there is a `Float.parse/1` — it reads `Europe/Tallinn` as `0`,
and `PhoenixKit.Utils.TimeZone` does not exist in that release at all. So on a host
resolving phoenix_kit 2.4.0–2.13.8, both of the PR's conversions are identity-on-UTC,
every timestamp post is stamped, released and syndicated on UTC while the editor shows
the site's clock, and **PR #45 fixes nothing** — with no error, no warning and a green
build. That is the very failure the PR exists to remove, reintroduced through
dependency resolution instead of through code.

This repository already has the precedent and the vocabulary for it: the 0.6.0
CHANGELOG entry is a "⚠️ Requires `phoenix_kit ~> 2.4`" note added for exactly this
class of problem, and the comment above the dep in `mix.exs` explains that floor as
"a hard floor, not a preference".

**Fixed.** `pk_dep(:phoenix_kit, "~> 2.14")`, with the reasoning recorded next to the
existing `put_slug/3` reason. The true floor is 2.13.9; it is rounded up to the nearest
minor because every sibling in the ecosystem expresses this as a plain `~> X.Y` and a
compound requirement would be the only one of its kind. Host-visible, so it gets the
⚠️ treatment in the CHANGELOG.

`test/core_pin_conformance_test.exs` guards this pin and failed on the bump, which is
the guard working: its `@must_admit`/`@must_reject` fixtures are pinned to the floor and
its moduledoc says to "raise this alongside `mix.exs` whenever a newly-adopted core API
sets a higher floor". Both lists moved to the new floor (2.13.9 now sits in
`@must_reject`, since the pin is the rounded floor and not the exact one), and the
moduledoc gained the distinction this finding turns on: `put_slug/3` was a **missing**
function, which fails loudly, whereas `shift_to_offset/2` is a **present but
differently-behaved** one, which does not fail at all. That is why the floor has to
track behaviour and not just arity.

### IMPROVEMENT — HIGH: the RSS feed reads the `time_zone` setting once per item, twice over

`effective_datetime/1` (`web/controller/feed.ex`) calls `Constants.from_site_wall(post.date, time)`
— the **arity-2** clause, whose default argument is `site_tz()`. That is
`PhoenixKit.Settings.get_setting/2`, and core's `get_setting/1` is an uncached
`repo().get_by(Setting, key: key)`, not the `get_settings_cached/2` the admin
LiveViews use.

`effective_datetime/1` is called once per item from `pub_date/1` **and** once per post
again from `last_build_date/1`, so a 50-item feed issued **100 settings queries** to
answer one question whose answer cannot change mid-document.

This is inherited rather than introduced — the pre-PR body called
`Constants.site_offset_seconds()` in exactly the same position, and that was a settings
read too. But the PR's own `filter_published/1` hunk shows the author knew to hoist the
reading out of the loop; the feed is the one consumer that was left behind, and it is
the consumer where each iteration costs a database round-trip rather than arithmetic.

**Fixed.** `render_rss/3` now reads the zone once and threads it through
`item_xml/6` → `pub_date/2` → `effective_datetime/2` and `last_build_date/2`. One
settings query per feed document.

### IMPROVEMENT — MEDIUM: `scheduled_ahead?/3` got ~30x more expensive, per post, on every public request

`filter_published/1` (`web/controller/listing.ex`) runs `scheduled_ahead?/3` over the
listing cache — the code's own comment says "up to 5,000 entries ... on every public
request" — and the predicate's body changed from

```elixir
DateTime.compare(DateTime.new!(date, time || ~T[00:00:00], "Etc/UTC"), now)
```

to a `from_site_wall/3` that builds an ISO string with `Calendar.strftime/2`, hands it
to `parse_datetime_local/2` (which parses it as ISO-8601 **twice** — the `<> ":00"`
attempt fails first), and then resolves the zone through tzdata. Measured on this
checkout, 5,000 calls:

| | ms / 5,000 |
|---|---|
| old `DateTime.new!` + compare | 0.84 |
| `from_site_wall/3`, `Europe/Tallinn` | 25.72 |
| `from_site_wall/3`, legacy `"2"` | 31.08 |
| `Date.diff/2` | 0.40 |

So a full 5,000-post listing pays ~25 ms of pure zone arithmetic per public request
that it did not pay before, to move a boundary that only ever concerns the handful of
posts sitting near *now*.

**Fixed** without touching the semantics. A wall clock runs at most 14 hours ahead of
UTC and 12 behind it (`TimeZone.parse_offset/1` guards `-12.0..14.0`; the IANA range is
the same), so the instant a stamped date names always lands inside the day either side
of that date. A post two whole days clear of now's UTC date is therefore decided by
`Date.diff/2` alone, and only the near-boundary posts resolve the zone:

```elixir
defp ahead_of?(date, time, now, tz) do
  case Date.diff(date, DateTime.to_date(now)) do
    diff when diff <= -2 -> false
    diff when diff >= 2 -> true
    _ -> DateTime.compare(from_site_wall(date, time, tz), now) == :gt
  end
end
```

The shortcut is only safe if it never disagrees with the resolution it replaces, so
that is what the new test asserts rather than the shortcut's own arithmetic — 126
combinations (6 zones including the `+14`/`-12` extremes, ±3 days, three hours of the
day), each cross-checked against `from_site_wall/3`.

### NITPICK: `site_now/0`'s doc pointed at a function the PR deleted

The moduledoc said the carrier "compares against `scheduled_at/2` directly", but
`scheduled_at/2` was removed in this same commit — the private helper `from_site_wall/3`
replaced it. **Fixed** (points at `to_site_wall/2` now).

`site_now/0` is itself now **caller-free in production**: `filter_published/1` moved to
`utc_now/0` + `site_tz/0`, `scheduled_ahead?/1` builds its own, and the only remaining
reference is its own test. Left in place — it is documented public API of the module
and the honest name for "now on the site's clock" — but it is worth deleting the next
time this file is opened if nothing has picked it up.

### NITPICK: stale pointer in the feed's comment

`effective_datetime/1`'s comment sent the reader to `Constants.site_now/0` for what "the
site's wall clock" means. `to_site_wall/2` is the function that actually defines it now.
**Fixed.**

### NOTE — API surface: `scheduled_ahead?/2` was removed without deprecation

The arity-2 clause is gone (replaced by `/3`) in a published Hex package, in a minor
release. No caller exists in any `phoenix_kit*` sibling or host application in this
workspace, so nothing breaks here — recording it so the CHANGELOG says so.

---

## Verified clean

Checked and found correct, so the next reader does not have to re-derive them:

* **No double-shift on display.** The premise the whole PR rests on — `post_date`/
  `post_time` are shown as-is — holds: core's `format_date_with_timezone_cached/4` and
  `format_time_with_timezone_cached/4` pass a `%Date{}`/`%Time{}` straight to the
  formatter and only shift `%DateTime{}`/`%NaiveDateTime{}`. The admin listing
  (`web/listing.ex format_datetime/3`) and the public renders therefore still show the
  stored wall clock, not a wall clock shifted a second time.
* **Cache shapes are struct-typed.** `Mapper.to_listing_map/4` puts `post.post_date` and
  `post.post_time` in the cached map unchanged (`:date` / `:time` Ecto types), so
  `from_site_wall/3`'s struct-only head cannot be reached with a string from
  `:persistent_term`. The defensive `match?(%Time{}, ...)` in `listing_sort_key/1` and
  `effective_datetime/2` is belt-and-braces, not evidence of a looser shape.
* **The editor's new-post prefill is still raw UTC** — `build_virtual_post/4` sets
  `date`/`time` from `UtilsDate.utc_now()` while `Posts.maybe_add_initial_timestamp/3`
  now stamps the site's wall clock. It does not surface: `base_form/1` has no date or
  time field, `generate_form_key/3`'s `:new` clauses ignore both, the URL is
  `/…/new`, and `create_post` overwrites both with `Map.merge/2` before insert. Not a
  drift, and deliberately not "fixed" — shifting `now` there would also move
  `published_at`, which is a genuine UTC field.
* **Unresolvable zone values degrade consistently.** `to_site_wall/2` returns the
  instant untouched (via `TimeZone.shift/2`) and `from_site_wall/3` falls back to
  reading the wall clock as UTC, so a `time_zone` value neither IANA nor numeric puts
  both directions on UTC rather than on two different clocks.

---

## Files changed by this review

| File | Change |
|------|--------|
| `lib/phoenix_kit_publishing/web/controller/feed.ex` | Hoist the `time_zone` read to one per document; thread `tz` through `item_xml/6`, `pub_date/2`, `last_build_date/2`, `effective_datetime/2` |
| `lib/phoenix_kit_publishing/constants.ex` | `ahead_of?/4` date-window short-circuit ahead of the zone resolution; fix the `scheduled_at/2` doc pointer |
| `mix.exs` | `phoenix_kit` floor `~> 2.4` → `~> 2.14`, so a host cannot resolve a core on which the fix is a no-op |
| `test/core_pin_conformance_test.exs` | Pin-guard fixtures moved to the new floor; moduledoc records that a floor can be set by core *behaviour*, not only by a missing function |
| `test/phoenix_kit_publishing/scheduled_release_test.exs` | New test cross-checking the short-circuit against `from_site_wall/3` over 126 zone/day/hour combinations |

## Related

- Previous PR: [#42](/dev_docs/pull_requests/2026/42-canonical-host-resolver/)
- Core helpers: `PhoenixKit.Utils.TimeZone.shift/2`, `from_wall/2`; `PhoenixKit.Utils.Date.parse_datetime_local/2`
