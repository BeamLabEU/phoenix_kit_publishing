# Full module audit — 2026-11-08

A read of the whole module against 0.16.0 (`1a3735a`), in six areas: translations,
UI against core components, the data layer, the public side, the admin LiveViews,
and the machine API with the test suite. Every finding below was checked against the
code before it was fixed; the fixes carry a regression test that fails without them
unless noted. Severities follow `dev_docs/pull_requests/README.md`.

## Baseline

- `mix test` reported **1075 tests, 0 failures (1690 excluded)**: the local test
  database was at core migration V224, below core 3.4's floor (V225), and
  `test_helper.exs` read the failed schema build as "no database" and excluded the
  whole integration tier. Rebuilt, the suite was **2765 tests, 0 failures**.
- `mix precommit` (compile with warnings as errors, unused-lock check, `hex.audit`,
  format, credo strict, dialyzer) was clean.
- `mix hex.outdated`: everything current except Leaf (0.11.1 is out; core 3.4.0 pins
  `~> 0.10.0`, so it cannot move until core does).

## Fixed

### BUG - HIGH

- **Stored XSS through `data-*` attributes.** The sanitiser allowed every `data-*`
  attribute, and phoenix_html.js (loaded by hosts) turns a click inside an element with
  `data-method` + `data-to="javascript:…"` into a script-running form submit; htmx reads
  `data-hx-*`. Only the notes' `data-note` on `a` passes now (`renderer/sanitizer.ex`),
  render cache `v11`.
- **`<EntityForm>` pages were cached with the first visitor's CSRF token**, so every
  other visitor's submit was refused with a 403 and the token was shown to all. A page
  carrying `name="_csrf_token"` is no longer cached (`renderer.ex`).
- **Endless 301 loop on non-ASCII URLs** (hashtag archives like `/blog/tag/äri`, unicode
  slugs): the canonical check compared the percent-encoded request path with the decoded
  canonical path. Both are decoded now (`controller/language.ex`).
- **The API's post-link confirmation rule was bypassed** by `\[\[post:…`, `&#91;&#91;post:…`
  and `&lbrack;` spellings, which render as a live link. TextScan reads the text with
  backslashes dropped and entities decoded; `&sol;` / `&UnderBar;` were added to the
  autolink decoder (`api/text_scan.ex`). A renderer-backed test checks 2,700 spellings.
- **Peer nodes never dropped their cached listing after a post, version or translation
  change** (half of audit 25's H-B): only open admin Listings heard `:cache_changed`. A
  mutation's regeneration now also announces `{:cache_regenerated, slug, node()}` on the
  node-level topic and every other node's `CacheSync` erases its copy; a rebuild a
  mutation asked for that fails erases the old listing everywhere (`listing_cache.ex`,
  `cache_sync.ex`, `pubsub.ex`).
- **The orphan-file check missed most of this module's file references** (`audio_uuid`,
  `og.image_uuid`, `featured_image_id`, body `<Image file_uuid>` and `/file/<uuid>/` URLs),
  so "Delete all orphaned" could take a picture off a live post. `FileReferences` now
  lists the same set `MediaAdoption` files; core's own pairs are kept verbatim
  (`file_references.ex`). The body check plans as an anti-join.
- **A concurrent stale-language heal could delete the row it meant to keep** (the lookup
  found the row itself after a parallel rename). Self-merges are refused and the legacy
  row is deleted only while it still holds the legacy language (`stale_fixer.ex`).
- **A new post with a taken slug left one orphan draft per autosave** (`hello-1`,
  `hello-2`, …): the editor stayed on a "new post" after the first save of its fields
  failed. It adopts the created post now (`web/editor/persistence.ex`).
- **Duplicated PubSub subscriptions after a version switch** double-counted AI
  translation completions, so the translation lock lifted at half the jobs. Subscriptions
  are taken once per form key (`web/editor/collaborative.ex`).
- **A Listing card refreshed after a background save was the live version's map**, so a
  draft-only language's pill opened the published version and its first save put that
  language live. Cards reload through `list_posts/1`, one reload per burst
  (`web/listing.ex`).

### BUG - MEDIUM

- Embargoed (scheduled-ahead) posts were readable through `/v/N` (`post_rendering.ex`).
- `?page[]=1` / `?page[x]=1` crashed every group listing with a 500 (`controller/listing.ex`).
- Query and body params overrode the route bindings (`?language=`, `?path[]=`); the
  comment POST took a map or `//host` as its language and 500'd (`controller.ex`).
- A path segment that is not UTF-8 (`/blog/%FF`) was a 500, not a 404 (`controller.ex`).
- Version URLs of timestamp posts that share a date (`/g/date/time/v/N`) never routed
  (`controller/routing.ex`).
- RSS descriptions turned text that names a tag into markup in feed readers, and one
  control character broke the whole feed (`controller/feed.ex`).
