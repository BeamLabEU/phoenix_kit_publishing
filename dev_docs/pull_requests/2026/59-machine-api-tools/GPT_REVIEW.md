# Review of PR #59

Reviewer: GPT / Codex. Date: 2026-10-23.
Merged commit: `9e7e617`; recheck based on `04a2017`.

## BUG - MEDIUM: language metadata is absent from concurrency checks

`Common.post_revision/3` hashed the language and its title/body, but omitted
`content.data` and `url_slug`. `Common.post_state/4`, used by confirmation
fingerprints, included `url_slug` but also omitted `content.data`. OpenGraph
overrides live in that data, separately from the version metadata already hashed.

Reproduction: read a revision, change only `og_title` through `update_post`, then
submit a different `og_title` with the old revision. The stale update succeeded.
Likewise, preview an OG replacement, change the stored OG title to another value,
and preview the same replacement: its fingerprint stayed identical even though
the approval's displayed old value changed. A confirmation could overwrite the
new metadata without asking the approver to review that change.

Fixed by using the same content value snapshot for revisions and confirmation
state: language, `url_slug`, title/body digest, and a hash of content data.
Timestamps remain excluded. The guide now documents those fields. Revision and
confirmation hashes are opaque; clients holding an earlier hash must read or
preview again after this change.

Regression coverage includes stale-revision rejection with the newer OG value
preserved, fingerprint changes after a metadata edit, and a real core executor
confirmation round trip that refuses redemption with `reason: "changed"`.
Existing value-snapshot tests also cover metadata and per-language URL changes.
The new handler and snapshot assertions failed before the fix.

## Scope and limits

Read the API handlers and shared resolution/presentation/schema/danger logic,
with particular attention to Claude's omitted areas: group/category planning and
writes, publish/unpublish, trash/restore, AI enqueueing, refs and response shapes.
Traced OG storage through `Posts.upsert_post_content/6` and `put_og_overrides/2`,
version/content query ordering, category parent validation, and the existing
executor tests. Rechecked the text rule and tool schema contracts. Existing
conformance, static, integration and executor tests complement the source review.

No further blocking issue was established in those paths. The documented
check-to-write windows and the two-step scheduling/translation operations remain;
this patch does not turn revisions or confirmations into atomic compare-and-swap.
The seven canonical URL tests require a newer core helper and are excluded on
the locked Hex core 2.63.0. Core executor and database-backed tests do run.

## Validation

- Baseline: 2,713 tests, zero failures, seven excluded.
- Focused API/executor/sanitiser checks after both fixes: 224 tests, zero failures.
- `mix precommit`: passed, including compilation with warnings as errors, lock
  audit, Hex audit, format, strict Credo and Dialyzer. The existing 14 Dialyzer
  suppressions were used; none added.
- Final full suite: 2,718 tests, zero failures, seven canonical URL tests excluded.
- `git diff --check`: passed.
- Version and CHANGELOG are unchanged.
