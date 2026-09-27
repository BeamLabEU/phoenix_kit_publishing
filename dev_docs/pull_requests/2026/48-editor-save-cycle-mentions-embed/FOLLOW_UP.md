# Follow-up

## Fixed (pre-existing)

- ~~Primary-language `url_slug` stripped before conflict validation (BUG HIGH)~~ — `d6200ed`; `persistence.ex:120-126` validates first
- ~~Five new pieces untested (IMPROVEMENT HIGH)~~ — `d6200ed`; `db_storage_mention_and_rename_test.exs`, `embed_test.exs`, `post_links_test.exs`
- ~~`Posts` alias out of order (NITPICK)~~ — `d6200ed`
- ~~Three credo refactoring findings (NITPICK)~~ — `e87a294`

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

None.
