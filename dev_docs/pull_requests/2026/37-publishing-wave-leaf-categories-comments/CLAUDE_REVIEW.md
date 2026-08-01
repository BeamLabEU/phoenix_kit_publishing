# PR #37 — Claude review (post-merge)

Review of merged PR #37 — "Publishing wave: Leaf editor, per-version
categories, gallery/notes/audio/comments, and a security pass"
(`mdon/main`, merged `557da34`, author Dmitri Don). 123 files,
+23,090 / −4,022 — the largest single change the module has taken.

Reviewed with the `elixir:phoenix-thinking` and `elixir:ecto-thinking`
skills (LiveViews, a public dead-view controller, new Ecto schemas, a
JSONB-backed taxonomy, and a stateful LiveComponent).

## Scope covered

New: `categories.ex`, `comments.ex`, `hashtags.ex`, `views.ex`,
`web/controller/feed.ex`, `web/categories_live.ex`,
`web/components/categories_picker.ex`, `page_builder/components/audio.ex`,
`schemas/publishing_category.ex`, `schemas/publishing_post_category.ex`.
Substantially changed: `renderer.ex` (+1010 — `<Showcase>`, `<Gallery>`,
`<Note>`, hashtag linkification), `web/editor.ex` (+1133 — Leaf editor),
`web/controller.ex` (+489), `web/html.ex` (+1019),
`web/controller/listing.ex` (+266), `posts.ex`, `versions.ex`,
`db_storage.ex`, `constants.ex`, `groups.ex`, `listing_cache.ex`,
`routing.ex`, `router_dispatch.ex`.

Much of it holds up well and the design comments are unusually good — the
`stale_snapshot?` guard in `ListingCache`, the `save_writable_status/2`
reservation that stops a stale form demoting the live version, the
`jsonb_set`-rather-than-read-modify-write reasoning in
`backfill_version_categories/1`, the `@component_tags` / `preserve_tags`
contract with Leaf, and the note-anchor content addressing are all correct
and correctly explained. Findings below are what did not hold.

---

## Findings

### 1. BUG — HIGH: scheduled posts go public at the wrong hour (fixed)

`Constants.scheduled_ahead?/1` (new in this PR) is the single predicate
that decides when a timestamp-mode post stops being embargoed. It built
the scheduled instant from `post_date` + `post_time` as if they were UTC
and compared it against `DateTime.utc_now/0`, with a docstring asserting
"Both comparisons are UTC, matching how the rows are stored and how the
editor writes them."

That premise is false. `Posts.maybe_add_initial_timestamp/3` — the L5 fix
already in the tree — stamps `post_date`/`post_time` through
`shift_to_site_timezone/1`, i.e. on the site's `time_zone` offset, and the
public side renders them with no display conversion. So the row is a
site-local wall clock and the comparison was against UTC:

- `time_zone = "-5"`: an announcement embargoed until 09:00 was **public at
  04:00 site time — five hours early**. This is the direction that matters;
  the whole point of the feature is holding an announcement back.
- `time_zone = "3"`: the same post appears three hours late.

Only a site left at the `"0"` default was correct, which is why it passed
review. All three call sites (`Listing.filter_published/1`,
`PostRendering.render_resolved_post/4`, `Fallback.published_timestamp_url/5`)
inherited it — the PR's own consolidation is what made the error uniform.

**Fixed.** `Constants` now owns the offset reading
(`site_offset_seconds/0`) and the site clock (`site_now/0`), and
`scheduled_ahead?/2` takes an explicit `now` so the release rule can be
pinned without a settings row. `Posts.shift_to_site_timezone/1` now
delegates to the same `site_offset_seconds/0` rather than keeping its own
copy of the `Integer.parse(Settings.get_setting("time_zone", "0"))` — a
second copy of that reading is precisely how the clock a post is *stamped*
on drifts from the clock it is *released* on.

`Listing.filter_published/1` hoists `site_now/0` out of the loop: it runs
over the whole listing cache (up to ~5,000 entries) on every public
request, and the offset is a settings read.

New pure-tier regression test:
`test/phoenix_kit_publishing/scheduled_release_test.exs` — including an
explicit assertion that the same post reads "already out" against the site
clock and "still scheduled" against UTC, which is the bug in one line.

### 2. BUG — HIGH: `mix test` fails on a checkout without Postgres (fixed)

