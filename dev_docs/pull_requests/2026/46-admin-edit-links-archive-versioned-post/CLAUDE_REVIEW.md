# PR #46 Review — Add admin edit links to the category/tag archive and versioned post views

**Author:** Tymofii Shapovalov <timujeen@gmail.com>
**Reviewer:** Claude (Anthropic)
**Status:** Merged — post-merge review, fix applied on `main`
**Commit:** `39759e7`
**Date:** 2026-09-07

---

## Verdict

The core change is correct and small: both branches (`handle_term_archive`,
`handle_versioned_post`) were genuinely missing `maybe_assign_admin_edit/3` relative to
their siblings, the wiring reuses the existing helper/template rendering path exactly
like the group listing and slug/date post views, and the new test file pins admin-vs-
anonymous visibility on both routes. `mix precommit` is clean and all four new tests
(plus the three I added) pass.

One finding: the category/tag archive handler assigns the **same** "Edit Categories"
link (pointing at `/admin/publishing/categories/:group`) regardless of whether the
current archive is a category or a tag. Tags aren't admin-managed entities in this
codebase — per the `Hashtags` moduledoc, "Body hashtags ARE the tag system... there is
no separate tags field" — so an admin standing on a **tag** archive (`/group/tag/howto`)
saw an "Edit Categories" button that opens the categories tree page, which has no way
to rename, merge, or otherwise touch that tag at all. Fixed by only assigning the link
for `{:category, _}` archives.

---

## Findings

### BUG — MEDIUM: tag archives got a mislabeled/dead-end admin edit link

**File:** `lib/phoenix_kit_publishing/web/controller.ex`, `handle_term_archive/4`

`handle_term_archive` serves both `{:category, slug}` and `{:tag, tag}` archives
(dispatched from `dispatch_parsed_path/3`). The PR's new call:

```elixir
|> maybe_assign_admin_edit(
  Routes.path("/admin/publishing/categories/#{group_slug}"),
  "Edit Categories"
)
```

runs unconditionally for both term types. `/admin/publishing/categories/:group`
(`CategoriesLive`) manages the hierarchical category taxonomy only — tags have no
admin surface at all; per `Hashtags`' moduledoc they're derived from `#hashtag` text
typed into the post body on save. An admin visiting a tag archive and clicking "Edit
Categories" lands on a page that cannot rename, merge, or delete that tag — a dead end
that also mislabels what they're being sent to edit.

**Fix applied:** replaced the single `maybe_assign_admin_edit` call with
`maybe_assign_term_admin_edit(conn, term, group_slug)`, which pattern-matches on the
term tuple and only assigns the categories link for `{:category, _}`; `{:tag, _}`
passes the conn through unchanged (no edit link at all, matching "there is nothing to
edit here today").

**Test added:** `admin_edit_links_test.exs` — "an admin sees no edit link on a tag
archive", using a post tagged via `#howto` in the body (mirrors the pattern already
used in `term_archive_test.exs`).

### Pre-existing (unrelated): `settings_live_test.exs` failing on `main`

Not caused by this PR, but caught by the gate: `mix test` on `main` (before any of
this review's changes) already had one failure — `settings_live_test.exs` asserted
the old `<title>Publishing Settings</title>` text. The title was intentionally
shortened to `"Publishing"` in the 0.9.0 release (see that CHANGELOG entry), and the
test was never updated. Fixed to pin the actual `<title>` tag.

---

## Gate

```
mix precommit   # compile + format + credo --strict + dialyzer — clean
mix test        # 1591 tests, 0 failures
```

---

## Files Changed (post-merge fix)

- `lib/phoenix_kit_publishing/web/controller.ex` — split the admin-edit assignment for
  term archives into a type-aware helper; bumped `Publishing.version/0` to match
  `mix.exs`.
- `mix.exs` — version bump `0.9.0` → `0.9.1`.
- `test/phoenix_kit_publishing/web/controller/admin_edit_links_test.exs` — added a tag
  fixture and a test pinning that tag archives get no admin edit link.
- `test/phoenix_kit_publishing/web/settings_live_test.exs` — fixed the stale
  pre-existing title assertion.
- `CHANGELOG.md` — 0.9.1 entry covering both fixes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
