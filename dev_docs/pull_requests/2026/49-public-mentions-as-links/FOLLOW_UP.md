# Follow-up

## Fixed (pre-existing)

- ~~Class swap had no test (IMPROVEMENT MEDIUM)~~ — `e87a294`; `post_links_test.exs:60-61`
- ~~(grok) `@component_tags` name reused for detection prefixes (IMPROVEMENT MEDIUM)~~ — `e87a294`; `@embedded_component_prefixes`

## Skipped (with rationale)

- (grok) `%{href: href} when is_binary(href)` remark — approving, no action

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

None.
