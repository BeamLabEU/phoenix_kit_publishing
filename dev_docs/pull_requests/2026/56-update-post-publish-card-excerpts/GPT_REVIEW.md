# Review of releases 0.12.0–0.13.1, including PR #56

Reviewer: GPT / Codex. Date: 2026-10-05. Baseline: `3ec1930`.
Scope: PRs #52, #53, #55, #56 and their release follow-ups. Examined the
publish/save contract, version browsing, Leaf document handover, media-folder
ownership, public canonical handling, listing-cache ordering, and visitor counting.
This is a targeted review of those interactions, not an exhaustive audit.

## Findings and fixes

### BUG - HIGH: the admitted Leaf minimum cannot complete editor actions

The dependency admitted Leaf 0.4.1, but PR #55's `after_flush/2` waits for
`{:leaf_flushed, %{ref: ...}}`. Preview, translation, version creation and
language/version switches therefore time out on an otherwise valid dependency
resolution. The document handover also relies on the newer `:set_content` dirty
baseline.

Verified against the actual published `leaf-0.4.1.tar`: its flush handler drops
the ref and it has no `leaf_flushed` event handler. Leaf's 0.5.1 changelog identifies
that release as the first published correlated-flush implementation; 0.5.0 was
never published. The current suite exercises the modern message protocol.

Fixed the requirement to `>= 0.5.1 and < 1.0.0`. This raises the necessary floor
while preserving the original instruction's purpose of admitting later 0.x
minors. Added a dependency-range regression test and updated AGENTS.md and
README upgrade guidance. Hosts must update their Leaf browser bundle too.

### BUG - HIGH: an update can mutate a post in a different group and report failure

`find_db_post_for_update/2` trusted a UUID without checking its group. Pairing
another group's slug with the UUID wrote content, then failed the group-scoped
readback with `:not_found`. The caller saw failure after a real mutation, with
cache/audit handling attributed to the wrong group. This is an older gap exposed
while reviewing PR #56's save/publish pipeline, not a new regression in #56.

Fixed UUID lookup to use the existing `DBStorage.get_group_post_by_uuid/3`.
The regression requests publication under the wrong group and verifies the error,
unchanged content, and unchanged draft/live-pointer state. It failed before the
fix because the submitted content had actually been persisted.

### BUG - MEDIUM: version history fails when the listing cache is disabled

The database fallback passed a UUID to `fetch_published_version/2`, whose lookup
expects an internal slug. It also read `allow_version_access` from the requested
historical version when that version's language was primary. Thus a valid
historical URL redirected instead of rendering, and the access flag could disagree
with the current live version. This also affects posts absent from the capped
listing cache.

Fixed the fallback to resolve the group-scoped post and its active-version
association, taking the flag and version number from that same live record.
Withdrawn or trashed posts return `{false, nil}`. Two regressions cover working
history with caching disabled and a historical flag that differs from the live
flag. Both failed before the fix.

### BUG - MEDIUM: the version dropdown advertises archived drafts

The dropdown included every version with status `archived`, although the route
requires an archived version to have a publication date and to be at or before
the current live version. Archiving an unpublished draft produced a public link
that immediately fell back instead of showing that version.

The mapper now carries `version_publication_dates` alongside version statuses
using the already-loaded rows. The dropdown applies the route's publication-date
and live-version-boundary rules without extra per-version queries. A regression
publishes v1 and v3 with an unpublished archived v2 between them and verifies
only v3 and v1 are offered. It previously offered all three.

### BUG - MEDIUM: blank versions omit the post's media-folder pointer

PR #53 stores a post's folder pointer on every version; copied versions preserve
it, but creating a blank version initialized `data` to an empty map. Subsequent
filing short-circuits when an older version already has a live folder, so it
does not repair this omission.

Blank creation now preserves only `media_folder_uuid` from the newest version
carrying it, leaving editorial metadata and body blank. Blank and cloned version
creation take the post lock before reading version data, matching filing and save
operations and preventing a folder claim from being missed by a concurrent copy.
The blank-version regression failed before the fix and verifies both the retained
pointer and exclusion of the source's editorial metadata.

## Additional documentation improvement

README's database setup still called V1 the current migration. Updated it to
describe V2's indexes and the existing-host update command. No migration or
schema change was needed for these fixes.

## Validation

- Before fixes: targeted database suite, 29 tests, five reproducible failures.
- After fixes: the same 29 tests pass.
- Full `mix test`: 1,921 tests, zero failures, with the test database available.
- `mix format` and `mix precommit`: passed, including compilation with warnings
  as errors, unused-lock check, Hex audit, format check, strict Credo and Dialyzer.
- `git diff --check`: passed. No new Dialyzer suppressions.

The Leaf minimum was verified through published source and a requirement test;
the full suite runs the installed Leaf version, not a separate host on 0.5.1.
No real-browser test was run. Existing library-test warnings about AI/comments
JavaScript bundling do not fail the gate. No version bump or publication was
requested or performed.