- Component attributes were cut at an apostrophe (`alt="Tallinn's old town"` → `Tallinn`)
  (`renderer.ex`).
- Trashed posts' slugs were handed out again and refused by the unique index; a lost
  slug race was reported as `:db_update_failed` and rolled the content back
  (`slug_helpers.ex`, `db_storage.ex`, `posts.ex`).
- `publish_version/4` wrote the pointer through the pre-lock row, so a concurrent publish
  could leave it on an archived version (`versions.ex`).
- `fix_all_stale_values/0` always raised once a group existed (`Repo.stream` outside a
  transaction); it pages with a keyset now (`stale_fixer.ex`, `db_storage.ex`).
- `add_group/2` turned an unknown mode into a permanent timestamp group; it is
  `:invalid_mode` now (`groups.ex`). **Contract change**, test updated.
- Group slugs `new-group`, `edit-group`, `categories` were shadowed by admin routes; new
  and renamed groups can't take them, an existing group keeps its slug (`groups.ex`).
- Nine error atoms (and `{:has_posts, n}`) rendered as "Unexpected error: :x"; changeset
  messages were English. Messages added, changeset text goes through core's `errors`
  catalogue (`errors.ex`).
- The listing's Draft ↔ Archived always failed with "Not published" (`web/listing.ex`).
- "Post restored as draft" was untrue for a post with a live version, which is public
  again at once; the flash says so and the button confirms (`web/listing.ex`).
- The Settings page flashed success for writes that failed, and "Regenerated N caches"
  for partial failures (`web/settings.ex`).
- A refused group save rebuilt the form from raw params, regressing PR #32's dependent
  fields (`web/edit.ex`).
- Saves on the way to a switch, a preview or an AI enqueue ignored the translation lock
  (`web/editor.ex`, `web/editor/translation.ex`).
- A save in a sibling language replaced this editor's document, dropping what was typed
  inside Leaf's debounce (`web/editor/persistence.ex`).
- The Listing's stale-fixer sweep never ran (its gate compared against the slug `mount`
  had already assigned) (`web/listing.ex`).
- The editor's category picker stored any client-sent uuid; only the group's own
  categories are filed now (`posts.ex`).
- A crafted `delete_group` event could permanently delete an ACTIVE group with all its
  posts; the server requires the trash step now (`web/index.ex`).
- Two tabs deleting the same translation crashed the second LiveView
  (`translation_manager.ex`; no test, the race needs two transactions interleaved).

### Translations

- et/it/ru showed a literal backslash before every quote in 11 strings each; replaced
  with native quotes.
- ru months were nominative ("05 Январь 2026"), it full dates used the abbreviation
  "Mag", et/it months were capitalised; the abbreviations got their own context and the
  day is unpadded (`%-d`).
- Plurals hard-coding "1" were wrong in ru (21 → "1 запись") and fr (0); count messages
  without `ngettext`; "date at time" built by concatenation.
- Permission and notification labels declared no `gettext_backend`, so the Roles page
  and notification settings showed them in English.
- Comment notifications were stored in the commenter's page language; they are written
  in the recipient's.
- The projects-hub Docs tab ignored the session locale (English everywhere, links to
  the default-locale admin) and showed raw ISO dates.
- Hard-coded English: the public "Edit Blog/Post/Categories" labels, editor tooltips,
  component render-failure messages.
- The render-cache TTL text said 6 hours in every language; it is 24.
- Five reviewed `fuzzy` entries cleared; 42 new or reworded strings translated in all
  five languages. A catalogue lint test now fails on a fuzzy entry, an empty msgstr, a
  stray backslash or a placeholder the msgid lacks.

### UI

- `loading-2xs` (not a daisyUI 5 class) made the save spinners full size.
- The OG notice was unreadable in dark themes (`text-info-content` on `bg-info/5`).
- PostShow printed raw ISO timestamps.
- Icon-only buttons on the groups page had no accessible name; their size classes
  cancelled each other on phones.
- The featured-image Change/Remove buttons were invisible to keyboard focus.
- The Listing's title link did a full page reload instead of LiveView navigation.
- The editor's URL preview was hand-built (wrong for dialects, prefixless primary and
  `url_prefix`); it uses the public builder.

### Tests and tooling

- `test_helper.exs` fails the run when the database answers but the schema can't be
  built (it used to exclude the integration tier and go green); dead feature probes and
  their tags removed (every probed API is in the 2.65.0 floor); `mix test.reset` added,
  which core's below-floor error already names.
- Weak tests made strict: draft and trashed post URLs now prove the body is withheld;
  the views test waits for its tasks instead of sleeping 50 ms; two renderer cache tests
  that could not fail were removed (`renderer_cache_test.exs` covers the path).
