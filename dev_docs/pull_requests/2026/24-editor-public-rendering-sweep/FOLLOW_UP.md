# PR #24 — Phase 1 follow-up (review catch-up)

After-action report for the Phase 1 pass on the PR #24 review
(`CLAUDE_REVIEW.md`, read-only). Picked up when the merge landed via a
`pull --rebase`. All work is local commits; nothing pushed. Suite
**1137 tests, 0 failures**; `mix format`, `mix credo --strict`,
`mix dialyzer` clean.

## Fixed (with regression tests)

- **#1 — `humanize_field/1` lowercased acronyms** (`errors.ex`). It ran
  `String.capitalize/1` over the whole field name, so `:url_slug` →
  "Url slug" and `:seo_title` → "Seo title" in flash messages. Now splits
  on `_`, uppercases known acronyms (`url`/`seo`/`og`/…), and sentence-cases
  the first word — "URL slug", "SEO title", while "active_version_uuid" still
  reads "Active version". Test in `errors_test.exs`.
- **#3 — slug-truncation warning wiped by the next keystroke** (`forms.ex`).
  `update_meta` clear_flash's up front, but `maybe_warn_slug_truncated` only
  put the warning on the false→true transition — so any further keystroke
  while the slug was still truncated dropped it. Now re-asserts the warning
  whenever the title is over the URL cap (clears when it shrinks back). LV
  test in `editor_live_test.exs`.
- **#4 — brittle test assertion** (`editor_live_test.exs`). Dropped
  `assert html =~ "does not exist"`, which coupled the test to PostgreSQL's
  FK-error wording; the neighbouring `assert "save this post."` /
  `refute "Failed to save post"` already prove the descriptive-flash behaviour.

## Evaluated — left as-is (intentional)

- **#2 — in-page OpenGraph defaults on.** Reviewer flagged that a host which
  *also* renders the forwarded `:og` in its own `<head>` emits duplicate
  og/twitter tags until it flips `publishing_render_og_tags`. Kept default-on:
  the common case is a host with no OG handling, which gets correct social
  previews out of the box; defaulting off would silently strip OG/Twitter tags
  from every vanilla CMS install to protect an advanced host that already has
  a one-toggle opt-out (documented in `AGENTS.md`). One-line flip if we ever
  want strict opt-in.

The review's one real bug (#1 in `CLAUDE_REVIEW.md` — `safe_to_string/1`
rescue too narrow) was already fixed in the merge itself (`c6a6754`), with its
own regression test.

## Open

None.
