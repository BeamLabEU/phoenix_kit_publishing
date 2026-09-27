# Follow-up

## Fixed (pre-existing)

- ~~`:phoenix_kit ~> 2.0` floor admitted cores without `put_slug/3` (BUG CRITICAL)~~ — `1567be7`; floor since `>= 2.38.0 and < 3.0.0`, `core_pin_conformance_test.exs`
- ~~Trashed group still owned its slug; `add_group/2` probed active-only (BUG HIGH)~~ — `1567be7`; `DBStorage.all_group_slugs/0`
- ~~Suffix loop nested (`-2-3`) and ignored max length (BUG MEDIUM)~~ — `1567be7`; `Slug.ensure_unique/3`
- ~~Tests pinned the changeset path production doesn't take (NITPICK)~~ — `1567be7`; `group_slug_test.exs` "the path the admin UI takes"
- ~~Stale `:needs_unreleased_core` exclusion (note)~~ — `1567be7`
- ~~phase1: version bump / floor / merge sequencing~~ — `1567be7`, CHANGELOG 0.6.0

## Awaiting a decision (surfaced 2026-09-27)

Not deferred unilaterally: each is a preference the reviewer left open, listed for Max to fix, skip or punt.

- `Publishing.valid_slug?/1` omits the reserved route words (`publishing.ex:720-722` vs `slug_helpers.ex:44`) — a group named "Admin" slugs to `admin` and is shadowed by host routes; adding the check may reject existing names — maintainer's call
- Two slug rules for one column: context `SlugHelpers.slugify` vs changeset `put_slug` (`groups.ex:786`, `publishing_group.ex:143`) — hand the changeset the context's slugify or drop the changeset generator; documented as deliberate
- Seven-line history comment above `put_slug` (`publishing_group.ex:136-142`) — trim to one line; style

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

The three items above.
