# PR #38 — Claude review (post-merge)

Review of merged PR #38 — "Fix the public and admin language surfaces, add
sibling-dialect URLs, and harden concurrency" (`mdon/main`, merged
`5af474c`, author Dmitri Don). 51 files, +3,164 / −507 excluding the six
gettext catalogues (which are line-number churn from re-extraction).

Reviewed with the `elixir:phoenix-thinking`, `elixir:ecto-thinking`, and
`elixir:otp-thinking` skills — the change touches LiveView lifecycle and
PubSub fan-out, adds row locks and compare-and-swap writes to the Ecto
layer, and introduces a new supervised GenServer (`ListingCache.CacheSync`).

## Scope covered

Read in full with surrounding context: `pubsub.ex`, `posts.ex`,
`db_storage.ex` + `db_storage/mapper.ex`, `groups.ex`, `versions.ex`,
`translation_manager.ex`, `stale_fixer.ex`, `language_helpers.ex`,
`listing_cache.ex` + the new `listing_cache/cache_sync.ex`, `categories.ex`,
`comments.ex`, `ai_translatable.ex`, `shared.ex`, `renderer.ex`,
`router_dispatch.ex`, `presence_helpers.ex`, and every `web/` file in the
diff (`controller.ex`, `controller/{feed,language,listing,post_rendering,
translations}.ex`, `editor.ex` + `editor/{collaborative,persistence,
translation,versions}.ex`, `html.ex`, `index.ex`, `listing.ex`, `edit.ex`,
`new.ex`, `post_show.ex`, `settings.ex`, `categories_live.ex`).

The PR ships its own after-action report
(`dev_docs/2026-08-04-admin-language-sweep-FOLLOW_UP.md`) listing ~45
verified findings from an internal + external review panel, with 17 open
items deliberately deferred. That report is accurate — I re-verified a
sample of its claims against the code and found no overstatements. This
review only records what that process did **not** catch.

The load-bearing work is good. Spot-checking the riskiest claims:

- **The StaleFixer publish-revert race is genuinely closed.**
  `clear_active_version_if/2` and `demote_version_if_orphaned/2` are real
  compare-and-swap statements (`WHERE … AND active_version_uuid = $expected`
  / `WHERE … AND EXISTS (orphaned post)`), and `fix_active_pointer_cas/2`
  re-reads the post before the orphan demotion runs, so the two heals can't
  compose into "clear the fresh pointer, then draft the freshly published
  version."
- **The save-path lock is placed correctly.** `lock_post_row!/2` is taken
  *before* the `version` re-read inside the same transaction, so the
  `version.data` read-modify-write can't observe a pre-transaction snapshot.
  It is the same `FOR UPDATE` the publish machinery takes.
- **`Renderer.notes_section/1` gettext-at-render-time is safe with the
  render cache**, contrary to how it reads. `build_cache_key/2` includes
  `post.language`, and `render_post/2` (the only caching entry point) is
  reached solely from `PostRendering`, after `set_gettext_locale/1` — the
  admin preview path uses uncached `render_markdown/2`. No cross-locale
  cache poisoning is possible.
- **`Shared.strip_components/1`** behaves as documented on paired,
  self-closing, and truncated tags; `<Note>` keeps its inner phrase; the new
  `String.trim` + reject-empty in `extract_first_paragraph/1` correctly stops
  a stripped component block from becoming the "first paragraph."
- **`dashboard_summary` / `build_summary/2` / `editor_presence_topic/1`
  removals are clean** — zero remaining references in `lib/` or `test/`, and
  the deleted `Web.HTML.all_groups/1` was genuinely unrouted.

## Findings

### BUG - HIGH — `:translation_deleted` carries an integer version; the editor compares against a string, so the event is silently dropped

`translation_manager.ex` (both `clear_translation/5` and
`delete_language/5`) broadcast

```elixir
PublishingPubSub.broadcast_translation_deleted(
  group_slug, db_post.uuid, language_code, db_version.version_number   # integer
)
```

while `Web.Editor`'s handler filters with

```elixir
(is_nil(version) or version == current_version_scope(socket))
```