- New tests: comment POST gates (group flag off, a draft's uuid), `ProjectDocsLive`
  (first tests), and one per fix above.

### Docs

README: install pin, Leaf floor, AI pipeline, cache TTL, component list, module tree,
admin routes, smart-fallback wording, settings keys (`default_language_no_prefix` is
core's), API permissions, dependency table, `mix test.reset`. AGENTS.md: sanitiser
`data-*` rule, PubSub cache topics, `CacheSync`, test harness, `Errors` tuples.

## Open items, second pass

Fixed after the 0.17.0 release, each with a test that fails without it unless noted.

**Data layer**
- `Publishing.list_posts/2` with a language (core's Sitemap) answers a live post's
  `available_languages`, `language_slugs`, `language_previous_slugs` and `url_slug`
  from its LIVE version; without one (the admin) nothing changes.
- The duplicate-published heal keeps the version the post points at, under the locked
  row's pointer.
- `Views.VisitorTable` caps per day (a `{:count, day}` counter) and sweeps just after
  UTC midnight.
- Categories write their audit row and invalidate the listing after COMMIT;
  `replace_post_categories` writes under the post lock on a re-read version; the
  reorder failure row's resource type is `publishing_group` (the AGENTS.md TODO).
- Self-healing writes log `auto` rows: `publishing.content.url_slug_resolved`,
  `publishing.post.pointer_cleared`, `publishing.version.orphan_demoted`,
  `publishing.version.duplicate_archived`.
- The groups dashboard reads aggregates (`group_post_stats/1`) instead of every post
  body of every group.
- A group rename carries `publishing_render_cache_enabled_<slug>` to the new slug.
- Every mutation threads its options into its log calls (none is exempt in
  `activity_attribution_test.exs` now); a refused group name is logged by length, not
  text; a refused group create says why (`:invalid_name`, …) instead of always
  `:already_exists`.
- A title-derived post slug goes through `validate_slug/1` like a preferred one.
- A date-only URL resolves over the times a reader can open (no embargoed post's time
  leaks); the missing-timestamp heal stamps the site clock.
- Dead internal code removed: `DBStorage.delete_post/1`, `list_languages/1`,
  `list_posts_slug_mode/2`, `update_content_status_except/3`, `upsert_group/1`,
  `Categories.categories_for_posts/1`, `categories_of_post/1`,
  `MediaFolders.post_folder_prefix/0`, `Web.Editor.Preview` (and its `preview_token`
  guards), the never-taken save-time version branch, a few unused helpers. Functions on
  the public `Publishing` facade were kept.

**Public**
- An unpublished post's language fallback costs the same however many versions the post
  has (72 → 48 queries for 13 versions in the test, more with languages on).
- The comment form URL is built once per page.
- A marked session dedups by an id in the marker, so a replayed cookie counts once.
- Body search ignores HTML comments.

**Admin**
- Back and a mention click flush Leaf's buffer first (`after_flush/2`).
- An open editor follows a rename of its group (saves keep working, a flash says so); an
  open Listing moves to the new slug.

**UI**
- Status badges are core's `status_badge` (and the listing's version badge uses the
  same colours); public pagination is windowed with previous/next; duplicate headings
  and breadcrumbs removed (Listing, New, PostShow); the version switcher shows the site
  date format and clock; New, Edit and the category dialogs use core's `form_actions`;
  the remaining unnamed controls have names; daisyUI 4 `*-disabled` classes removed;
  radio groups are `fieldset`/`legend`; hand-drawn SVGs are `<.icon>`; PostShow shows
  the real view count instead of a placeholder card.

**Machine API**
- Reasons `primary_language`, `exclusive_fields`, `invalid_datetime` on the three
  reasonless errors; upper-case category ids match; `if_revision` matches a legacy
  base-code primary row.

**Translations**
- es, pl, uk and zh catalogues (core's locales), and a `leaf` domain in all ten
  languages for Leaf's editor strings.

## Still open

- **Per-card image URLs** cost 3–5 queries each on listings: core has no batch URL
  lookup, and the URLs are signed, so it starts in core.
- **Edit's form sections** stay hand-rolled: they are sub-sections inside one form card,
  and core's `form_section` is a top-level shadowed card.
- `ProjectDocsLive` renders without core's components (it is a plain `Phoenix.LiveView`
  for the projects hub); Preview repeats the public post-date and version-dropdown
  markup.
- The editor's published-at field is a UTC instant, previewed on the site clock
  ("Displays as"); that is correct, but an editor reads two clocks.
- Leaf adds "results" after a bare number with no plural handling, so the translation
  reads right only for the many-form (a Leaf change).
- `PubSub.broadcast_post_status_changed/2` has receivers and no sender.
- The view-dedup session marker (up to 50 uuids and an id) has not been measured
  against a host's other session data and the 4 KB cookie limit.
