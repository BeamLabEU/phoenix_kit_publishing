# PR #48 Review — Editor save-cycle fixes, [[ publication mentions, and an &lt;Embed&gt; demo component

**Author:** Sasha Don <alexdon@fotki.com>
**Reviewer:** Claude (Anthropic)
**Status:** Merged — post-merge review, fixes applied on `main`
**Commit:** `b2943de`
**Date:** 2026-09-10

---

## Verdict

This is a large, mostly-correct PR: fourteen distinct editor save-cycle bug fixes
(slug rename sync, form-buffer clobbering, stale URL preview, etc.), a new
`[[post:UUID|Alias]]` cross-post mention feature resolved at request time so cached
pages never serve a stale link, and a new `<Embed>` iframe component. The commit
message documents its own prior review round (four fixes: double-escaping, slug
truncation, excerpt-token slicing, HTML-flattening) and one refuted finding. I traced
the save-cycle logic (`push_patch` skipping, form-buffer preservation, `db_post_slug`
tracking, the primary/translation `url_slug` split) end to end against the actual
callers and found it internally consistent — no further defects there.

Two real problems surfaced:

1. **A regression this review's own gate caught**: the "stop persisting the primary
   language's mirrored `url_slug`" fix deletes `url_slug` from the save params
   *before* the conflict-validation step, not just before persistence — so a
   primary-language save whose `url_slug` mirror happens to collide with another
   post's custom `url_slug` no longer shows the "URL slug already in use" modal; it
   silently drops the field and proceeds to save. `mix test` on `main` already pinned
   this exact behavior (`editor_live_test.exs`, "saving a url_slug owned by another
   post shows the conflict modal (M13)") and it was failing before this fix.
2. **No test coverage for any of the new functionality.** `DBStorage.search_posts_for_mention/2`,
   `DBStorage.rename_default_url_slugs/3`, `Renderer.resolve_post_links/2`,
   `Renderer.post_links_to_text/1`, and the entire `<Embed>` component shipped with
   zero tests — only `editor_preserve_tags_test.exs` was touched, and only for the
   editor-mode guard. Every comparable component (`<Audio>`) and query
   (`find_by_url_slug`) in this codebase has a dedicated contract test file.

Both are fixed below. `mix precommit` and the full `mix test` suite are clean after
the fixes.

---

## Findings

### BUG — HIGH: primary-language `url_slug` conflict check silently bypassed

**File:** `lib/phoenix_kit_publishing/web/editor/persistence.ex`, `do_perform_save_with_params/1`

The PR's "Stop persisting the primary language's mirrored url_slug" fix deleted
`params["url_slug"]` whenever `is_primary_language` was true, **before** calling
`validate_url_slug_for_save/2`:

```elixir
params =
  if socket.assigns[:is_primary_language],
    do: Map.delete(params, "url_slug"),
    else: params
# ... normalize, restore_default_url_slug ...
case validate_url_slug_for_save(socket, params) do
```

`validate_url_slug_for_save/2` treats an absent/blank `url_slug` as "nothing to
check" and returns `{:ok, params}` immediately — so on the primary language, the
conflict branch (`{:slug_conflict, info}`, which blocks the save and shows the modal)
can never fire. The save falls through to `do_perform_save/2` and attempts a real
write. In `editor_live_test.exs`'s M13 test, that write hits an unrelated FK
violation from the test's `fake_scope/1` fixture (`updated_by_uuid` doesn't exist),
turning a clean "URL slug already in use" modal into a confusing
`"Couldn't save this post. Updated by does not exist"` flash — which is exactly what
the regression looks like once the validation step is skipped. Confirmed the test
passed on the commit before this PR (`3bc6bda`) and fails at `b2943de`.

