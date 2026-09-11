# PR #49 Review — Style public mentions as links, not hover-only text

**Author:** Sasha Don <alexdon@fotki.com>
**Reviewer:** Claude (Anthropic)
**Status:** Merged — post-merge review, fixes applied on `main`
**Commit:** `7f4b5ca`
**Date:** 2026-09-11

---

## Verdict

A six-line, single-purpose fix, and it is correct. The resolved
`[[post:UUID|Alias]]` anchor carried daisyUI's `link link-hover`, which renders an
underline only on `:hover` — so a publication mention (PR #48's feature) read as
plain prose on the public page until the pointer happened to cross it. The PR
swaps it for `link link-primary`.

I verified the two claims the commit message makes, because both are the kind of
thing that is easy to assert and wrong:

1. **"the exact classes `add_tailwind_classes` puts on ordinary in-body anchors."**
   True — `@tag_patterns` in `renderer.ex:363` is literally `{"a", "link link-primary"}`,
   and `renderer_test.exs:46` already pins `<a class="link link-primary"` for a plain
   markdown link. A mention and an ordinary link are now visually identical, which is
   the right outcome: a reader should not have to learn that one kind of link is
   invisible.
2. **"the mention pass runs after that styling step, so the classes are inlined here."**
   True, and it is the reason **no `@cache_version` bump was needed** — which is the
   one thing this PR could plausibly have gotten wrong. `@cache_version` (`"v8"`)
   exists precisely to drop cached HTML when render output changes for unchanged
   source, and changing an emitted class string is exactly that shape of change.
   But `resolve_post_links/2` is invoked from
   `web/controller/post_rendering.ex:304`, *after* `Renderer.render_post/2` returns
   the cached HTML — the mention anchor is built fresh on every request and never
   enters the cache. A bump here would have been a pointless cluster-wide
   re-render of every cached post. Correctly omitted.

No `publishing-post-link` CSS rule exists anywhere in `lib/`, `test/` or the host
CSS contract, so the marker class carries no styling that the swap could conflict
with. `link-primary` is already emitted by the ordinary-anchor path, so Tailwind's
`@source` scan over `phoenix_kit_publishing` already retains it — no purge risk.

One gap: it shipped with no test.

---

## Findings

### IMPROVEMENT — MEDIUM: the fix had no test, so a revert would be silent

**File:** `test/phoenix_kit_publishing/web/controller/post_links_test.exs`

The only assertion touching the resolved anchor was `assert html =~ "publishing-post-link"`
— the marker class, not the styling classes. Nothing anywhere in the suite pinned
`link-primary`. Reverting to `link-hover`, or a future refactor of
`render_post_link/2` that rebuilds the class list, would leave every test green
while the bug this PR fixed silently came back. That matters more than usual here
because the symptom is *invisible by construction*: a mention styled as plain text
looks fine in a rendered-HTML assertion and fine in a screenshot until you move a
mouse over it.

The unit-level `resolve_post_links/2` tests in `renderer_test.exs` cannot cover this
— they all exercise the unresolvable-target branch, which returns bare text with no
anchor at all (the file says so in a comment: the resolved branch "needs a real post
to link to" and lives in `post_links_test.exs`).

**Fix applied:** extended the existing "resolves to the target's current public URL"
integration test to assert the full class string and to refute the old one:

```elixir
assert html =~ ~s(class="link link-primary publishing-post-link")
refute html =~ "link-hover publishing-post-link"
```

The `refute` is deliberate rather than redundant: it names the specific regression,
so a failure reads as "the hover-only styling came back" instead of "some class
string changed".

---

## Testing

- [x] Unit tests added/updated — integration assertion strengthened
- [x] Integration tests pass
- [ ] Migration tested on staging — n/a, no schema change
- [x] Backward compatibility verified — render cache untouched by design
- [x] Documentation updated — n/a; the inline comment the PR added is accurate

## Related

- Previous PR: [#48](/dev_docs/pull_requests/2026/48-editor-save-cycle-mentions-embed/) — introduced the mention feature this restyles