and `current_version_scope/1` returns `to_string(socket.assigns.current_version)`
— a **string**. `2 == "2"` is `false`, and `version` is never `nil` now that
both call sites pass a version, so **the guard can never pass**.

The PR's stated intent was "version-scoped like `:translation_created`", but
the sibling event passes `content_version_scope(new_post)`, whose own comment
says *"as the string the editor matches translation events against"*. The
deleted path skipped that helper.

Net effect: an editor tab open on a post never removes the language pill
when another admin (or the same admin in another tab) clears/deletes that
translation. Clicking the stale pill opens what is now a new-translation
form. Pre-PR the payload was versionless and the guard absent, so this is a
**regression** — the version-scoping fix inverted "always applies" into
"never applies."

The type split was pinned by the test the PR wrote, side by side:

```elixir
broadcast_translation_created(group, slug, "de", "2")   # string
broadcast_translation_deleted(group, slug, "fr", 2)     # integer
```

**Fixed.** Added `version_row_scope/1` to `TranslationManager` (the
version-row twin of `content_version_scope/1`) and routed both broadcast
sites through it; widened the stale `@spec broadcast_translation_deleted/3`
to the real 4-arity `String.t() | nil` shape and documented the contract on
the `@doc`. Tests: `pubsub_test.exs` now asserts the string payload with the
reason inline, and a new `translation_manager_test.exs` case subscribes to
the post-translations topic and asserts `delete_language/5` emits
`to_string(version.version_number)`.

### IMPROVEMENT - MEDIUM — the mirrored `editor_saved` broadcast makes same-key editors reload twice

`broadcast_editor_saved/3` mirrors `{:editor_saved, form_key, source}` onto
`post_translations_topic(group_slug, post_uuid)` so sibling-language editors
learn about shared version-level writes. But an editor on the **saver's own
form key** is subscribed to *both* `editor_form_topic(form_key)` (via
`Collaborative.track_and_subscribe/3`) and the post-translations topic (via
`subscribe_to_post_translations/1`, which keys on `broadcast_id/1` = the post
uuid). It therefore receives the same message twice and runs
`Persistence.reload_post/1` twice per remote save — two redundant post reads,
two form rebuilds, two `set-content` pushes.

**Fixed.** The mirror now carries a distinct `:sibling_editor_saved` tag with
its own `handle_info/2` clause; `{:editor_saved, …}` stays exact-form-key
only. Pinned by a new `pubsub_test.exs` case that subscribes to both topics
and asserts one of each tag.

### NITPICK — `same_post_and_version?/2` accepts a language code in the version slot

The pattern `{[group, uuid, "v" <> _ = version, _lang_a], …}` treats any
4-segment key whose third segment starts with `v` as version-scoped — which
includes the language code `"vi"`. Today's other 4-segment shape is the
socket-scoped new-post key (`"<group>:new:<lang>:<socket_id>"`), whose
holders aren't subscribed to a post-translations topic, so this isn't
currently reachable. It is a latent hazard the moment a key shape changes.

**Fixed.** Tightened to `v` + digits via `version_segment?/1`.

### NITPICK — orphaned doc comment in `web/editor.ex`

`same_post_and_version?/2` was inserted between `new_translation_request?/2`
and the comment block describing it, so the comment now documents the wrong
function (and `same_post_and_version?/2` had none).

**Fixed.** Comment moved back onto `new_translation_request?/2`;
`same_post_and_version?/2` got its own.

### NITPICK — stale `@spec` on `broadcast_editor_saved`

The function gained a third parameter; the spec still declared arity 2.
Legal Elixir (arity 2 exists), but it leaves the new argument untyped.

**Fixed.** Widened to `{String.t(), String.t()} | nil`.

### NITPICK — `AGENTS.md` still referenced the deleted all-groups overview

The PR removed `Web.HTML.all_groups/1` and updated three of the four
mentions; the "Translatable group name" section still listed "the all-groups
overview cards" as a surface resolving through
`Publishing.translated_group_name/2`.

**Fixed.** Replaced with the feed channel title (a real current consumer,
now that `Feed.render_rss/3` takes `scope_label`) plus a pointer to the
deletion note.

## Observations — not fixed, deliberately

