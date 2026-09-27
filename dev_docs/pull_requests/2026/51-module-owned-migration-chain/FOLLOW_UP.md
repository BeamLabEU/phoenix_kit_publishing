# Follow-up

## Fixed (pre-existing)

- ~~No test compared V1's catalog with what core built (IMPROVEMENT MEDIUM)~~ — `a267b14`; `migrations_catalog_parity_test.exs`
- ~~Moduledoc gave the wrong reason for the V164 partial index (NITPICK)~~ — `a267b14`
- ~~README drop recipe named a constraint (NITPICK)~~ — `a267b14`
- ~~AGENTS.md TODO said the module owns no chain (NITPICK)~~ — `a267b14`

## Skipped (with rationale)

- `up/1` re-queues `CREATE OR REPLACE FUNCTION uuid_generate_v7()` — matches core's own chain; the helper skips a foreign-owned function
- FK guards ignore `ON DELETE` — deliberate, documented at `migrations.ex:110-112`
- `test_helper.exs` uses `up_statements/0` not `up/1` — the data-safety test covers `up/1`

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

None.
