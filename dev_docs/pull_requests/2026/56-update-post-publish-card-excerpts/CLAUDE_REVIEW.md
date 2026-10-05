# PR #56: Fix update_post leaving a draft when asked to publish, and card excerpts overflowing their clamp

**Author**: Max Don
**Reviewer**: Claude
**Status**: Merged
**Commit**: `b620cda`
**Date**: 2026-10-05

## Goal

Two fixes. `Posts.update_post/4` with `"status" => "published"` used to save the
content, drop the status and answer `{:ok, post}` — a draft. It now publishes the
saved version through `Versions.publish_version/4` and reports a refused publish as
`{:error, {:publish_failed, reason}}`. Separately, listing cards' clamped excerpts
no longer stretch under daisyUI's `.card-body p { flex-grow: 1 }`.

## Verdict

Sound. The publish still goes through `publish_version`, so status and
`active_version_uuid` move together under the post's `FOR UPDATE` lock; the save
never writes the status itself. No correctness bug found.

## What was checked

- **Every `update_post/4` caller.** Only the three in `web/editor/persistence.ex`
  (all now `publish: false`) and `AiTranslatable.put_translation/4`, whose params
  carry only title/content/url_slug — it never sets `"status"`, so AI translation
  cannot start publishing translations.
- **Reachability of `:publish_failed`.** The doc says the primary-title check in
  `validate_primary_title!` can refuse after a translation saves. Confirmed
  against `versions.ex`; but the PR's tests never reached that branch.
- **Already-live versions** are saved, not re-published (`live?` guard); a post
  with `publish: false` is never touched.
- **Gettext.** The new msgid is translated in all six locale catalogues (de, en,
  et, fr, it, ru) and the `.pot`.
- **CSS.** `grow-0` on the three clamped `<p>`s overrides `.card-body p`.

## Findings

### IMPROVEMENT - MEDIUM — `{:publish_failed, _}` path had no test

The only test of a refused publish hit the save's own `:title_required` guard,
which fires *before* the write; the post-save refusal the PR introduced was
unexercised, including the claim that "the save stands".
**Fixed:** `update_post_publish_test.exs` blanks the primary title, saves an `et`
translation asking for `published`, and asserts the error tuple, the draft state,
and that the translation content was persisted.

### NITPICK — refusal reason logged with bare `inspect/1`

`maybe_publish_after_save/6` logged the publish reason through `inspect/1`;
AGENTS.md names `Errors.truncate_for_log/1` as the canonical way to put an opaque
reason in a `Logger` call (a changeset reason can carry submitted text).
**Fixed:** now `Errors.truncate_for_log(reason)`.

### NITPICK — AGENTS.md listed five Gettext locales, the repo has six

`de` ships a catalogue (and the PR added a `de` translation) but the convention
line read "en, et, fr, it, ru". **Fixed.**

## Not changed (on record)

- `update_post/4` still logs `publishing.post.updated`, regenerates the listing
  cache and broadcasts `:post_updated` *before* the publish step, so subscribers
  briefly see the draft snapshot and then `:version_live_changed`. The save did
  happen and the publish broadcasts its own events; reordering would make the
  audit row depend on the publish outcome. Left as is.
- The publish is a second transaction after the save, not one with it. That is the
  deliberate trade (documented in `update_post/4`): a failed publish leaves a
  saved draft and tells the caller, rather than losing the save.

## Verification

`mix test` on `update_post_publish_test.exs` and `errors_test.exs`: 29 tests, 0
failures. Gate result recorded in the release commit.
