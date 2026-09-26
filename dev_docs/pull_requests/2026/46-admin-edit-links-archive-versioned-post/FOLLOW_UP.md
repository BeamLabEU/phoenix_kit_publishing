# Follow-up

## Fixed (pre-existing)

- ~~Tag archives got a mislabeled dead-end "Edit Categories" link (BUG MEDIUM)~~ — `75a5ae3`; `maybe_assign_term_admin_edit/2`; `admin_edit_links_test.exs:87`
- ~~`settings_live_test.exs` asserted a stale `<title>` (gate)~~ — `75a5ae3`

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

None.
