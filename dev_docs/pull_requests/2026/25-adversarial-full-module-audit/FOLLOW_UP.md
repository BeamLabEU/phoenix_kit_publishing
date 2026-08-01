# FOLLOW_UP — PR #25 (Adversarial full-module audit)

Triaged 2026-08-01. The review's own "Still open" list was re-checked against
current code; most had been closed by later work, and the rest were fixed in
this pass.

## Fixed (pre-existing)

- ~~**M-A — multi-line single-backtick code span renders a component live.**~~
  Closed by the PR #26/#27 re-review: `@code_region_regex` is now
  `` `(?:[^`\n]|\n(?!\n))*` `` (`renderer.ex:315`), which spans soft line
  breaks but stops at a paragraph boundary. Both the M-A case and the
  over-match regression it would have introduced are pinned in
  `renderer_test.exs`.
- ~~**Double-escaped `&` in code spans.**~~ N/A — the escaper was replaced.
  `mask_scanned_code/1` (`renderer.ex:893`) now masks only `<` with a
  sentinel and leaves everything else to MDEx, so ampersands are never
  touched.
- ~~**`regenerate_slug` missing the `readonly?` guard.**~~ Present at
  `web/editor.ex:679`, alongside `translation_locked?`.
- ~~**Slug-truncation warning droppable by an unrelated `update_meta`.**~~
  `maybe_warn_slug_truncated/2` is re-asserted from the current title at both
  call sites (`web/editor/forms.ex:322,342`) rather than latched once.
- ~~**Translation button double-enqueue.**~~ All three translate buttons carry
  `phx-disable-with` and a `disabled` gate on
  `ai_translation_status in [:enqueued, :in_progress]`.
- ~~**Preview-tab loading indicator.**~~ The Preview button has a spinner and
  `[&.phx-click-loading]:pointer-events-none` (`web/editor.ex:2499`).
- ~~**Video insertion paths inconsistent.**~~ One insertion path remains
  (`web/editor.ex:1366`), emitting the `<Video url="">` shape the renderer
  matches.

## Fixed (2026-08-01)

- ~~**Stale doc comments after L12.**~~ `listing_cache.ex` and
  `web/settings.ex` said "all three prefixes"; there are two (commit b825d3d).
- ~~**Duplicated `page` on listing 301s.**~~ `with_query_string/2` now drops
  keys the target URL already names, so a paginated canonical no longer emits
  `?page=2&page=2`. Unit-pinned in `canonical_query_test.exs` (b825d3d).
- ~~**`record_previous_url_slug` clears the slug on an explicit nil.**~~ A
  present-but-empty `url_slug` means "leave it alone"; taking it literally
  blanked the row's slug and filed the old one as a previous slug, so the post
  lost its address and gained a redirect to nothing (b825d3d).
- ~~**`clear_translation/5` trailing-default trap.**~~ Both 5-arity functions
  now guard `is_nil(version) or is_integer(version)`, so a keyword list in the
  version position raises instead of binding there and silently no-opping.
  Pinned in `cross_group_scope_test.exs` (4c6c6cc).
- ~~**`reset_translation_state` drops the lock mid-translation on version
  switch.**~~ Versions with a translation running are tracked, so leaving and
  returning restores the lock instead of unlocking the editor mid-write.
  Pinned in `editor_translation_lock_test.exs` (a1769ca).
- ~~**Multi-tab sync (listed here as "design decision pending").**~~ Resolved
  as a data-loss fix rather than a UX change: a tab with unsaved work is no
  longer reloaded over when another tab saves (4c6c6cc). Two tabs of the same
  account remain co-owners; the second one now keeps its buffer and is told
  the row moved.

## Skipped

- **Centralise the `"published"` status string** (~96 occurrences). Mechanical
  and wide; raised with Max rather than folded into a correctness pass.

## Verification

`mix test` 1525 tests / 0 failures; `mix compile --warnings-as-errors` clean;
`mix credo --strict` at 9 refactoring opportunities (one below the baseline
this sweep started from).

## Open

None.
