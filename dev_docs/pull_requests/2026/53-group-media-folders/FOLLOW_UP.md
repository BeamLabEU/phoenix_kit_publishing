# Follow-up

## Fixed (pre-existing)

- ~~Two media tests order-flaky on a same-ms UUIDv7 tie-break (BUG MEDIUM)~~ — `0e6ac10`; `media_fixtures.ex` `backdate!/1`

## Awaiting a decision (surfaced 2026-09-27)

Not deferred unilaterally: each is a preference the reviewer left open, listed for Max to fix, skip or punt.

- `post_folder/1` runs `live_folder/1` once per version pointer (`media_folders.ex:295-300`) — `Enum.uniq/1` before `find_value/2`; one line, per pick, off the LiveView
- Orphan joins on `lower(data->>'media_folder_uuid')` cannot use an index (`media_reorganizer.ex:134,184,224-236`) — an expression index is a V2 migration; only if the manual reorganize task gets slow
- Editor filing warns on a forged other-library pick while adoption skips silently (`media_folders.ex:741-744` vs `media_adoption.ex:252`) — downgrade to `debug` or leave; the reviewer endorsed the current level

## Skipped (with rationale)

- `create_version_from/3` takes no post lock; a new version may miss the pointer — harmless: `post_pointer_query/1` takes the newest version with a pointer

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

The three preferences above.