The primary language's `url_slug` form field is only ever a *mirror* (no input is
rendered for it), so the fix's intent — never let a stale mirror value overwrite the
content row — is correct. But dropping it *before validation* throws away the
conflict check along with the write: the codebase has no DB-level uniqueness
constraint on `url_slug` (see AGENTS.md's TODOs — "Custom `url_slug` uniqueness is
application-level only"), so this check is the only thing standing between a
programmatically-set primary-language `url_slug` (the domain layer accepts one; see
`Posts.update_post/4`) and a silent duplicate.

**Fix applied:** moved the primary-language strip to run *after*
`validate_url_slug_for_save/2` succeeds, on the validated params, right before
`do_perform_save/2` — via a new `drop_primary_language_url_slug/2` helper. The mirror
is still validated (and blocked with the conflict modal, or auto-cleared with a
notice, exactly as before this PR) but is never the thing that gets written on the
primary language.

**Test:** no new test added — `editor_live_test.exs`'s existing M13 test now passes
and is the regression guard.

### IMPROVEMENT — HIGH: no test coverage for any of the PR's new functionality

**Files:** `lib/phoenix_kit_publishing/db_storage.ex`, `lib/phoenix_kit_publishing/renderer.ex`,
`lib/phoenix_kit_publishing/page_builder/components/embed.ex`

Five substantial pieces of new logic shipped with no dedicated tests:

- `DBStorage.search_posts_for_mention/2` — the `[[` mention picker's query (cross-group
  title search, trashed-post/group exclusion, one-row-per-post dedup via
  `DISTINCT ON`, recency fallback for the empty query).
- `DBStorage.rename_default_url_slugs/3` — the post-slug-rename sync that carries
  default-tracking `url_slug`s along and files the old one as a 301.
- `Renderer.resolve_post_links/2` and `Renderer.post_links_to_text/1` — the
  `[[post:UUID|Alias]]` resolution/degradation logic (missing/trashed/unpublished
  target → plain text; alias-vs-title fallback; escaping).
- The `<Embed>` component — safe-src posture, height clamping, sandboxed iframe.

Every comparable piece of existing functionality in this module has a dedicated
contract test (`web/controller/audio_test.exs` for `<Audio>`,
`integration/db_storage_url_slug_lookup_test.exs` for the URL-slug queries). Without
tests here, a future refactor of any of these five functions has nothing pinning
its current behavior — including the escaping/truncation/flattening bugs this PR's
own prior review round already had to catch once.

**Fix applied:** added four test files, matching the existing conventions:

- `test/phoenix_kit_publishing/integration/db_storage_mention_and_rename_test.exs` —
  `search_posts_for_mention/2` (case-insensitive match, empty-query recency order,
  trashed post/group exclusion, one-row-per-post/highest-version-wins, limit) and
  `rename_default_url_slugs/3` (default-tracking rows follow a rename and file a
  301, customized rows are left alone, multi-language coverage, no-op case).
- `test/phoenix_kit_publishing/web/controller/embed_test.exs` — mirrors
  `audio_test.exs`: safe/unsafe `src` schemes, height clamping (160/1200/default),
  title/caption, `stretch`, the `component_tags/0` contract.
- `test/phoenix_kit_publishing/renderer_test.exs` (new `describe` blocks) —
  `resolve_post_links/2` (no-token passthrough, alias-not-double-escaped when the
  target can't resolve, bare token with no alias renders nothing, `<pre>`/`<code>`/`<a>`
  regions left literal) and `post_links_to_text/1` (alias reduction, bare-token
  drop, token-straddling-a-slice-boundary regression guard).
- `test/phoenix_kit_publishing/web/controller/post_links_test.exs` — end-to-end,
  DB-backed: a published mention resolves to the target's current public URL, a
  bare token uses the target's live title, a rename after the render cache is warm
  still resolves fresh (the actual point of resolving post-cache), and missing/
  unpublished/trashed targets all degrade to plain text. Also covers the listing
  excerpt reducing a token to its visible text.

All new tests pass; the full suite (`mix test`) is green at 1628 tests, 0 failures.

### NITPICK: two `mix credo --strict` findings introduced by the PR

