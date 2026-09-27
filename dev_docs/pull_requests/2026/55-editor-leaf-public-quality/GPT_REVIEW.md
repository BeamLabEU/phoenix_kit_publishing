# Review of PR #55

Reviewed merged commit `d6f9847` against its parent, with fixes based on `6fe9695`.
Reviewer: GPT / Codex. Date: 2026-09-27.

## Findings and fixes

### BUG - HIGH: creating a version can discard Leaf's latest keystrokes

`Web.Editor.handle_event("create_version_from_source", ...)` saved only the
server's current assigns before copying the source row and navigating away.
Unlike the newly corrected language/version switches and Preview, this path
never requested Leaf's debounced client buffer. Text still on the client could
be absent from both the saved source and its new copy.

Fixed by routing creation through `after_flush/2`, then saving before copying.
The continuation also checks whether the editor became read-only while waiting.
A LiveView regression test holds the flush reply, verifies no new version exists,
then replies with unsent text and verifies that both versions contain it.

### BUG - MEDIUM: visitor-table capacity suppresses all new views

`Views.VisitorTable.first_view_today?/3` used `size < limit and insert_new(...)`.
At 500,000 rows it returned false for every visitor, so unique-view counting
stopped globally until old entries were swept. This contradicted the documented
fallback of continuing to count without retaining additional visitors. When the
table was absent, `:ets.info/2` returned `:undefined`; Erlang term ordering also
made that comparison false, bypassing the intended rescue fallback.

Fixed the short-circuit condition to return true at capacity or when the table is
absent. Tests cover ordinary deduplication and a full table, including verifying
that accepting a new view does not grow it.

### BUG - MEDIUM: cold builds omit publishing routes from the test router

The initial full suite failed four dispatch end-to-end tests with 404s. An
isolated rerun passed. Core's router macro checks the optional dispatch module
with `Code.ensure_loaded?/1`; during this package's own cold compilation, that
module is being compiled alongside the test router and may not yet be loaded.
The macro can therefore omit the entire dispatch scope and override.

Fixed the test harness with `require PhoenixKitPublishing.RouterDispatch` before
expanding `phoenix_kit_routes()`. This creates a compile-time dependency. An
ordinary module-body `Code.ensure_compiled!/1` was insufficient because the macro
had already expanded; a cold rebuild reproduced that distinction. All four tests
pass after `mix clean --only test` with the compile-time dependency in place.
Production hosts consume the already compiled dependency; no core change is
needed for this package's test compilation race.

### IMPROVEMENT - MEDIUM: remove obsolete operational guidance

Updated AGENTS.md to describe the 1.5-second waiting indicator and 6-second
cancellation, and to include Create Version among flush-dependent actions.
Removed TODOs already resolved by this PR: version fallback's permanent redirect,
full-code canonical redirects, acting on an unanswered flush, and missing
address-based visitor deduplication. Corrected the Views moduledoc's forwarded-hop
description to match its implementation.

## Validation

- Initial full suite: 1,903 tests, four dispatch failures.
- Targeted visitor/editor/dispatch suite: 22 tests, zero failures.
- Cold-build dispatch suite after the compile dependency fix: four tests, zero failures.
- Final full suite: 1,906 tests, zero failures, including database-backed tests.
- `mix format` and `mix precommit`: passed (warnings-as-errors compilation,
  unused-lock check, Hex audit, format check, strict Credo, and Dialyzer).
  Dialyzer used the existing 14 suppressions; no new suppressions were added.
- `git diff --check`: passed.

The review covered editor buffer handover and save/copy paths, public fallback and
language canonicalization, cache write ordering, visitor counting, category
broadcasts, the migration changes, and the API/UI cleanup. Browser JavaScript was
not exercised by a real browser; the Leaf regression uses its actual server-side
message protocol through LiveViewTest. No version bump or release was requested.
