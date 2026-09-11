# PR #50 Review — Move Create Group from the navbar into the grid as a ghost card

**Author:** Sasha Don <alexdon@fotki.com>
**Reviewer:** Grok (xAI)
**Status:** Merged — post-merge review on `main` (already released as 0.10.1);
fixes for the empty-state gating bug applied afterwards
**Commit:** `f0b330f`
**Date:** 2026-09-11

---

## Verdict

The relocation is behaviourally correct for the four states the earlier review
enumerated, **except one that table missed**: a dashboard with **zero active
groups and a non-empty Trash**.

Dropping `:page_action` is safe — core reads `assigns[:page_action]` with a
nil default. The ghost card's Tailwind classes are in this module's
`css_sources/0` `@source`, so they survive the host purge. Active-view-only
gating is the right rule (nothing is created in Trash). The earlier tests
pin presence in the active grid and absence after a deferred switch to Trash.

The missed state is a real user-facing bug, and it is worse after this PR
than before: the navbar button at least stayed visible after trashing the
last group. The empty-state card now replaces the whole dashboard,
including the Trash tab.

---

## Findings

### BUG — MEDIUM: empty-state hid Trash when every group was trashed

**File:** `lib/phoenix_kit_publishing/web/index.ex`

`empty_state?` was `groups == []` on mount, and
`groups == [] and view_mode == "active"` on refresh. The empty-state card
is the `if` branch that *replaces* the Active/Trash tabs and the grid.

Two paths hit it with groups still recoverable:

1. **Fresh mount** with 0 active groups and N trashed — the test that
   switches to Trash after mount never saw this, because
   `render_click(view, "switch_view", …)` fires the event even when the
   tab is not in the DOM. The initial `html` from `live/2` was never
   asserted.
2. **Trashing the last active group** — `trash_group` calls
   `refresh_dashboard/1` synchronously, `empty_state?` flipped to true,
   and the Trash tab disappeared on the same render as the flash
   "Group moved to trash". Restore was then unreachable from the UI.

The earlier review's four-state table treated "Active, 0 groups" as the
empty-state card and "Trashed, 0 groups" as "Trash is empty". It did not
consider "Active, 0 groups, Trash non-empty" on first paint.

**Fix applied:** `empty_dashboard?/3` is true only for
`([], "active", 0)` — no active groups *and* nothing in Trash. Mount and
refresh both go through it. A dashboard whose groups all sit in Trash
now shows the tabs plus the ghost create-card, which is the reachable
pair (create something new, or open Trash and restore).

Pinned with three tests: only-trashed on fresh mount, trashing the last
active group, and a truly empty dashboard (0 active, 0 trash) still
rendering the empty-state CTA.

### NITPICK: empty-state CTA used `href`, ghost card used `navigate`

**File:** `lib/phoenix_kit_publishing/web/index.ex`

The empty-state "Create Publishing Group" button was a full-page `href`
to the same LiveView the ghost card `navigate`s to, inside the same
`live_session`. After this PR the two CTAs are the only ways to create a
group; they should take the same path.

**Fix applied:** empty-state CTA now `navigate`s, matching the ghost card.

---

## Testing

- [x] Unit tests added/updated — empty-state vs Trash gating pinned in
      `index_live_test.exs`
- [x] Integration tests pass
- [ ] Migration tested on staging — n/a
- [x] Backward compatibility verified — `:page_action` absence is still safe
- [x] Documentation updated — this file

## Related

- Sibling PR: [#49](/dev_docs/pull_requests/2026/49-public-mentions-as-links/)
