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

## Open

Not fixed in this pass; listed with where to start.

**Data layer**
- `Publishing.list_posts/2` (core's Sitemap) builds `language_slugs`,
  `available_languages` and `url_slug` from the newest version, so a draft's renamed
  slug is advertised for a live post (`db_storage.ex` `live_effective_opts`). MEDIUM.
- `StaleFixer.archive_extra_published` keeps the highest published version instead of
  the one the pointer names; two reads can unpublish the post. MEDIUM.
- `Views.VisitorTable` sweeps every 24 h from boot and caps across days. MEDIUM.
- Categories write the audit row and broadcast inside their transaction. MEDIUM.
- Self-healing renames (`auto_resolve_url_slug_collision`, StaleFixer pointer clears)
  write no activity row.
- `list_posts_with_metadata` loads every body to count statuses (Index dashboard,
  sitemap); a group rename orphans `publishing_render_cache_enabled_<old-slug>`.
- Several log calls use the 5-argument forms and drop `opts`; `name_attempted` puts raw
  submitted text into activity metadata.
- Dead code: `DBStorage.delete_post/1`, `list_languages/1`, `list_posts_slug_mode/2`,
  `upsert_group/1`, `Groups.list_trashed_groups/0`, the `Metadata` module,
  `PubSub.broadcast_post_status_changed/2` (no sender; receivers exist),
  `Web.Editor.Preview`, `Persistence.create_new_version_from_edit/3`.

**Public**
- One request to an unpublished post costs up to ~5 × (versions + 1) queries in the
  language fallback; per-card image URL lookups and per-call `count_posts_on_date`.
- A replayed session cookie with the dedup marker counts every hit.
- Search runs ILIKE over raw markdown, so stripped HTML comments can be probed.

**Admin**
- A mention link or Back leaves the editor without flushing Leaf's buffer.
- Renaming a group strands open editors and Listings on the old slug.
- The Index dashboard loads every post of every group on each refresh.

**UI** (consistency, no breakage): status badges hand-rolled three ways (core
`status_badge` fits), public pagination unwindowed (core `pagination_controls`),
duplicate headings beside the layout trail, five date formats, hand-rolled form
sections and footers (`form_section` / `form_actions`), labels not tied to controls,
daisyUI 4 `input-disabled` leftovers.

**Machine API** (nits): reasonless validation errors in `set_translation`,
`create_version`, `schedule_post`; upper-case category uuids miss; schema caps differ
from handler caps; `if_revision` on unhealed legacy rows.

**Translations**: core ships es, pl, uk, zh, this module doesn't; Leaf's strings
(tracked in PR 63's follow-up).
