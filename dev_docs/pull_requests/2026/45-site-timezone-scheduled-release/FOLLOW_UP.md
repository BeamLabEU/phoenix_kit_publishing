# Follow-up

## Fixed (pre-existing)

- ~~`phoenix_kit ~> 2.4` floor let hosts resolve a core where the fix was a silent no-op (BUG HIGH)~~ — `5c660ab` (`~> 2.14`), superseded by `8c311a2` (`>= 2.38.0`)
- ~~RSS feed read `time_zone` twice per item (IMPROVEMENT HIGH)~~ — `5c660ab`; `feed.ex:63-66` hoists `tz`
- ~~`scheduled_ahead?/3` ~30× costlier per post on every request (IMPROVEMENT MEDIUM)~~ — `5c660ab`; `constants.ex` `ahead_of?/4` short-circuit
- ~~`site_now/0` doc pointed at a deleted function (NITPICK)~~ — `5c660ab`
- ~~Feed comment pointed at `site_now/0` (NITPICK)~~ — `5c660ab`
- ~~`scheduled_ahead?/2` removed without a CHANGELOG note (NOTE)~~ — `5c660ab`; CHANGELOG:284

## Awaiting a decision (surfaced 2026-09-27)

Not deferred unilaterally: each is a preference the reviewer left open, listed for Max to fix, skip or punt.

- `Constants.site_now/0` has no production caller (`constants.ex:98-99`; only its own test) — delete the function and its describe block, note the API removal — preference, harmless if left

## Skipped (with rationale)

- Editor new-post prefill is raw UTC — the review declined the change: the prefill never surfaces, shifting it would move `published_at`

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

The `site_now/0` preference above.
