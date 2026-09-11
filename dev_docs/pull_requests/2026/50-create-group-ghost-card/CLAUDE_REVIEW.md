# PR #50 Review — Move Create Group from the navbar into the grid as a ghost card

**Author:** Sasha Don <alexdon@fotki.com>
**Reviewer:** Claude (Anthropic)
**Status:** Merged — post-merge review, fixes applied on `main`
**Commit:** `f0b330f`
**Date:** 2026-09-11

---

## Verdict

A pure-UI relocation, and it is behaviourally correct. The create action moves out
of core's navbar `:page_action` slot and into the groups grid as a dashed ghost card,
gated to the active view. I traced the four states the dashboard can be in and the
gating holds in all of them:

| State | `@empty_state?` | Rendered |
|-------|-----------------|----------|
| Active, ≥1 group | `false` | grid + ghost card ✓ |
| Active, 0 groups | `true` | empty-state card with its own CTA (ghost not reached) ✓ |
| Trashed, ≥1 group | `false` (`view_mode != "active"`) | grid, **no** ghost ✓ |
| Trashed, 0 groups | `false` | "Trash is empty" ✓ |

Two things I checked specifically, because they are the ways this change could have
broken something invisibly:

1. **Dropping `:page_action` from `mount/3` does not break core's layout.** Core
   reads it defensively — `layouts/admin.html.heex:31` passes `assigns[:page_action]`
   (not `@page_action`), `layout_wrapper.ex:105` declares it as an `attr` defaulting
   to nil, and the render site is guarded `:if={@action == [] and @page_action}`. An
   unset assign yields no button rather than a `KeyError`. Safe.
2. **`min-h-40` is a real utility here.** The module already ships `min-h-64`,
   `min-h-80` and `min-h-96`, so the full `min-h-*` spacing scale is in the host's
   Tailwind build; and `css_sources/0` puts an `@source` on this module, so
   `border-base-content/25` and `group-hover:text-primary` survive the purge too.

The `aria-label` duplicating the visible `<span>` label is redundant but harmless —
the computed accessible name is the same string either way. Left as-is.

Two gaps, both fixed below, plus a third problem the gate surfaced that predates
this PR.

---

## Findings

### IMPROVEMENT — MEDIUM: the only create affordance on a populated dashboard had no test

**File:** `test/phoenix_kit_publishing/web/index_live_test.exs`

Before this PR the create action was a `:page_action` map built in `mount/3` — a data
structure, trivially greppable, rendered by core. After it, the action is markup
inside a conditional branch of a 250-line `render/1`, and it is the *only* way to
create a group from a dashboard that already has one (the empty-state CTA appears
only at zero groups). Nothing in the suite asserted it exists, and nothing asserted
its one real rule — that it must never appear in Trash, where creating a group makes
no sense.

That combination is the bad one: a whitespace-level edit to the
`<%= if @view_mode == "active" do %>` guard, or a future refactor of the grid, could
delete the create action from the admin UI entirely and leave every test green.

**Fix applied:** added a `describe "the ghost create-group card"` block pinning both
gates — present in the active view, absent after switching to Trash.

The trashed-view test deliberately re-renders after the click rather than asserting
on the click's own return value:

```elixir
_ = render_click(view, "switch_view", %{"mode" => "trashed"})
html = render(view)
assert html =~ group["name"]
refute html =~ ~s|href="/admin/publishing/new-group"|
```

`switch_view` sets `loading: true` and defers the real load to
`{:deferred_view_switch, mode}`, so the click's own render is the *skeleton* — which
has no create link either. Asserting there would have passed for the wrong reason,
and would have kept passing if the gate were removed. The `assert html =~
group["name"]` proves the real grid is on screen before the `refute` means anything.

### NITPICK: `"Create Group"` left orphaned in all six gettext catalogs

**Files:** `priv/gettext/default.pot`, `priv/gettext/{de,en,et,fr,it,ru}/LC_MESSAGES/default.po`

The removed navbar button was the sole use of `gettext("Create Group")`. The PR did
not re-run `mix gettext.extract --merge`, so the msgid survived in the `.pot` and all
six `.po` files with a reference comment pointing at `web/index.ex:75` — a line that
no longer contains it. Translators would keep maintaining a string nothing renders.

**Fix applied:** re-extracted and merged. The orphan is gone; `"Create Publishing
Group"` now correctly lists its three live call sites.

Per AGENTS.md's warning that `gettext.merge` can reword an entry without flagging it
fuzzy, I diffed the catalogs before and after: `0 reworded (fuzzy)`, and the only
`msgstr` lost across all six files was `"Создать группу"` — the orphan's own Russian
translation. No collateral damage.

