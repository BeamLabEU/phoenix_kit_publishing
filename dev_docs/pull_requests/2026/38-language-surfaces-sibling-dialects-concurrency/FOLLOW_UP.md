# Follow-up

## Fixed (pre-existing)

- ~~`:translation_deleted` sent an integer version, editor compared a string (BUG HIGH)~~ — `2a9731e`; `translation_manager.ex` `version_row_scope/1`
- ~~Mirrored `editor_saved` reloaded same-key editors twice (IMPROVEMENT MEDIUM)~~ — `2a9731e`; `:sibling_editor_saved`
- ~~`same_post_and_version?/2` accepted `"vi"` as a version (NITPICK)~~ — `2a9731e`; `version_segment?/1` requires digits
- ~~Orphaned doc comment on `new_translation_request?/2` (NITPICK)~~ — `2a9731e`
- ~~Stale arity-2 `@spec broadcast_editor_saved` (NITPICK)~~ — `2a9731e`
- ~~AGENTS.md cited the deleted all-groups overview (NITPICK)~~ — `2a9731e`, rewritten `3bc6bda`

## Awaiting a decision (surfaced 2026-09-27)

Not deferred unilaterally: each is a preference the reviewer left open, listed for Max to fix, skip or punt.

- `neighbor_posts/3` walks the listing cache twice (`listing.ex:542-543`) — one fold producing posts + date counts; perf preference over `:persistent_term`
- Base-code guard blocks a safe `/en-gb` → `/en` fallback redirect (`listing.ex:158-160`) — guard on `public_url_segment/1` plus a redirect-loop test; today an empty listing, no loop

## Skipped (with rationale)

- `strip_components/1` can eat prose with `<Capital … >` — excerpt-only; accepted trade-off, tightening the regex risks worse

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

The two preferences above.
