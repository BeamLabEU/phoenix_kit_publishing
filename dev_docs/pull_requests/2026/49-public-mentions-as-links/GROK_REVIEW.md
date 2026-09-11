# PR #49 Review — Style public mentions as links, not hover-only text

**Author:** Sasha Don <alexdon@fotki.com>
**Reviewer:** Grok (xAI)
**Status:** Merged — post-merge review on `main` (already released as 0.10.1)
**Commit:** `7f4b5ca`
**Date:** 2026-09-11

---

## Verdict

Agreed with the earlier review: the six-line class swap is correct, and the
two claims the commit makes both hold against the code they depend on.

1. **`link link-primary` matches ordinary in-body anchors.** `@tag_classes`
   still maps `{"a", "link link-primary"}`. A mention and a markdown link are
   now the same visual object, which is the right outcome.
2. **No `@cache_version` bump is required.** `Web.Controller.PostRendering.render_post_content/2`
   calls `Renderer.resolve_post_links/2` *after* `Renderer.render_post/2`
   returns (cached or not). Preview does the same after `render_markdown/2`.
   The mention anchor is built per request and never enters the render cache.
   Bumping `v8` would have been a pointless cluster-wide re-render.

The follow-up test in `post_links_test.exs` pins the full class string and
refutes `link-hover`, so a revert fails loudly. I did not add more coverage
on this PR.

The 0.10.1 credo split of `render_post_link/2` into `mention_text/2` +
`wrap_mention_in_anchor/2` preserves the old `cond` clause-for-clause,
including the alias-vs-title escaping asymmetry (alias comes out of already-
rendered HTML; the title fallback is escaped here). `%{href: href} when is_binary(href)`
is slightly safer than the old `is_nil(target.href)` (a map missing `:href`
used to `KeyError`; now it degrades to plain text).

---

## Findings

### IMPROVEMENT — MEDIUM: the 0.10.1 credo refactor shadowed `@component_tags`

**File:** `lib/phoenix_kit_publishing/renderer.ex`

Not introduced by this PR's hunk — it landed in the post-merge review commit
that also pinned this PR's class string. The credo extract of
`has_embedded_components?/1` reused the module attribute name
`@component_tags`, which already holds the Leaf `preserve_tags` list at the
top of the file (bare tag names, including `Note` and `Image`).

Elixir expands attributes at the use site, so `component_tags/0` (defined
above the second assignment) kept returning the Leaf list — the existing
`editor_preserve_tags_test.exs` still passed. Any later function that read
`@component_tags` would have silently received the detection prefixes
(`"<CTA"`, `"<Headline"`, …) instead. Two lists that must stay in sync,
sharing a name, is the exact shape of bug this repo has been bitten by.

**Fix applied:** renamed the detection list to `@embedded_component_prefixes`.
Behaviour unchanged; `<Image>` stays a separate regex; `<Note>` stays out of
the mixed-pipeline detector because notes are extracted before this check.

---

## Testing

- [x] Unit tests added/updated — class assertion already in `post_links_test.exs`
- [x] Integration tests pass
- [ ] Migration tested on staging — n/a
- [x] Backward compatibility verified — render cache untouched by design
- [x] Documentation updated — this file

## Related

- Previous PR: [#48](/dev_docs/pull_requests/2026/48-editor-save-cycle-mentions-embed/)
- Sibling PR: [#50](/dev_docs/pull_requests/2026/50-create-group-ghost-card/)