`test/phoenix_kit_publishing/web/controller/dispatch_e2e_test.exs` (new)
uses raw `use ExUnit.Case` rather than one of the case templates, and so
never picked up the `@moduletag :integration` that `DataCase` / `ConnCase`
/ `LiveCase` all set. Its `setup` calls
`Sandbox.start_owner!/2` unconditionally.

`AGENTS.md` documents that integration tests are "automatically excluded
when unavailable" and that `mix test` is the whole-suite command. On a
machine with no test database the suite was **711 tests, 3 failures** —
every failure this one file, all `could not lookup Ecto repo`.

It is the only DB-touching test in the PR that misses the tag; the other 36
new files all inherit it from a case template.

**Fixed:** added `@moduletag :integration` with a comment explaining why
this file has to carry it by hand. Suite is now **715 tests, 0 failures
(817 excluded)**.

### 3. BUG — MEDIUM: RSS `pubDate` is off by the site's UTC offset (fixed)

Same root cause as #1, separate site.
`Feed.effective_datetime/1` builds `DateTime.new!(post.date, time,
"Etc/UTC")` from the site-local wall clock and `rfc822/1` then stamps every
item `+0000`. Every timestamp-mode item in every feed was dated by the
site's own offset, and `lastBuildDate` (an `Enum.max` over the same values)
with it. Feed readers sort and de-duplicate on `pubDate`, so this is
visible to subscribers, not just cosmetic.

**Fixed:** the site-local instant is converted back to UTC via
`Constants.site_offset_seconds/0` before it is stamped.

### 4. IMPROVEMENT — MEDIUM: a DB query per keystroke in the post editor (fixed)

`Web.Components.CategoriesPicker.update/2` opened with an unconditional
`Categories.list_tree(assigns.group_slug)` — a two-table join with an
`ORDER BY`.

A stateful `live_component`'s `update/2` runs on **every parent render**,
not only when its own assigns change. The parent here is `Web.Editor`,
which re-renders on `update_content` (each debounced keystroke),
`update_meta`, autosave completion, every collaborative broadcast, and
every presence event — and the component is rendered unconditionally in the
sidebar, not behind an `:if`. So typing a post body issued a category-tree
query per render.

