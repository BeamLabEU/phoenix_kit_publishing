# PR #55: Editor on Leaf done right, public-side fixes, core components, and the quality sweep

**Author**: Max Don
**Reviewer**: Claude
**Status**: Merged (squash)
**Commit**: `d6f9847` (plus follow-up `b6bd9c3`)
**Date**: 2026-09-27 (reviewed 2026-10-15, against `main` at `9e099a4`)

## Scope of this review

155 files, ~12.7k lines. Read for the highest-risk non-test code: the editor
flush / hand-over protocol (`web/editor.ex`, `web/editor/`), `ListingCache` with
`LockTableOwner` and `CacheSync`, `Views` and `Views.VisitorTable`, and the
controller / renderer changes. Not a line-by-line read of the public templates or
the core-component migration. Complements `GPT_REVIEW.md`; `FOLLOW_UP.md`'s four
"fixed" claims hold at HEAD.

## Verdict

Sound structure; no CRITICAL/HIGH finding. The flush protocol (unique refs, stale
refs ignored, 1.5 s indicator, 6 s abandon that clears all state and acts on no
stale text), the `install_snapshot/4` sequence ordering and tombstone, the
token-matched lock release, and `VisitorTable` (truncated HMAC only, never the raw
address; a full or absent table counts the view) all check out. No `String.to_atom`
on user input, no PII or changesets in activity metadata, PubSub topics scoped.

## Findings

### IMPROVEMENT - MEDIUM — `Listing` LiveView wiped the cache a mutation just regenerated

`handle_info({:cache_changed, slug}, …)` called `ListingCache.invalidate/1`. A
mutation regenerates the listing and broadcasts `:cache_changed`; every open Listing
view then erased the fresh term, wrote a tombstone and broadcast
`{:cache_invalidated, _}` to the cluster — M broadcasts per mutation for M open views,
each erasing every node's new listing. The in-code comment ("erase emits nothing") was
wrong, and AGENTS.md's Landmines name exactly this: a PubSub receiver must use
`erase_local/1`. The tombstone added in this PR made the pattern costlier.
**Fixed:** `erase_local/1`, comment corrected.

### IMPROVEMENT - MEDIUM — `client_events_test.exs` could not see most `push_event` calls

The scan regex matched only the piped form `push_event("x"`, so
`push_event(socket, "x", …)` (`sortable:flash`, `category_staged`) was invisible; a
future `push_event(socket, "set-content", …)` — the very regression the test exists
for — would pass. **Fixed:** the regex accepts the socket-first form and both events
are listed with their listeners (core's sortable hook; SearchPicker's `staged_event`).

### BUG - MEDIUM (not fixed) — autosave can drop the last keystrokes of a burst

`Helpers.mark_clean/1` sends Leaf `action: :mark_saved`; in Leaf's JS that does
`this._savedContent = this._currentMarkdown()` — the client's text when the command
runs, not what the server saved. A character typed after the last debounced push but
before `mark_saved` lands is baselined as saved; its push then arrives `dirty: false`,
`settle_on_saved_body/1` resets `@content` to the saved text and schedules no autosave,
and a later language switch replaces the buffer without it. Self-heals if the writer
keeps typing. Found by reading Leaf 0.8.0's JS, not reproduced in a browser.
**Not fixed here:** the right fix is on Leaf's side (`mark_saved` taking the saved
markdown) or a ref'd flush that baselines only when the reply equals the saved body;
either needs a browser to verify, and a guess in the flush protocol is riskier than
the narrow window. Recorded in FOLLOW_UP.

### IMPROVEMENT - MEDIUM (not fixed) — unique-view dedup collapses visitors behind a CDN / second proxy

`Views.visitor_hash/1` keys cookieless visitors on the LAST `x-forwarded-for` hop. With
CDN + load balancer (or Cloudflare + nginx) that hop is the edge, not the visitor, so
readers sharing an edge count once per post per day; `conn.remote_ip` is ignored even
when the host rewrites it. A client-supplied header with no proxy at all mints visitors
freely (no worse than before the PR). **Not fixed:** the correct behaviour depends on
the host's topology, so it needs a trusted-hops setting — a design decision.
In FOLLOW_UP.

### IMPROVEMENT - MEDIUM (not fixed) — AI translation can lock the editor if a job finishes before `:translation_started`

`:translation_started` is broadcast after `enqueue_all_missing` returns. A job that
finishes or fails earlier bumps `ai_translation_progress` while the total is nil, then
the start event resets progress to 0, so it can never reach the total and
`translation_locked?` stays true until reload. A race between two senders; predates
this PR; not reproduced. In FOLLOW_UP.

### NITPICK — not changed

- `ListingCache.erase_now/1` writes a tombstone for any slug and `Web.Settings`
  `invalidate_cache` takes the slug from client params, so an admin can create
  unbounded `persistent_term` entries. Admin-only; a known-group check would close it.
- `VisitorTable` sweeps every 24 h from boot, not at midnight, so up to two days of
  rows can sit under the 500k cap; each node has its own pepper and table, so a
  cookieless client counts once per node per day.
- `Index.mount` runs `dashboard_insights` on both the disconnected and connected mount.
