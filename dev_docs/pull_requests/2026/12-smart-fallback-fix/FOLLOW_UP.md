# Follow-up Items for PR #12

Triaged against `main` on 2026-05-05. `CLAUDE_REVIEW.md` approved the
PR ("Strong PR. … Approve.") and surfaced four small follow-ups, none
blocking. All actionable items had already been resolved in the merged
commit `7f547b5` (2026-05-02) "Post-PR#12 cleanup: eliminate redundant
group query, document params rewrite, add CHANGELOG"; this file
records the resolution and closes the open `dev_docs/pull_requests`
folder.

## Fixed (Batch 1 — 2026-05-02 — `7f547b5`)

- ~~**Comment the same-binding match trick** in `rewrite_params_after_shift/3`~~ —
  `web/controller.ex:113-114`. Two-line comment above the identity
  clause: `# Same-binding pattern: both heads match the same variable,
  so this clause / fires only when adjusted_params is identical to
  original_params (no shift).` Saves the next reader from staring at
  the unusual `(conn, original_params, original_params)` head shape.
- ~~**Thread `group_name` through assigns from `PostRendering.render_post*`**~~ —
  `web/controller/post_rendering.ex:81,128,143,363-368` +
  `web/controller.ex:245,275,306` + `web/preview.ex` (caller updated
  for the arity bump). `PostRendering.render_post/4` and
  `render_post_with_version/5` now load the group name once via
  `fetch_group_name/1` and put it into the assigns map alongside
  `:group_slug`; `build_breadcrumbs/3` was widened to `/4` to take the
  pre-fetched name. Three controller branches (`handle_post`,
  `handle_versioned_post`, `handle_date_only_url`) consume
  `assigns.group_name` instead of calling `Publishing.group_name(slug)`
  themselves — eliminates one redundant `Repo.get_by` per public page
  render. (As a follow-on this batch: `post_rendering_helpers_test.exs`
  was updated for the new arity — the original `build_breadcrumbs/3`
  call site at line 74 was a stale assertion left over from the
  refactor; now passes the new `group_name` arg explicitly and asserts
  on the resulting label.)
- ~~**Stale `conn.params["language"]` after `rewrite_params_after_shift/3`**~~ —
  `web/controller.ex:118-120`. Three-line comment inside the merge
  branch documenting that the original `"language"` key is preserved
  by `Map.merge` and may be stale after a language→group shift, but no
  downstream reader uses it (locale lives in
  `conn.assigns.current_language`), so the residual is intentional.
  Cheaper than dropping the key and signals intent.

## Skipped (with rationale)

- **CHANGELOG entry** — already landed in the same `7f547b5` commit
  (CHANGELOG 0.1.6 entry for PR #12 changes). Workspace memory
  [`feedback_phoenix_kit_releases.md`](~/.claude/projects/-Users-maxdon-Desktop-Elixir/memory/feedback_phoenix_kit_releases.md)
  marks releases boss-only, but Max approved the entry in the
  follow-up commit itself; nothing further to do.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_publishing/web/controller.ex` | Comment on same-binding match (113-114); comment on stale `language` key (118-120); 3× consume `assigns.group_name` (245/275/306) |
| `lib/phoenix_kit_publishing/web/controller/post_rendering.ex` | `fetch_group_name/1` helper (370-375); `group_name` threaded into assigns (90, 143); `build_breadcrumbs/3` → `/4` taking pre-fetched name (363-368) |
| `lib/phoenix_kit_publishing/web/preview.ex` | Caller updated for `build_breadcrumbs/4` arity bump |
| `CHANGELOG.md` | 0.1.6 entry for PR #12 (smart-fallback fix + migration cleanup + Phase 2 polish) |
| `test/phoenix_kit_publishing/web/controller/post_rendering_helpers_test.exs` | Update `build_breadcrumbs` test to the new `/4` arity (Batch 1 follow-on, 2026-05-05 — the cleanup commit missed this stale call site) |

## Verification

- `mix compile --warnings-as-errors` ✓
- `mix format` ✓ (only the pre-existing drift in `web/preview.ex` from
  before this branch — unrelated)
- `mix credo --strict` — 0 issues
- `mix dialyzer` — 0 errors
- `mix test` — 1000 tests, 0 failures (after dropping + recreating
  `phoenix_kit_publishing_test` to pull in the latest core V*
  migrations; the column drift causing `open_media_selector` to fail
  was stale local schema, not a code bug)

## Open

None.