The component's own docstring already justifies re-reading the tree **on
search** ("making a category happens in another tab… if this searched a
stale list, the new category wouldn't be findable") — that is the path
where freshness is load-bearing, and it is untouched.

**Fixed:** `update/2` reuses the tree it already holds and only re-reads
when the component is pointed at a different group; `handle_event
("category_search", …)` still re-reads every time, as designed.

### 5. BUG — LOW: `Hashtags.suggest/3` contradicted its own contract (fixed)

`tag_counts/1`'s comment: "keeping the spelling that occurs most often so
the popup offers `Elixir` if that's what the group actually writes." The
code keyed the tally on `String.downcase(tag)` and returned **the key**, so
the popup always offered `elixir`. No test covered it either way.

**Fixed** in the direction the comment states, since `extract/1` already
preserves the author's spelling ("first-spelling-wins") and the popup
disagreeing with the prose is the odd one out. `tag_counts/1` now tallies
the case-insensitive total while tracking spellings, and returns the
most-used one (tag as tie-break, because map iteration order is not
insertion order and an equally-common pair would otherwise swap between
cache rebuilds).

`suggest/3` now folds **both** sides before filtering and ordering —
without that, returning `"Elixir"` would have made typing `eli` match
nothing, turning a comment fix into a real regression.

Not covered by a test: `suggest/3` reads through `ListingCache`, whose miss
path regenerates from the database, so there is no pure-tier seam and no
existing DB-tier pattern for it. Flagged rather than pinned with a test I
could not execute here (see "Validation" below).

### 6. BUG — LOW: two dead branches in new code, found by dialyzer (fixed)

Both were masked by finding #7's dialyzer noise until it was cleared.

- **`Hashtags.tag_counts/1`** matched `{:ok, %{posts: posts}}` before
  `{:ok, posts} when is_list(posts)`. `ListingCache.read/1` is specced (and
  behaves as) `{:ok, [map()]} | {:error, :cache_miss}` — it hands back a
  bare list, never a `%{posts: …}` envelope; the generation timestamp lives
  under its own term key. The first clause could never match.
- **`Categories.update_category/3`** had `:error -> repo().rollback
  (:invalid_parent)` in its `with/else`. Every step in that `with` returns
  `:ok` or a tagged `{:error, reason}`, so a bare `:error` cannot arrive —
  meaning `:invalid_parent` was an atom the module could never produce.
  (I had registered it in `Errors` under finding #7 before dialyzer showed
  it was unreachable; it has been removed again rather than documenting a
  dead atom.)

Both clauses removed, with a comment recording why.

### 7. IMPROVEMENT — MEDIUM: new error atoms bypassed the `Errors` dispatcher (fixed)

`AGENTS.md`: "Add new error atoms by extending `@type error_atom`, the
doctest example, and adding a `def message(:new_atom)` clause."

The PR introduced new public-API error atoms and registered none:
`:params_not_applied` (`Versions.create_version/4`), `:category_cycle`,
`:parent_not_found`, `:parent_wrong_group`, `:invalid_order`
(`Categories`). `errors_test.exs` enforces that every atom *in the type*
has a message, so nothing failed — the atoms simply never reached the type.
They fell through to `gettext("Unexpected error: %{reason}")`.

`CategoriesLive` is insulated (it has its own `parent_error_message/1`),
but `Versions.create_version/4` is a facade-level call whose result does go
through `Errors.message/1`.

**Fixed:** all five added to `@type error_atom` with `message/1` clauses
and matching assertions in `errors_test.exs`. (A sixth, `:invalid_parent`,
turned out to be unreachable — see finding #6.)

### 8. BUG — MEDIUM: `mix precommit` / `mix quality.ci` was red (fixed)

The PR's `FOLLOW_UP.md` states "`mix format`, `mix credo --strict`,
`mix dialyzer` clean". On this checkout neither was: `mix credo --strict`
exited 14 with **22 issues** and `mix dialyzer` exited 2 with **7
warnings** — every one of the 29 in code this PR added or changed. So `mix
precommit` (which chains `quality.ci`) fails, and the repo's stated gate
("Always run before committing") was not green at merge.

**Dialyzer (7).** Six were `PhoenixKitComments.*` `unknown_function`s from
the new optional-plugin seam. `Comments` correctly carries
`@compile {:no_warn_undefined, …}` — but that only silences the *compiler*.
This repo's established convention for exactly this case is a
`.dialyzer_ignore.exs` entry, and the file's own comment for the
`PhoenixKitOG` seam spells out why ("Dialyzer doesn't understand that
directive"). The PR copied one half of the pattern and not the other.
**Fixed:** matching entry added for `comments.ex`, with the reasoning
carried over. The seventh was finding #6's dead clause. Clearing those six
then exposed two more that had been buried in the noise: an opaque-`MapSet`
violation in `Categories.walk_tree/4` (seeded with an empty
`MapSet.new()`, which dialyzer treats as a different parameterisation of
the opaque type than the populated one it recurses with — switched to a
plain map used as a set, which the sibling MapSets in the module don't need
because they are seeded with their elements), and finding #6's second dead
branch.

**Credo (22).** Breakdown: 12 × nested-module-not-aliased (`Views`, `Storage`,
`URLSigner`, the `Audio` component, `Phoenix.HTML.Safe`, `Sandbox`,
`Test.Repo`, `Posts`, `Renderer`), 1 × alias ordering (`Renderer` inserted
mid-block in `web/controller.ex`), 5 × nesting depth
(`Hashtags.linkify_part/4`, `Categories.update_category/3`,
`Categories.renumber_siblings/2`, `PublishingCategory.translated_name/2`,
`Renderer.extract_notes/2`), 4 × cyclomatic complexity
(`Controller.handle_parsed_path/3` at 12, `Controller.submit_comment/4` at
10, `PublishingCategory.translated_name/2` at 10,
`Editor.do_handle_media_selected/2` at **16**).

**Fixed**, all 22, as extractions rather than rewrites — behaviour is
unchanged. The two worth naming:

- `Controller.handle_parsed_path/3` — the trashed-group guard stays, and
  the eight-way `case` becomes eight `dispatch_parsed_path/3` clauses.
- `Editor.do_handle_media_selected/2` (complexity 16) — the five-branch
  `cond` becomes `media_selection_kind/2` (which of the five a Choose click
  means) plus one `apply_media_selection/3` clause each. **Branch order was
  load-bearing** and is preserved: an armed insertion mode wins over the
  plain slot assignment, and the audio type check still runs before the
  form is written.

One thing deliberately *not* consolidated while doing this:
`Controller.comment_posted_message/1` compares the comment's status to the
literal `"published"` rather than calling `Constants.published?/1`.
`published?/1`'s own docstring says not to — it is the publishing
vocabulary, and a comment's status lives on a different table with
unrelated meaning. (I made that substitution mid-refactor and reverted it.)

---

## Reviewed and accepted (no change)

These looked wrong on first read and are not:

- **`fragment("… @> ?", v.data, ^[category_uuid])` and
  `jsonb_set(?, '{category_uuids}', ?::jsonb)`** with an Elixir list
  parameter. There is no Ecto type information inside a fragment, so a list
  would normally encode as a Postgres array — but Postgres infers the
  parameter type from the operator/cast (`jsonb @> jsonb`, `$n::jsonb`) and
  reports it back at parse time, so Postgrex encodes via the JSONB
  extension. Correct as written.
- **`Hashtags` masking vs the `Renderer`'s.** `mask_scanned_code/1` only
  replaces `<` inside code regions with a sentinel; the backticks survive,
  so `Hashtags.linkify/2`'s own `@masked_regions` still matches the fences.
  The masked/unmasked asymmetry in `extract_notes/2` (masked content when
  notes exist, original when not) does not change hashtag behaviour.
- **`Renderer.build_cache_key/2`** does fold `notes_style` into the key, so
  flipping the group setting cannot serve the other style's cached HTML.
- **`showcase_styles/1` / `helix_styles/1`** keying on `class="pk-showcase `
  (trailing space) and `class="pk-helix` matches what the emitters actually
  produce.
- **`escape_html/1` encoding `#` to `&#35;`** inside gallery `src`/`alt`
  attributes is harmless — the entity decodes back to `#` in an attribute
  value — and is load-bearing for keeping the later hashtag pass out of
  note bodies.
- **`Comments.for_post_page/2`** indexing `comment.metadata["note_id"]`
  when `metadata` is `nil`: `Access` on `nil` returns `nil`, not a raise.
- **`redirect(to: …)` with an unvalidated `params["language"]`** in the
  comment POST path is not an open redirect — Phoenix's `redirect/2`
  validates `:to` as a local path.

## Known limitations left on record (not fixed)

- **Feed enclosures carry a *signed* Storage URL**
  (`Feed.enclosure/2` → `URLSigner.signed_url(uuid, "original")`). Podcast
  clients keep a feed for a long time and re-fetch enclosures on their own
  schedule; a signed URL that expires leaves dead audio in every cached
  copy. Fixing it needs a storage-side decision (a long-lived or unsigned
  variant for syndication), so it is a cross-repo item, not a publishing
  patch.
- **Search runs `ILIKE '%…%'` over `contents.content`** with no index —
  a sequential scan over every published body in the group, per request,
  on a public unauthenticated route. `@db_match_cap 2000` bounds the rows
  *returned*, not the rows *scanned*, and the `?q=` cap is 100 characters.
  Fine for a blog, a real cost for a large docs group; a trigram index or
  `tsvector` column is the fix and it needs a core migration.
- **`show_tags` was removed** from `Constants` / `PublishingGroup` /
  `GroupSettings` / `merge_group_config`. Groups that had it on keep the
  key in their `data` JSONB, now unread. Deliberate (the chip row is gone
  because tags moved into the prose) and documented in
  `dev_docs/2026-07-improvements-roadmap.md`; recorded here so the orphan
  key isn't mistaken for drift later.
- **`CategoriesPicker.matching/3` filters on `category.name`** while the
  chips render `PublishingCategory.translated_name/2`. An admin working in
  a non-primary language sees "Uudised" on the chip but has to type "News"
  to find it. Small, and the fix has a real design question behind it
  (match both spellings, or the displayed one only), so it is flagged
  rather than guessed at.
- **`ListingCache.regenerate/2` now calls
  `Categories.backfill_version_categories/1` on every regeneration.** The
  steady state is one `SELECT` over an empty table, which is the stated
  design — noted only because it is a new query on the cache-rebuild path.

## Validation

```
mix format --check-formatted      clean
mix compile --force --warnings-as-errors  clean
mix credo --strict                no issues          (was: 22)
mix dialyzer                      passed successfully (was: 7 warnings)
mix test                          715 tests, 0 failures, 817 excluded
                                                     (was: 711 / 3 failures)
```

**The integration tier did not run here.** This sandbox has no PostgreSQL
(`psql` is not on PATH), so 817 `:integration` tests — including every new
DB-backed test this PR added and the fixed `dispatch_e2e_test.exs` — were
excluded. The findings above were reached by reading against the emitters
rather than by executing the DB tier; anything touching it should be
re-run where `createdb phoenix_kit_publishing_test` is possible. The
regression test added for finding #1 is deliberately pure-tier so it runs
either way.
