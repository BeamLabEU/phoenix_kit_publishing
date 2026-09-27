# Follow-up

## Fixed (pre-existing)

- ~~Editor post crumb kept the old title after a same-URL save (IMPROVEMENT MEDIUM)~~ — `0e6ac10`; `assign_page_trail/2`; `header_trail_test.exs:131`

## Awaiting a decision (surfaced 2026-09-27)

Not deferred unilaterally: each is a preference the reviewer left open, listed for Max to fix, skip or punt.

- Move dialog's tree is a snapshot taken at open (`categories_live.ex:164`; `reload_tree/1` does not touch `:move`) — re-prune `move.tree` in `reload_tree/1` when `@move` is set; the context already refuses stale targets — UX preference

## Skipped (with rationale)

- Core `Activity.log/1` logs a warning where the old wrapper was silent — intentional core behaviour
- One unreproduced failure in a 20-run loop — unnamed in the review; matches the documented sandbox/activity flake, no evidence either way

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

The move-dialog preference above.