- `renderer.ex`'s new `alias PhoenixKit.Modules.Publishing.Posts` landed out of
  alphabetical order in the `alias` block. **Fixed** — moved after `PageBuilder`.
- The end-to-end mention test I added referenced `PhoenixKit.Modules.Publishing`
  inline instead of aliasing it (credo: "nested modules could be aliased at the
  top"). **Fixed** in `post_links_test.exs`.

Three more `credo --strict` refactoring-opportunity findings are new in this PR
(`Renderer.resolve_post_links/2` nests one level past credo's default max,
`Renderer.render_post_link/2` and `Renderer.has_embedded_components?/1` are each one
point over the cyclomatic-complexity threshold — the latter from simply adding
`Embed` to an existing boolean-OR chain). **Left as-is**: `mix precommit` does not
fail on these (they're "refactoring opportunities," not errors), and restructuring
already-tested, already-verified-correct logic purely to satisfy a complexity
heuristic risks introducing a new bug for no behavioral gain. Noting them here so
they're not mistaken for something this review missed.

---

## Things checked and found correct (no action taken)

- **`sync_default_url_slugs`/`rename_default_url_slugs` transaction placement** — runs
  inside the same `repo.transaction` as the rest of the save, after
  `upsert_post_content` (so it also catches the row upsert just rewrote) and using
  the pre-rename `db_post.slug` captured before `resolve_slug_in_tx` mutated the row
  — correct "old slug" identity.
- **`preserve_live_buffers/2`** — only applies on the routine-save path
  (`handle_post_save_success`) and the create/new-translation path
  (`handle_post_update_result`); traced both callers and confirmed the
  `is_new_post`/`is_new_translation` guard reads the socket assigns *before*
  `extra_assigns` flips them to `false`, so creation correctly adopts the DB echo
  instead of fighting it.
- **`maybe_patch_edit_url/2`** — only the create/new-translation path calls it; the
  routine autosave path never `push_patch`es at all (pre-existing), and the
  new-version path always patches unconditionally (correct, since its URL always
  changes). No path was found where a version-switch would incorrectly preserve a
  stale title/slug buffer.
- **`resolve_post_links/2` escaping** — the alias is inserted verbatim (already
  MDEx-escaped, since it's sliced from rendered HTML) while the DB-sourced title
  fallback and the href are explicitly escaped; verified with a test that a `&` in
  an alias renders once-escaped, not double-escaped.
- **`<Embed>`'s `sandbox="allow-scripts allow-same-origin allow-forms allow-popups"`**
  — matches the existing `<Audio>` trust model (admin-authored content only, `unsafe:
  true` rendering already documented in AGENTS.md) rather than introducing a new
  posture.
- **`defdelegate search_posts_for_mention(query, limit \\ 10)`** — default args on
  `defdelegate` are already an established pattern in `publishing.ex` (a dozen+
  existing delegates do this); not a compile risk.

---

## Gate

```
mix precommit   # compile --warnings-as-errors + format + credo --strict + dialyzer
mix test        # 1628 tests, 0 failures (was 1 failure before the fix, pre-existing on main)
```

---

## Files Changed (post-merge fix)

- `lib/phoenix_kit_publishing/web/editor/persistence.ex` — moved the primary-language
  `url_slug` strip to run after validation instead of before (new
  `drop_primary_language_url_slug/2` helper).
- `lib/phoenix_kit_publishing/renderer.ex` — reordered the `Posts` alias
  alphabetically (credo).
- `test/phoenix_kit_publishing/integration/db_storage_mention_and_rename_test.exs` — new.
- `test/phoenix_kit_publishing/web/controller/embed_test.exs` — new.
- `test/phoenix_kit_publishing/web/controller/post_links_test.exs` — new.
- `test/phoenix_kit_publishing/renderer_test.exs` — new `describe` blocks for
  `resolve_post_links/2` and `post_links_to_text/1`.
- `mix.exs` — version bump.
- `CHANGELOG.md` — new entry.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
