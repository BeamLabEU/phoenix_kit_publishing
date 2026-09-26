# Follow-up

## Fixed (pre-existing)

- ~~Ghost card had no active/Trash gating test (IMPROVEMENT MEDIUM)~~ — `e87a294`; `index_live_test.exs:185`
- ~~"Create Group" orphaned in the catalogues; PR 48 msgids never extracted (NITPICK)~~ — `e87a294`
- ~~`mix precommit` red on main: three credo findings (BUG MEDIUM)~~ — `e87a294`
- ~~Dialyzer `guard_fail` in `normalize_editor_mode/1` (BUG)~~ — `e87a294`
- ~~(grok) Empty state hid the Trash tab when all groups were trashed (BUG MEDIUM)~~ — `5272585`; `empty_dashboard?/3`
- ~~(grok) Empty-state CTA used `href`, ghost card `navigate` (NITPICK)~~ — `5272585`

## Skipped (with rationale)

- `aria-label` duplicates the visible span label — harmless, left by design

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

None.
