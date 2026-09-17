# PR #51 Review — Add module-owned migration chain for the 7 publishing tables

**Author:** Tymofii Shapovalov <timujeen@gmail.com>
**Reviewer:** Claude (Anthropic)
**Status:** Merged — post-merge review, fixes applied on `main`
**Commit:** `44ced4e`
**Date:** 2026-09-17

---

## Verdict

Sound. The PR adds `PhoenixKitPublishing.Migrations` and sets
`migration_module/0` on the facade. V1 only adopts the 7 tables core already
builds: it creates any missing table, key, constraint or index under guards
that match on shape, then stamps `pkpub_schema:1` on
`phoenix_kit_publishing_groups`. `down/1` only touches that marker. I found no
bug in the DDL or the version readers. The findings below are one factual
error in the moduledoc, one fragile README recipe, one stale TODO, and one gap
in test coverage.

### What I verified independently, not from the PR description

1. **V1 builds exactly core's shape.** I ran `up_statements/2` into an
   empty scratch schema (with a stub `phoenix_kit_users` table and the
   `uuid_generate_v7()` function). Then I compared its catalog with the
   `public` tables core's chain built in the test database: every column
   (type, width, nullability, default), every
   `pg_get_constraintdef` and every `pg_indexes.indexdef`, with the schema
   qualifier stripped. **Result: 109 rows on each side, identical.** That is
   7 PK + 1 UNIQUE + 12 FK constraints and 30 indexes (the 22 standalone ones
   plus the 8 that back constraints). A second run changed nothing.
2. **The two `DESC` indexes and the three partial predicates** match what
   Postgres records. If the `indoption` normalisation or the `pg_get_expr`
   text were wrong, the guards would miss existing indexes and create
   duplicates, and those duplicates would show up in the comparison above.
   None did.
3. **The protocol matches what core calls.** `PhoenixKit.Migrations.Modules`
   calls `migrated_version_runtime(prefix:)` and `current_version/0`, and
   `mix phoenix_kit.update` writes a host migration file that calls `up/1`.
   All of them are exported with the expected arities.
4. **`Helpers.ensure_extension!("pgcrypto")` is safe on existing installs.**
   It checks `pg_extension` first and returns `:ok` when the extension is
   present, so a role without `CREATE` privilege is never asked to create it.
5. **Full suite:** 1687 tests, 0 failures, integration tests included, before
   any of my changes.

---

## Findings

### IMPROVEMENT - MEDIUM — No test compares V1 with the real catalog

`migrations_test.exs` compares the emitted SQL with the text of core's
`ExpectedSchema` manifest. The renamed-host and expression-index tests build
their fixtures *from `up_statements/2` itself*, so they cannot catch V1
drifting away from what core actually built. The Phase 2 promise (a fresh
install with no core baseline still gets the same schema) rested only on the
research pass described in the moduledoc.

**Fixed:** added `test/phoenix_kit_publishing/migrations_catalog_parity_test.exs`.
It automates check 1 above inside the sandbox: V1 runs into an empty
`pkpubparity_host` schema, and its catalog must equal `public`'s both ways.
Two count assertions (20 constraints, 30 indexes) keep it from passing when
nothing was built, and a second test checks that running V1 twice changes
nothing. To confirm the test has teeth, I changed `PublishingPost`'s `slug`
width from 500 to 499: the test failed, naming the column.

### NITPICK — The moduledoc gives the wrong reason for V164's partial index

The `idx_publishing_posts_group_slug` section said the index became partial
because NULL slugs "collide under the old plain-UNIQUE semantics … on some
Postgres versions' interpretation quirks". That is wrong. A Postgres unique
index treats NULLs as distinct unless it is declared `NULLS NOT DISTINCT`, so
NULL slugs never collided. Core's `postgres.ex` V164 notes give the real
reason. The partial shape dates from pre-squash V68, but V68 dropped the old
index with a bare, unqualified `DROP INDEX IF EXISTS`. That drop was a silent
no-op under a named prefix, so prefixed installs, and the V135 squash, kept
the plain shape until V164 converged them.

**Fixed:** rewrote that paragraph. The conclusion (adopt the post-V164 shape)
was already correct.

### NITPICK — README drop recipe named a constraint

The "Removing this module" SQL broke the posts ↔ versions FK cycle with
`ALTER TABLE … DROP CONSTRAINT fk_publishing_posts_active_version`. On a host
whose constraints were renamed, which is the scenario the PR's guards are
built for, that statement fails. One `DROP TABLE t1, …, t7` statement resolves
the cycle itself without naming any constraint. I checked this against a
two-table cycle with a renamed FK in the test database.

**Fixed:** the recipe is now a single `DROP TABLE` over all 7 tables, and the
moduledoc cross-reference now matches it.

### NITPICK — Stale AGENTS.md TODO and architecture tree

The `url_slug` partial UNIQUE index TODO still said "This module owns no
chain, so it is a core migration". With this PR that is backwards: it is V2
of this chain, plus the Phase 1 core `ExpectedSchema` exclusion and floor
bump. The architecture tree also didn't list `migrations.ex`.

**Fixed:** updated both.

---

## Considered and left as-is

- **`up/1` re-queues `CREATE OR REPLACE FUNCTION uuid_generate_v7()` on
  existing installs.** Core's own chain does the same, and the helper already
  skips a function owned by another role. Harmless.
- **FK guards ignore `ON DELETE`.** This is deliberate and documented: V1
  adopts and does not repair. A host whose referential action differs is a
  V2+ question.
- **`test_helper.exs` applies `up_statements/0` through `SQL.query!` rather
  than `up/1`.** That skips the migration-context reader, but the
  data-safety test already covers `up/1` through `Ecto.Migration.Runner`.
- **The moduledoc is long.** It is also the only record of the ownership and
  phase reasoning that a V2 author must read, so I left it as is.
