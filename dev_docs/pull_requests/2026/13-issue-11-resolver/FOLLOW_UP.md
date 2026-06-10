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

## Fixed (pre-existing — verified 2026-06-11)

- **#1 — Unify the three base→dialect resolvers.** Done in a later PR.
  The shared resolver is now `LanguageHelpers.resolve_dialect_for_base/3`
  (`lib/phoenix_kit_publishing/language_helpers.ex:392`), whose `opts`
  carry the tie-break as `prefer:` (primary-language preference) /
  `exclude:` — exactly the `resolve_in/3` + `:tie_break` shape the review
  envisioned. Both context entry points delegate to it:
  `Posts.resolve_language_to_dialect/1` (`posts.ex:840`, `prefer:` =
  primary) and `Web.Controller.Language.find_dialect_for_base/2`
  (`language.ex:269`, no prefer = first-match), plus `StaleFixer`
  (`stale_fixer.ex:543`). The DB-cached primary read is lifted out and
  passed in as the `prefer:` opt by the caller, so the side effect no
  longer lives in the helper. The duplication is gone; the remaining
  two thin wrappers are just context-specific callers of one shared
  helper with different opts — the desired end state.

## Files touched

| File | Change |
|---|---|
| `AGENTS.md` | Added two-stage resolution flow diagram + unification follow-up note under the Base→enabled-dialect bullet |

## Verification

- 2026-05-18: `AGENTS.md` content review only. No code edits in that sweep.
- 2026-06-11: re-verified `#1` is resolved by `resolve_dialect_for_base/3`
  (source-read of `posts.ex:840`, `language.ex:269`, `stale_fixer.ex:543`).

## Open

None.
