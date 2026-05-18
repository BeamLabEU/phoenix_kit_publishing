# FOLLOW_UP — PR #13 (Issue #11 resolver)

Triaged 2026-05-18 against the post-merge state.

CLAUDE_REVIEW.md verdict was APPROVE with two non-blocking
codebase-shape observations — no findings tagged HIGH or MEDIUM.

## Fixed (Batch 1 — 2026-05-18)

- **Editor two-stage resolution flow diagram** added to `AGENTS.md`
  under the "Base→enabled-dialect resolution" critical-convention
  bullet. ASCII flow shows the URL → `new_translation_request?/2` →
  `resolve_language_for_post/2` against `post.available_languages`,
  then `read_post_by_uuid` → `resolve_language_to_dialect/1` against
  enabled languages. Closes follow-up #2 from the review.

## Skipped (with rationale)

- **#1 (codebase-shape) — Unify the three base→dialect resolvers**
  (`Posts.enabled_dialect_for_base/2`,
  `Web.Controller.Language.find_dialect_for_base/2`,
  `Web.Controller.Language.resolve_language_for_post/2`). The
  reviewer framed this as "~1 hour when next touching either
  layer." Deferred to its own PR because: (a) the helpers operate
  at different abstraction levels (one is a higher-level wrapper
  around another), (b) `enabled_dialect_for_base/2`'s primary
  tie-break does a DB-cached read (`LanguageHelpers.get_primary_language/0`)
  that's a side effect baked into the helper — purely-functional
  extraction needs more thought, and (c) the divergence is now
  documented in the AGENTS.md flow diagram so the next contributor
  knows it exists. Not blocking; not a live bug.

## Files touched

| File | Change |
|---|---|
| `AGENTS.md` | Added two-stage resolution flow diagram + unification follow-up note under the Base→enabled-dialect bullet |

## Verification

- `AGENTS.md` content review only. No code edits in this sweep.

## Open

- **#1** — Unify the three base→dialect resolvers into a single
  `Languages.resolve_in/3` with an explicit `:tie_break` opt. Wants
  its own focused PR with test verification.