- **`Listing.group_date_counts/1` adds a second full-group pass on post
  pages.** `neighbor_posts/3` already computes `chronological_posts/2`
  (fetch + `filter_published/1`); it now *also* calls `group_date_counts/1`,
  which repeats fetch + filter + `build_date_counts/1` over the same cached
  set (capped at 5,000 entries). The correctness argument for the change is
  right — date-URL resolution is language-agnostic, so the counts must be
  too — and the pass is over `:persistent_term` data, not the DB. Folding the
  two into one traversal is a straightforward follow-up if the listing cache
  ever grows past its cap; not worth the churn now.

- **`fallback_language_with_content/2` degrades to an empty listing for
  same-base sibling dialects.** Its loop guard compares
  `url_language_code(preferred) != requested_base`, i.e. base codes. Now that
  `public_url_segment/1` gives a non-owner sibling its own URL (`/en-gb/`),
  a request for `/en-gb/blog` with content only in `en-US` *could* safely
  redirect to `/en/blog` — the base-code guard suppresses it and renders the
  empty listing instead. Safe (no loop), just less helpful than it could be.
  Fixing it means teaching the guard about segments rather than bases, which
  is exactly the kind of subtle change that reintroduces a redirect loop; it
  wants its own PR with a dedicated loop test.

- **`strip_components/1` can eat prose containing `<Capital … >`.** e.g.
  `"Compare 5<Xylophone and 3>Y"` becomes `"Compare 5 Y"`. Excerpt-only (the
  rendered body is untouched), and tightening the regex risks missing real
  truncated component tags, which is the failure this heuristic exists to
  prevent. Correct trade-off as shipped.

- **Failure-side activity logging fans out to many call sites.** The
  `log_category_failure/5` and `log_translation_failure/6` chokepoints are
  well placed; `ActivityLog.reason_string/1` correctly collapses changesets
  to `"changeset_error"` so user free text never reaches metadata. No issue —
  noting it because it is the pattern new mutations should copy.

## Semantics worth knowing (behaviour changes, all deliberate)

Recorded here because they are user-visible and only documented in the
FOLLOW_UP:

1. **`delete_language/5` now hard-deletes** the content row instead of
   setting `status: "archived"`. The archive semantics were reader-dead (no
   read path filtered archived rows), so a "deleted" translation kept
   serving publicly and `create_version_from` resurrected it. Irreversible
   by design — versions are the undo mechanism.
2. **The primary language's content row can no longer be deleted** by either
   `clear_translation/5` or `delete_language/5` (`:cannot_delete_primary_language`).
   A legacy base-code row (`"en"` while primary is `"en-US"`) counts as
   primary; an enabled sibling (`"en-GB"`) does not.
3. **Non-owner sibling dialects get their own public URLs** (`/en-gb/…`)
   via `LanguageHelpers.public_url_segment/1`; the base's owner dialect keeps
   the historical base segment, so no existing URL changes.
4. **Collaborative form keys are version-scoped** (`<group>:<uuid>:v<N>:<lang>`)
   and new-post keys are socket-scoped. Anything comparing form keys by
   string must account for both shapes.

## Gate

`mix precommit` clean on the merged tree and again after these fixes:
`mix format` no changes, `mix compile --warnings-as-errors` clean, Credo
`--strict` **no issues** (2,716 mods/funs, 207 files), Dialyzer 0 new
(13 errors, 13 skipped by `.dialyzer_ignore.exs`).

`mix test`: **713 tests, 0 failures** (852 excluded — the DB-backed
integration and controller suites, which this environment has no PostgreSQL
for; per `AGENTS.md` that exclusion is expected and the gate, not `mix test`,
is the bar). The new `pubsub_test.exs` cases run and pass here; the new
`translation_manager_test.exs` case is DB-backed and runs under
`mix test --only integration` with a database present.

## Related PRs

- Previous: [#37](/dev_docs/pull_requests/2026/37-publishing-wave-leaf-categories-comments)
- PR's own after-action report: [`dev_docs/2026-08-04-admin-language-sweep-FOLLOW_UP.md`](/dev_docs/2026-08-04-admin-language-sweep-FOLLOW_UP.md)