The merge also surfaced a **backlog from PR #48**, which likewise never re-extracted:
six msgids (`"Link a publication"`, `"That publication no longer exists."`,
`"Displays as:"`, `"Interactive demo"`, `"Live demo (iframe)"`, `"Try it"`) had never
entered any catalogue. Since `de`/`et`/`fr`/`it`/`ru` were otherwise 100% complete —
zero empty `msgstr` before this — leaving them blank would have leaked English into
five fully-translated admin UIs. Translated all six in all five languages. `en` is
left on msgid fallback, matching that catalogue's own convention (156 entries already
rely on it).

### BUG — MEDIUM: `mix precommit` was already failing on `main` (pre-existing, not caused by this PR)

**File:** `lib/phoenix_kit_publishing/renderer.ex`

Running the repo's own gate, `mix precommit` exits **8**: `credo --strict` reports
three refactoring opportunities and the alias aborts before `dialyzer` ever runs.

This is not from #49 or #50 — `git stash && mix credo --strict` on untouched `HEAD`
reproduces all three identically, and `credo` has been pinned at `1.7.19` across
every commit back through `3bc6bda`, so no linter bump caused it. All three trace to
PR #48 (`b2943de`), which introduced `resolve_post_links/2` and `render_post_link/2`
and added `<Embed>` to `has_embedded_components?`:

```
[F] Function body is nested too deep (max depth is 2, was 4).      renderer.ex:447 resolve_post_links
[F] Function is too complex (cyclomatic complexity is 11, max 9).  renderer.ex:504 render_post_link
[F] Function is too complex (cyclomatic complexity is 10, max 9).  renderer.ex:853 has_embedded_components?
```

Worth stating plainly: PR #49 edited `render_post_link/2` — one of the two flagged
functions — and shipped without the gate being run. A red gate on `main` is corrosive
in exactly this way. Once it is red the next author gets no signal, and the rule in
AGENTS.md ("run before every commit") quietly stops being enforced.

**Fix applied:** all three resolved, without changing behaviour.

- `resolve_post_links/2`: the chunk mapper extracted to
  `resolve_post_links_in_chunk/2`, and its inline `~r/^<(?:pre|code|a)\b/i` hoisted
  to `@post_link_skip_head_re` beside the `@post_link_skip_re` it partners.
- `render_post_link/2`: split along its actual seams — `mention_text/2` (alias
  verbatim vs. escaped title fallback) and `wrap_mention_in_anchor/2`, whose three
  clauses pattern-match the three outcomes the old `cond` enumerated: no text → `""`,
  resolvable target → anchor, anything else → plain text. Each branch now carries the
  comment that explains it, including #49's `link-primary` rationale.
- `has_embedded_components?/1`: the ten-term `||` chain becomes `@component_tags`
  plus `Enum.any?/2`. `<Image>` stays a separate regex because it alone must match a
  newline after the tag name. Adding a component is now one list entry rather than
  another `||` — which is what let this creep past 9 in the first place.

Semantics are preserved clause for clause: `String.contains?` substring matching and
the escaping asymmetry between alias and title are unchanged, and the mention tests
(including #49's new class assertion) pass unmodified.

**Second-order finding.** Clearing credo let `dialyzer` run for the first time since
#48 — and it immediately failed on something credo had been masking:

```
lib/phoenix_kit_publishing/web/editor.ex:153:41:guard_fail
The guard test: is_binary(_mode :: :html | :hybrid | :markdown | :visual) can never succeed.
```

`normalize_editor_mode/1` has exactly one caller,
`normalize_editor_mode(Settings.get_editor_mode())`, and core's
`get_editor_mode/0` is specced *and implemented* to fold an unknown stored string
to `:hybrid` before returning — so it can only ever yield one of four atoms. The
`is_binary(mode)` clause was unreachable. Deleted; the `_mode` catch-all still
satisfies the comment's actual requirement (never hand Leaf an unrecognised mode,
since Leaf's own clauses have no catch-all). This is a good argument for the
"never commit through a red gate" rule: a genuine type error sat undetected behind
a style warning for two PRs.

---

## Testing

- [x] Unit tests added/updated — ghost-card gating pinned in `index_live_test.exs`
- [x] Integration tests pass
- [ ] Migration tested on staging — n/a, no schema change
- [x] Backward compatibility verified — `:page_action` absence is safe in core's layout
- [x] Documentation updated — n/a

## Related

- Previous PR: [#48](/dev_docs/pull_requests/2026/48-editor-save-cycle-mentions-embed/) — source of the credo regressions and the gettext backlog
- Sibling PR: [#49](/dev_docs/pull_requests/2026/49-public-mentions-as-links/)
