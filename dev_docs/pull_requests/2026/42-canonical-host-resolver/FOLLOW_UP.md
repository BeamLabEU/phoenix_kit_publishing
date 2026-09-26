# Follow-up

## Fixed (pre-existing)

- ~~`strip_language_prefix/2` stripped the base code, not the sibling dialect's URL segment (BUG HIGH)~~ — `9fbe091`; `controller.ex:1001-1015` uses `public_url_segment/1`; `canonical_host_resolver_test.exs:106`

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

None.
