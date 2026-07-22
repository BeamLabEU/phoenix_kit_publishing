# Changelog

## 0.4.3 - 2026-07-22

PR #36 — sixteen-commit boss-directed batch: a public "Latest" post band,
four band styles (`classic`/`cover`/`cover_panel`/`minimal`/`top`) for both
Featured and Latest, hover-lift listing animations, an admin group-page
header/save overhaul, an admin post-status classification fix, a
per-language URL slug fix for listing links, and group-name AI translation.
Two review rounds ran pre-merge (a 4-agent quality sweep, then a 5-AI
adversarial panel); all confirmed findings were fixed and pinned with tests
before merge — see
`dev_docs/pull_requests/2026/36-public-side-batch-and-sweep/FOLLOW_UP.md`
for the full findings/outcomes table. This release re-verified the key
fixes against current code and re-ran the full gate before publishing; no
further changes were needed. Also bumps the `phoenix_kit` dependency pin to
1.7.208.

### Added
- **Latest post band** (`newest_enabled`/`newest_layout` group settings) —
  the chronologically newest post is pulled out of the grid into its own
  "Latest" band under any Featured band; a post that is both featured and
  newest stays in Featured, Latest takes the next-newest. Ties on the same
  effective date break on post UUID for deterministic ordering.
- **Band styles** (`featured_style`/`newest_style`, default `classic`,
  orthogonal to layout): `cover` (featured image as the card background
  under a gradient scrim, branded gradient fallback when no image),
  `cover_panel` (image with an opaque text panel), `minimal` (text-only
  accent-border), `top` (16:9 banner above the text).
- **Listing hover-lift animations** (`listing_animations` group setting,
  default on, motion-safe).
- **Group-name AI translation** — a second AI-translatable adapter
  (`publishing_group`) merges translated names into `data["name_i18n"]`
  under a row lock, with its own `publishing.group.updated` audit trail.
- **Admin group page** — header actions moved into the shared
  `admin_page_header` actions slot with a Settings link to the group
  editor; Save / Save-and-exit split on the group editor.

### Fixed
- **Admin post-status classification** — the admin group page now classifies
  each post by its live (active-version) state, the same rule the public
  listing uses, instead of the latest version's status; a published post
  with a newer draft revision no longer misfiles under Drafts. The visible
  publish date and per-language pills now read the same version-accurate
  data as the status badge.
- **Per-language listing links** — group listing links now use the
  requested language's own custom URL slug instead of the primary
  language's; the language switcher pins the exact-language slug so
  base-code resolution can no longer leak a sibling dialect's slug.
- Public post page: compact name-only back links (`show_top_back_link`,
  top and bottom), an empty toolbar row no longer renders when there are no
  tools, and group-wide `date_counts` now disambiguate timestamp URLs
  correctly on page 2+.

## 0.4.2 - 2026-07-21

PR #34 — public-side listing polish: a "Latest" post band, a top back-link
on post pages, and clickable post-card images, plus a group-wide date-count
fix and card-image a11y guard from the post-merge quorum-review follow-up.
Reviewed post-merge with no further fixes needed — see
`dev_docs/pull_requests/2026/34-newest-band-back-link-image-links/` for the
review.

### Added
- **Latest post band** — new `newest_enabled`/`newest_layout` group settings
  pull the chronologically newest post out of the grid into its own "Latest"
  band under any featured posts (`hero` or `card` layout, same vocabulary as
  `featured_layout`). A post that is both featured and newest stays in the
  Featured band; Latest takes the next-newest.
- **Top back link** — new `show_top_back_link` group setting (default on)
  renders a subtle "Back to <group>" link at the top of post pages, mirroring
  the existing footer button, for readers who land mid-archive.
- **Clickable card images** — new `listing_image_links` group setting
  (default on) makes a post card's image click through to the post, same as
  the title; the image link is `aria-hidden`/`tabindex="-1"` since the title
  link is the accessible route to the same destination.

### Fixed
- Group listing `date_counts` (used to decide whether a post's URL needs a
  time segment to disambiguate same-day posts) are now computed over the
  full group, not just the visible page — a page-2 render could previously
  undercount a date shared with a post pinned into the Featured/Latest band
  or sitting on a different page, producing an ambiguous URL.
- `assign_group_display_config/2` no longer flips a stored `false` back to
  a default-`true` setting (was using `||`, which can't represent an
  explicit `false`); affects `show_top_back_link` and any future
  default-on post-display setting.

## 0.4.1 - 2026-07-20

PR #33 — guard the `phoenix_kit_og` refine seam against crashes and document
Phase 2 (the OG-image plugin extension point), plus a post-merge review fix.
See `dev_docs/pull_requests/2026/33-og-seam-rescue-and-docs/` for the review.

### Fixed
- `maybe_refine_og_with_module/4` now rescues around the optional
  `phoenix_kit_og` plugin's `refine_og/4` call — a raising plugin previously
  crashed every public post-page render; it now falls back to the per-post
  override/default OG map.
- Removed a stale, unused `mix.lock` entry (`beamlab_ex_aws_sqs`, orphaned by
  an earlier rename to `ex_aws_sqs`) that was failing `mix deps.unlock
  --check-unused` in the release gate.

### Added
- Regression test (`test/phoenix_kit_publishing/web/controller/og_refine_crash_test.exs`)
  covering the crash-guard end-to-end, plus a `PhoenixKitOG` test stub.
- `AGENTS.md` now documents the three-layer OG precedence (derived default →
  per-post override → `phoenix_kit_og` plugin) and how `build_og_data/4`
  resolves it.

## 0.4.0 - 2026-07-17

PR #32 — public-side publishing: featured posts, timeline/headings scroll
rails, per-group display settings, and a translatable group name. Written
without access to the quality-sweep playbook or a runnable test environment;
this release also folds in a full post-merge multi-AI quorum review (Codex,
Kimi, Grok, ZAI, Vibe) plus a 4-agent playbook triage pass, with every
confirmed finding fixed before publishing. See
`dev_docs/pull_requests/2026/32-public-side-display-settings/` for the full
review and fix log.

### Added
- **Featured posts** — an editor checkbox flags a post as featured; the
  public listing renders a hero + secondary featured band ahead of the
  regular grid, each card carrying `data-post-date` (mirrors
  `Listing.listing_sort_key/1`) so the timeline rail stays in sync.
- **Per-group display settings** (`GroupSettings`) — post count visibility
  (off by default), timeline/headings scroll rails, scrollbar styling,
  breadcrumbs, sort order, reading time, card width, date position, and a
  reading-progress bar, all configurable per group with governed string-keyed
  persistence.
- **Translatable group name** (`name_i18n`) — an override per language,
  capped at the primary-name length limit, resolved via
  `translated_group_name/2` everywhere the name surfaces: listing
  h1/title/breadcrumb, `og:title`, the post-page breadcrumb and "Back to …"
  footer, and the all-groups overview cards.
- 33 new tests covering every setting's public-render toggle, settings/
  `name_i18n` persistence (including crash-guard, truncation, invalid-enum,
  atom-key round-trip), and the edit/editor LiveView save paths.

### Fixed (post-merge quorum review)
- `GroupSettings.validate_params/1` normalized atom-keyed settings but kept
  the atom key, so `update_group/3` (string-keyed) silently persisted
  nothing on the documented AI/script path — settings now normalize to their
  canonical string key.
- `merge_name_i18n/2` called `to_string/1` on override values — a nested map
  (crafted params or a programmatic caller) raised `Protocol.UndefinedError`
  and crashed the edit LiveView; non-binary overrides are now dropped
  instead of raising.
- Grid cards preferred `metadata.published_at` over the effective post date
  used for sorting, so the timeline rail could disagree with the visible
  order — both now read a shared `effective_post_date/1` helper.
- The editor's hidden `featured=false` input stayed enabled while its
  checkbox was disabled, so a still-enabled sibling control could clobber
  the flag — now disabled in lockstep (defense-in-depth; pinned by test).
- `name_i18n` overrides bypassed the 255-char primary-name limit.
- `reading_time_label/1` used `gettext` with `%{count}`, which isn't
  pluralizable — switched to `ngettext`.
- Timeline-rail month labels and both rails' aria-labels were hardcoded
  English inside static JS on otherwise fully-localized public pages — now
  localized via `data-months`/`data-label` on the config elements.
- `assign_scroll_config/2` (renamed `assign_group_display_config/2`)
  re-fetched the group a second time per request and redeclared setting
  defaults as literals instead of reading `Constants`.
- Spec-parity and `default_config/0` tests compared against a hardcoded key
  list instead of the real write path (`Groups.config_setting_keys/0`),
  which had gone drift-blind and was missing `show_post_count`.
- Featured vs. grid card markup was near-duplicated in `html.ex` — unified
  into one `listing_post_card/1` component.
- `Groups.update_group/3` and the edit LiveView both broadcast
  `{:group_updated, …}` on save — the LiveView's duplicate removed.
- `translated_group_name/2` was missing a `@spec`.
- 57 admin/public strings per locale were never extracted (written on a
  server without a gettext-capable environment) — all five catalogs
  re-extracted, merged, and translated (en identity, et/fr/it/ru filled).

## 0.3.0 - 2026-07-04

Publishing's admin/editor UI strings now translate — previously every
`gettext()` call here routed through core's `PhoenixKitWeb.Gettext`, but
`mix gettext.extract` only walks a project's own `lib/`, so none of this
module's ~390 strings were ever extracted into any catalog, in any locale.
The whole admin UI silently rendered in English regardless of locale. Also
picks up the `phoenix_kit_og` `PhoenixKitOg` → `PhoenixKitOG` rename.

### Added
- **Own `PhoenixKitPublishing.Gettext` backend** (`priv/gettext/`), following
  the per-module i18n pattern `phoenix_kit_ecommerce` already uses. All 456
  msgids extracted and translated into English, Russian, Italian, French,
  and Estonian, plurals included with correct per-locale plural-category
  counts (Russian's 3 forms vs. everyone else's 2). Sidebar tab labels
  (`admin_tabs/0`, `settings_tabs/0`) now carry `gettext_backend:`; the
  public-content locale setter syncs both this module's backend and core's,
  so post pages translate too, not just the admin panel.

### Fixed
- Updated the guarded `phoenix_kit_og` integration seam
  (`controller.ex`/`editor.ex`/`.dialyzer_ignore.exs`) for the sibling
  plugin's `PhoenixKitOg` → `PhoenixKitOG` module rename.

## 0.2.3 - 2026-07-03

PRs #27–#29 — a `phoenix_kit_og` integration seam (per-post OG-image template
wiring, editor OG-override panel), a lower SEO-friendly auto-slug cap, a
missing `:url_path` assign that broke canonical URLs on public controller
pages, and route-prefix collisions with other modules' reserved routes. Plus
a post-merge review pass. Built against `phoenix_kit ~> 1.7.170`.

### Added
- **`phoenix_kit_og` template-wiring seam** — `Publishing.og_variables/0` +
  `og_resolve/2` expose post title/description/URL/featured image/group
  name/group slug/first-words/published-date for a future OG-image plugin
  to bind to template slots. A per-language OG override
  (title/description/image) is editable from the editor's new "Social /
  OpenGraph" panel and layered into the existing `og:*` meta tags
  (module override → per-post override → derived default). No-op until
  `phoenix_kit_og` is installed.
- `og:image:width` / `og:image:height` / `og:image:type` meta tags when the
  featured (or overridden) image's dimensions are available.

### Changed
- **Auto-generated slug cap lowered 200 → 60 chars** (SEO guidance —
  Ahrefs/Moz/Yoast/Semrush converge on 50–75). Applies only to slugs derived
  from titles / AI translation / transliteration; a human-typed slug is
  still bounded by the 500-char save limit.

### Fixed
- **Public controller pages now assign `:url_path`** so host root layouts
  building canonical/`og:url`/hreflang tags from it don't fall back to `"/"`
  on every publishing-served page (this dropped `/legal/*`-style pages from
  Google's index as canonical duplicates on at least one production site).
- **A group slug that collides with another module's reserved top-level
  route is no longer claimed by the group-dispatch catch-all**, even when a
  same-named group genuinely exists in publishing's own data — closes a hole
  where e.g. a `phoenix_kit_legal`-reserved `"legal"` path could be hijacked
  by publishing's generic post view instead of the owning module's page.
- **Three `og_resolve/2` variables that were silently dead** (`post_url`,
  `post_group_name`, `post_group_slug` always resolved to `nil` — the
  metadata keys they read don't exist on the post map) — found and fixed in
  post-merge review, before anything depended on them.
- `credo --strict` violation in the new OG-image-metadata code
  (unaliased nested module reference).
- `mix dialyzer` was failing outright on this branch (the optional
  `PhoenixKitOg` calls plus two dead-code branches in the new OG-image
  logic). Added `.dialyzer_ignore.exs` for the optional-module warnings
  (matching the pattern already used by sibling `phoenix_kit_*` repos) and
  removed the unreachable branches.

## 0.2.2 - 2026-06-19

Migrates markdown rendering from **Earmark → MDEx (comrak)**. Earmark is retired/unmaintained on Hex, so `mix hex.audit` (part of `precommit`) now reports **no retired packages**. MDEx is already pulled in by `phoenix_kit` core, so this adds no new native footprint. No public API change — `Renderer.render_markdown/1` keeps the same contract; rendered HTML is equivalent (the markdown→HTML output differs only cosmetically: whitespace, `<img />` self-closing, entity normalization).

### Changed
- **`Renderer` now renders markdown with MDEx** (`render: [unsafe: true]`, smart punctuation, GFM tables/strikethrough/autolinks/task lists). The GFM `tagfilter` extension is intentionally left off to preserve the documented admin trust boundary (a pasted `<script>` still renders live).
- **Code-fence handling is simpler and safer.** comrak always HTML-escapes fenced/inline code content, so the plain path no longer pre-escapes; a raw `<script>` inside a ```fence``` still renders as literal text. The mixed (component) path masks only the `<` of components shown literally inside code so the component scanner skips them, then restores it before MDEx (which escapes it) — replacing the old entity pre-escaping that MDEx would double-escape.
- **Render cache version bumped `v4 → v5`** so Earmark-rendered entries are dropped and re-rendered with MDEx instead of served stale.
- Dependency: dropped `{:earmark, "~> 1.4"}`, added `{:mdex, "~> 0.13"}`.

### Fixed
- Test harness no longer crashes when `psql` is absent — it now degrades to "integration tests excluded" so the Level 1 (pure) suite still runs.

## 0.2.1 - 2026-06-18

PR #26 — rewires the post editor onto the core `MarkdownEditor` hook so it renders **zero inline `<script>` and zero `onclick`** (CSP-safe and navigation-safe), plus a post-merge review pass. No public API breaks. Built against `phoenix_kit ~> 1.7.162` / `phoenix_kit_ai ~> 0.9` (existing constraints unchanged; the editor-hook and smart-default behaviors light up on those releases and degrade gracefully on older ones).

### Changed
- **Editor media insertion flows through the core `MarkdownEditor`** — images via `:insert_at_cursor` and video via the `:prompt_insert` action — so insertion no longer needs a module-owned inline `<script>` and survives LiveView navigation (image insert previously required a manual page refresh).
- **Unsaved-changes confirmation is a server-rendered modal** instead of a JS `confirm()` (which broke under CSP / on navigation).
- **The AI-translation modal pre-selects the endpoint** from core's smart default (last-used from history, else a non-reasoning chat endpoint) and **auto-closes on a successful translation**, so you no longer re-pick the endpoint or close the modal by hand.
- The auto-generated slug renders straight from the form assign, dropping the dead `update-slug` push and `Forms.push_slug_events/2`.

### Fixed
- **Video toolbar inserts the renderer-supported `<Video url="…">` component** instead of `![Video](url)` markdown, which the renderer turned into a broken `<img>`. Now matches the image-insert path and the `insert_component`/`insert_video_component` handlers.
- Reformatted `editor_forms_test.exs` (stray trailing blank line left by the `push_slug_events/2` test removal).

## 0.2.0 - 2026-06-11

PR #25 — a full-module adversarial audit: **9 High / 16 Medium / 12 Low** findings fixed across public routing, the listing cache, publishing atomicity, the editor, and markdown rendering, each pinned by a regression test. Plus a post-audit fix to listing-cache invalidation. No public API breaks; the minor bump reflects the breadth of behavioral hardening (redirects, slug-collision precedence, cache/clustering semantics). Built against `phoenix_kit ~> 1.7.144`.

### Fixed

**High**
- **301 redirects from renamed posts now fire** — `previous_url_slugs` are actually persisted, so an old URL redirects to the current one instead of 404ing.
- **Router host-route hijack closed** — segment-0 is only treated as a locale when it's an enabled/resolvable language, and a `GET`/`HEAD` method gate stops the publishing router from shadowing a host app's `POST`/form/webhook routes on the same path.
- **Two infinite-redirect loops closed** (canonical-language ping-pong and a future-dated-timestamp fallback loop).
- **Render cache is supervised** — started in the supervision tree instead of being born in a transient request process.
- **Spectator/read-only write guards** on every mutating editor event; editor reloads are pinned to the version being edited.
- **Public version dropdown restored.**

**Medium**
- **Publishing is atomic** and `StaleFixer` heals orphaned published versions — closes the "admin shows published / public 404s" split.
- **Transactional post updates and blank-version creation** (content-wipe + version promotion can no longer half-apply).
- **Timestamp-collision retry** matches by constraint name (won't swallow a slug-uniqueness violation); **trashed timestamp slots** are counted for availability so the retry converges.
- **Cross-group UUID access rejected** — a post UUID from another group returns not-found.
- **Clustering**: cross-node cache invalidation and remote-pid-safe presence checks.
- **Supervised lock table** + crash-proof regeneration guard (a vanished ETS table can't 500 a read).
- **Empty / featured-image-only posts are trashed, not hard-deleted**, with ActivityLog entries.
- **Markdown safety**: code-region integrity, multi-line `<Image>` detection, and consistent HTML escaping across paths.
- **url_slug collisions**: the incumbent post wins and the loser is auto-renamed; claiming another post's previous slug is blocked; the editor shows an explain-and-link conflict modal instead of silently clearing.
- **Admin-insight cache consistency** and **stale translation-lock** clearing.

**Low**
- `switch_version` crash on a junk param; preview save-failure handling; unpublish pre-lock re-read; transactional blank version; timestamp posts stamped in the **site time zone**; group-rename cache invalidation; whole-cache erase on memory-cache disable; double-backtick code spans masked; unresolved `{{placeholder}}` preserved; token-scoped lock release; narrowed update-error rescue; folded the listing-cache timestamps into one term to cut `:persistent_term` churn; title `phx-debounce`; canonical/302 redirects preserve the query string; reserved route words rejected as post/group slugs.

**Post-audit (listing-cache invalidation storm)**
- The `:cache_changed` LiveView handler no longer calls `regenerate/1`, which re-broadcast `:cache_changed` and — because the view subscribes to its own group's cache topic — looped into a self-sustaining, cluster-wide regeneration storm. The handler now **invalidates** the node-local term; the next public read rebuilds it fresh and **silently**. Mutation sites are the only `:cache_changed` announcers; read-miss repopulation is silent. This also removes a stale-hit window and a redundant per-event DB read, and erases stale terms on every node regardless of whether an admin view is mounted.

### Removed
- Dead per-post SEO/OpenGraph override scaffolding, and the `<Hero>` / `<Page>` components (resolved to core modules that were deleted with the Pages module).

### Changed
- Built against `phoenix_kit ~> 1.7.144` (`leaf` 0.2.23 transitively); the declared floor stays `~> 1.7.132`.
- `humanize_field/1` keeps acronyms uppercased ("URL slug", "SEO title"); the slug-truncation warning persists while the title stays over the URL cap.

## 0.1.16 - 2026-06-10

PR #24 — editor & public-rendering sweep: stable inline images, legacy image-URL healing at render, automatic in-page OpenGraph, descriptive error flashes, and slug-cap safety. Plus a post-merge crash fix. Built against `phoenix_kit ~> 1.7.138` and `phoenix_live_view 1.2`.

### Added
- **Automatic in-page OpenGraph + Twitter Card tags** on public listing + post pages (`publishing_render_og_tags`, default on) so social previews work with zero host `<head>` setup; a Settings toggle disables the in-page copy when the host renders the forwarded `:og` assign itself. The `:og` builder is hardened — relative SEO images normalize to absolute (no more `https://hostimages/...`), and `og:locale` is emitted in OpenGraph's `language_TERRITORY` form.
- **Auto-slug truncation warning** — a non-blocking flash when an automatic slug is shortened to fit the cap (e.g. a long Cyrillic title that transliteration expands, `щ → shch`), transition-gated so live typing past the cap doesn't spam it.

### Changed
- **Inline post images insert as `<Image file_uuid="…"/>` components**, not a frozen signed URL — resolved to a URL at render time, so they survive `url_prefix` changes and `secret_key_base` rotation (the same late resolution the featured image already used). Alt text derives from the file's original name. Drops the client-side `eval()` used for image insertion in favour of a typed `phx:insert-media` event.
- **Editor & admin error flashes are descriptive** — generic catch-alls now route through `Publishing.Errors` (e.g. "Couldn't save this post. Database update failed.") instead of flat "Failed to …" strings, including an `%Ecto.Changeset{}` clause that renders a humanized, capped field summary.
- **The auto-generated slug cap is derived from the save limit** — `min(SEO 200, Constants.max_slug_length)`, so a generated slug provably can't exceed what save accepts.
- Bumped dependencies: `phoenix_kit` 1.7.138, `phoenix_live_view` 1.2, `phoenix_kit_ai` 0.8, `phoenix` 1.8.8, `leaf` 0.2.23. Added `hex.audit` to `mix precommit`.

### Fixed
- **Legacy signed-file image URLs heal at render time** — posts authored before the `<Image>` change stored a fully-resolved `/<old-prefix>/file/…` URL that 404s after a prefix change or secret rotation. The renderer recovers the UUID + variant and re-signs against the current prefix/secret — no data migration, idempotent for current output, external/protocol-relative URLs untouched. The render cache key is now prefix- and secret-aware (bumped to `v3`).
- **`Errors.message/1` no longer crashes the flash** on a changeset whose error opt carries a list value (e.g. an inclusion/subset `enum`): `to_string/1` raises `ArgumentError` there, which is now caught alongside the existing tuple/`Protocol.UndefinedError` case.

## 0.1.15 - 2026-06-08

PR #23 — AI translation moves onto the shared `phoenix_kit_ai` pipeline, version-scoped translation, and editor fixes. Requires `phoenix_kit_ai ~> 0.4`.

### Changed
- **AI translation now runs on the `phoenix_kit_ai` plugin** (bumped to `~> 0.4`). The adapter, translation manager, and editor translation flow are rewired from core's `PhoenixKit.Modules.AI.*` to `PhoenixKitAI.*`. The adapter is duck-typed via `ai_translatables/0` and discovered by `PhoenixKitAI.Translatables`.
- **Translation targets the version the editor is on** (e.g. a draft), not always the active one — `resource_scope` threads through dedup, broadcasts, and `fetch/3` (F1). Default endpoint/prompt resolution is unified (F3), with a regenerate affordance for stale default prompts (F2).
- Standardized on the lowercase `"title"`/`"content"` field convention (matching catalogue/projects).

### Added
- Env-gated `pk_dep/3` path override in `mix.exs`: build/test against a local `phoenix_kit*` checkout via `<APP>_PATH` (e.g. `PHOENIX_KIT_PATH=../phoenix_kit mix test`). Unset = the published pin, so `mix deps.get` / `mix hex.publish` / CI resolve exactly as before.

### Fixed
- **Field-case regression**: capitalized `{{Title}}` placeholders rendered literally and the model hallucinated; now resolved by the lowercase field convention.
- **Duplicate-slug error** names the offending slug and notes uniqueness is within the group, across the create / in-place-update / version paths.
- **AI-translation source warning** distinguishes *nothing* / *only-title* / *only-content* instead of a blanket "source content is empty".
- **Translation modal** gained a reasoning-model hint under the endpoint selector and a clearer "runs in the background, you can keep editing or leave" line (parity with catalogue/projects).

## 0.1.14 - 2026-06-07

PR #21 + PR #22 — editor UX, configurable slug style, and parallel AI translation (one Oban job per language via the shared translation pipeline), plus a post-merge review sweep. Requires `phoenix_kit ~> 1.7.132`.

### Added
- **Configurable slug style** (`publishing_slug_style` setting + Settings dropdown). One style-aware `SlugHelpers.slugify/2` that every slug engine routes through: `transliterate` (default — Cyrillic → Latin, `Привет мир` → `privet-mir`), `unicode` (keep letters/numbers from any script, `привет-мир`), and `ascii` (legacy strip). Non-Latin titles no longer collapse to "untitled". Slugs are capped at 200 chars on a hyphen boundary.
- **`PhoenixKitPublishing.AITranslatable`** — adapter onto PhoenixKitAI's generic AI-translation pipeline (`PhoenixKitAI.{Translations,TranslateWorker}`), registered via `ai_translatables/0`. The per-language `url_slug` is generated locally from the translated title (honoring the slug style, never trusting an AI-returned slug) with a group+language uniqueness guard that omits the slug on conflict.
- Editor UX: full-width layout matching the catalogue, aligned header rows, the public URL shown under the action buttons on published posts, and the re-enabled per-language URL Slug field with live preview.

### Changed
- **AI translation now runs one Oban job per target language** (`PhoenixKitAI.Translations.enqueue_all_missing/2`) instead of translating every language sequentially in a single job — wall-clock drops from the sum of all languages to roughly the slowest one. The programmatic `translate_post_to_all_languages/3` routes through the same pipeline.
- `ai_translation_available?/0`, `list_ai_endpoints/0`, and `list_ai_prompts/0` delegate to `PhoenixKitAI.Translations` instead of re-deriving the `{uuid, name}` shape a third time (PR #21). Publishing keeps its own default endpoint/prompt resolution and its `translate-publishing-posts` prompt.
- The `url_slug` uniqueness check now excludes the current post **in SQL**.
- Added/updated the `phoenix_kit_ai` dependency for the generic AI-translation pipeline this module plugs into.

### Fixed
- **Translation source is always the primary language**, never the language the editor happens to be viewing — "translate this language" on a non-primary page no longer enqueues a language into itself, and "translate all/missing" no longer sources from a translation. Covers the `source_content_blank?/1` blank-source confirmation warning.
- **Read/write version pinning** in the translation adapter — a published-v1 + draft-v2 post no longer reads one version and writes the new language row onto another.
- The `url_slug` input gained `maxlength="200"` and a style-aware HTML5 `pattern`, so a valid Unicode slug isn't rejected client-side under the `unicode` style.
- The in-flight translation query references the core worker module instead of a hardcoded string, and a dead `|| %{}` guard on the always-a-map `post.metadata` was removed (Dialyzer).

### Removed
- The legacy `Workers.TranslatePostWorker` and its tests — superseded by the `AITranslatable` adapter + PhoenixKitAI pipeline (net −1.3k LOC).

## 0.1.13 - 2026-05-22

PR #20 — restore a defensive non-binary fallback in `TranslatePostWorker.parse_translated_response/1`, plus a follow-up that tightens the log-safe type descriptor.

### Fixed
- `TranslatePostWorker.parse_translated_response/1` no longer raises `FunctionClauseError` on non-binary input. After PR #19 delegated parsing to core's `Translation.parse_response/2` (guarded by `is_binary/1`), the `def`-public function could crash when handed `nil` / atom / number / map by a test or external caller — and `AI.extract_content/1` can itself surface `{:ok, nil}` when a provider returns a null `content`. A guarded `when is_binary(response)` clause now owns the parse path; a catch-all clause fails closed with the empty-tuple shape `{"", nil, ""}` and emits a `Logger.warning` so a production occurrence (which would persist a blank translation row) is operator-visible.
- The `describe_type/1` log helper reports only a value's type/shape — never its contents — to avoid leaking PII / API keys from pathological inputs, and uses a `proper_list?/1` guard so it doesn't itself crash on improper lists (`length/1` raises `ArgumentError` on `[:a | :b]`).

### Changed
- `describe_type/1` now uses a literal `nil` head instead of an `is_nil/1` guard, and gained an `is_bitstring/1` clause so a non-byte-aligned bitstring (e.g. `<<1::3>>`, which is not an `is_binary/1` match) logs as `bitstring` rather than `unknown`.
- Locked transitive dependencies: `etcher 0.4.8`, `fresco 0.5.5`, `ex_doc 0.40.3`.

## 0.1.12 - 2026-05-21

PR #19 — unify the translation-response parser with core (paired with `phoenix_kit 1.7.117`).

### Changed
- `TranslatePostWorker.parse_translated_response/1` now delegates to the shared `Translation.parse_response/2` helper (the canonical `---FIELD---` parser shared with `phoenix_kit_projects`) instead of a hand-rolled chained-regex matcher. It tries `["title", "slug", "content"]` first, retries with `["title", "content"]` on missing fields, and falls back to the publishing-specific `parse_markdown_response/1` salvage when no markers are present. The AI call sites, `extract_content/1`, and `sanitize_slug/1` are untouched.
- Bumped the `phoenix_kit` dependency floor to `~> 1.7.117`, which is where the shared translation parser became available; the lock also picks up `etcher 0.4.6`, `fresco 0.5.4`, and `req 0.5.18`.

### Fixed
- Translation responses with `---FIELD---` markers in any order, or with lower/mixed-case marker names, now parse correctly instead of falling through to the bare-markdown salvage path. Covered by new regression tests for marker order-independence, case-insensitive markers, and the TITLE-only fallback.

## 0.1.11 - 2026-05-19

PR #18 — delegate the `default_language_no_prefix` toggle to the site-wide core setting (paired with `phoenix_kit 1.7.115`).

### Changed
- `LanguageHelpers.default_language_no_prefix?/0` now delegates to `PhoenixKit.Modules.Languages.default_language_no_prefix?/0` instead of reading the legacy `publishing_default_language_no_prefix` setting key directly. All consumers (the six `Web.HTML` URL builders, the canonical-redirect controller, and the `Publishing.default_language_no_prefix?/0` / `use_language_prefix?/1` facade) keep the same signature and behavior.
- `/admin/settings/publishing` — the "Default Language Without Prefix" toggle is replaced with a read-only status row and a "Manage" link to `/admin/settings/languages`, which now owns the setting. Removes the dual-write risk where the publishing-side write could desync from the core-side read mid-deploy.
- Bumped `phoenix_kit` to `1.7.115`, which ships `Modules.Languages.default_language_no_prefix?/0` and the `Languages.migrate_legacy/0` backfill (run by `ModuleRegistry` at boot) that copies the legacy `publishing_default_language_no_prefix` value into the new core key, so existing sites keep their explicit choice without admin action.

### Removed
- `@default_language_no_prefix_key` constant and the `toggle_default_language_no_prefix` LiveView event on `Web.Settings` — the setting is no longer publishing-owned.

## 0.1.10 - 2026-05-19

Maintenance release — LiveView callback annotations and dependency bumps.

### Changed
- Added `@impl true` annotations to the `Web.Settings` LiveView callbacks (`mount/3`, `handle_params/3`, `terminate/2`, `handle_event/3`, `handle_info/2`, `render/1`) so the compiler verifies them against the `Phoenix.LiveView` behaviour.
- Bumped dependencies: `ecto` `3.13.6` → `3.14.0`, `ecto_sql` `3.13.5` → `3.14.0`, `fresco` `0.5.0` → `0.5.2`.

## 0.1.9 - 2026-05-19

PR #16 — Phase 2 quality sweep (URL-slug correctness, DoS guards, race fixes, archive semantics, host boundaries) + post-merge review fixes + the `phoenix_kit 1.7.114` upgrade.

### Fixed
- **`Ecto.MultipleResultsError` on URL-slug post lookups.** Posts that accumulated several versions sharing identical content fields crashed `repo().one()`. URL-slug resolution is now scoped to the post's active version (public path) with a deterministic tie-break.
- **Two DoS vectors closed.** (1) The PHK page-builder XML parser used `String.to_atom/1` on admin-supplied tag names — arbitrary tags could exhaust the finite BEAM atom table and crash the VM. It now uses `String.to_existing_atom/1`, routing unknown tags to `:unknown`. (2) `ListingCache` minted a never-GC'd `:persistent_term` entry for every unknown URL segment treated as a group slug; it now verifies the group exists before writing (each write also triggers a global GC pass — a flood of bad requests was a DoS on top of the leak).
- **Language-switch redirect loop on a trailing `?`.** `build_public_path/2` encoded an empty query map to `"foo?"`, which never equals the canonical `"foo"`, so the 301 looped to itself. Empty params now produce no `?`.
- **Public URLs broke under a non-root workspace prefix.** `RouterDispatch` gained `maybe_rewrite/2`, which strips/re-prepends the host's `url_prefix` so dispatch works when PhoenixKit is mounted under e.g. `/phoenix_kit`.
- **Publish/unpublish races.** Both `do_publish_version/4` and `do_unpublish_post/3` now take a `SELECT … FOR UPDATE` lock on the post row (shared `lock_post!/2` helper) so concurrent publishes/unpublishes can't interleave into a stale `active_version_uuid`. Timestamp-mode `create_post` retries the whole transaction on a `(group_uuid, post_date, post_time)` unique-constraint violation instead of failing.
- **`find_by_previous_url_slug/3` surfaced unpublished posts** — a public 301 redirect could resolve onto a never-published post that then 404s. Now scoped to the active version only.
- **`clear_translation` editor event was unguarded** — a spectator/locked-out viewer could hard-delete a translation row by sending the event directly over the socket. Now gated like every other destructive editor event.

### Added
- **`find_by_url_slug_any_version/3`** (`Posts` / `DBStorage`) — internal lookup that surfaces unpublished drafts, for the stale-language self-healing flow and slug-uniqueness checks. The public `find_by_url_slug/3` stays published-only.
- **`unpublish_post` `:target_status` option** — the "Archived" UI action now persists `status: "archived"` on the version row instead of silently reverting to `"draft"`.
- `terminate/2` on the `Index`, `PostShow`, and `Settings` LiveViews for subscribe/unsubscribe symmetry.
- i18n sweep — previously-hardcoded UI strings on the public listing/post pages and editor now flow through `gettext`/`ngettext`.

### Changed
- **URL-slug lookup split** into a public, published-only path and an internal any-version path; collisions on the public path self-heal by auto-suffixing the loser's `url_slug`.
- **base→dialect resolution consolidated** — three near-identical helpers in `Posts`, `Web.Controller.Language`, and `StaleFixer` collapse into `LanguageHelpers.resolve_dialect_for_base/3` with explicit `:prefer` / `:exclude` options.
- The admin "Edit Post" link now carries the current public-side language via `?lang=` so the editor opens in the language the reader was viewing.
- Narrowed `rescue` clauses in `Publishing.dashboard_tabs`, `load_publishing_groups_for_tabs`, and `Web.Preview` to catch only expected DB/render exceptions — genuine programmer errors bubble up again instead of being masked.
- `clear_translation/4` writes an `ActivityLog` audit entry, matching `delete_language`.
- Bumped `phoenix_kit` to `~> 1.7.114`, which adds the generic `:module_assigns` attr on `LayoutWrapper.app_layout/1`; `Web.HTML` forwards `phoenix_kit_publishing_translations` and `og` to the host layout through it.
- `create_post_with_timestamp_retry` takes a single context map instead of nine positional arguments.

### Docs
- `dev_docs/pull_requests/2026/16-phase-2-quality-sweep/` — `CLAUDE_REVIEW.md` (post-merge review) and `FOLLOW_UP.md` (findings triage + `mix precommit` restoration after the upgrade).

## 0.1.8 - 2026-05-09

PR #15 — host-integration hooks for the language switcher + post-merge boundary normalisation.

### Added
- **`:phoenix_kit_publishing_translations` conn assign** — the public API contract for host-app switchers. Set on listing and post responses (regardless of the in-page-switcher toggle) as a list of maps with exactly five fields: `%{code, name, flag, url, current}`. Lets host root layouts and custom switchers render publishing's per-translation URLs directly — important for groups with per-language URL slugs where a generic locale-rewrite produces wrong hrefs.
- **`publishing_show_language_switcher` setting** (default `true`) — gates the in-page switcher on listing + post pages. Hosts that already render a switcher in their header flip it to `false` in `/admin/settings/publishing` to suppress duplicate UI. Per-translation URLs stay exposed regardless.
- Settings UI gains an "In-Page Language Switcher" toggle mirroring the existing `publishing_default_language_no_prefix` shape.

### Changed
- `Web.Controller.assign_publishing_translations/2` normalises the public assign at the boundary, stripping internal-only fields (`display_code`, and on post routes `enabled`/`known`) so external consumers get a uniform 5-field shape on both listing and post routes. Internal `:translations` assign is unchanged.
- `Web.HTML` listing and post templates gate the in-page switcher on `assigns[:show_language_switcher] != false` — defaults to rendering when the assign is absent, preserving historical behaviour for hosts that haven't threaded the assign through.
- Bumped transitive deps in `mix.lock`: db_connection 2.10.0 → 2.10.1, decimal 2.3.0 → 3.1.0, ex_doc 0.40.1 → 0.40.2, leaf 0.2.12 → 0.2.13, makeup_erlang 1.0.3 → 1.1.0, mint 1.7.1 → 1.8.0.

### Docs
- AGENTS.md gains a "Language switcher integration" section documenting the three integration points (the toggle, the conn assign, and core's matching `<.language_switcher_dropdown>` `:per_translation_urls` attr) + a row in the Settings Keys table.
- `dev_docs/pull_requests/2026/15-language-switcher-host-integration/CLAUDE_REVIEW.md` — post-merge review.

## 0.1.7 - 2026-05-05

PR #13 — fix issue #11 (editor opens blank for `?lang=<base>` when only a non-default dialect is enabled) + PR-12 close-out + precommit nits.

### Fixed
- **Editor opened blank when `?lang=<base>` mapped to a non-default dialect (Issue #11).** Two-layer bug: `Posts.resolve_language_to_dialect/1` mapped `"en"` to the hard-coded `DialectMapper` default (`"en-US"`) instead of an enabled dialect like `"en-GB"`, and `Editor.handle_uuid_post_params/3` then ran a raw `language not in post.available_languages` check which routed `"en"` against `["en-GB", "ru"]` into `handle_new_translation_params/6` (empties the form). Fix at both layers — neither alone is sufficient.
- `post_rendering_helpers_test.exs:74` — stale `build_breadcrumbs/3` call site missed by the `7f547b5` (PR #12 cleanup) arity bump to `/4`. Now passes the `group_name` arg explicitly and asserts on the resulting label.

### Changed
- `Posts.resolve_language_to_dialect/1` — prefers an enabled dialect for the given base before falling back to `DialectMapper.base_to_dialect/1`. When several dialects share the base, prefers `LanguageHelpers.get_primary_language/0`, otherwise the first enabled dialect in declaration order. New private helper `enabled_dialect_for_base/2`.
- `Editor.handle_uuid_post_params/3` and `Editor.handle_path_post_params/3` — route through new `new_translation_request?/2` helper that resolves the requested language against `post.available_languages` via `Web.Controller.Language.resolve_language_for_post/2` before deciding new-vs-existing translation.
- `test_helper.exs` — swapped `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, ...)` for `PhoenixKit.Migration.ensure_current(TestRepo, log: false)` (core 1.7.105+ / phoenix_kit#515). The version-`0` pattern silently stopped re-applying once `0` was recorded in `schema_migrations`; `ensure_current/2` re-applies via fresh wall-clock versions on every boot.
- `StaleFixerTest` switched from `async: true` → `async: false`. Every test in the file mutates the shared `content_language` setting (ETS-cached singleton); two parallel runs in the same VM clobbered each other and produced a 1-in-15 flake on `:96 url slug lookup repairs legacy base-language slugs`.
- Bumped to `phoenix_kit ~> 1.7.105` (required by `Migration.ensure_current/2`) and `phoenix_kit_ai ~> 0.2.0`. The latter tightened return types of `AI.list_endpoints/1` and `AI.list_prompts/1`; `Editor.Translation.list_ai_endpoints/0` and `list_ai_prompts/0` dropped now-dead `_ -> []` fallbacks.

### Docs
- AGENTS.md gains a "Base→enabled-dialect resolution" Critical Conventions bullet documenting the resolver behavior, the editor-side contract, and the issue #11 reference.
- `dev_docs/pull_requests/2026/12-smart-fallback-fix/FOLLOW_UP.md` records resolution of the four `CLAUDE_REVIEW.md` findings from PR #12 (3 fixed in `7f547b5`, 1 here) and closes the folder.
- `dev_docs/pull_requests/2026/13-issue-11-resolver/CLAUDE_REVIEW.md` — post-merge review.

## 0.1.6 - 2026-05-02

PR #12 — fix smart-fallback URL hijack + drop hand-rolled migrations + Phase 2 cleanup.

### Fixed
- **Smart-fallback URL hijacking** — when `url_prefix` is `""`/`"/"`, publishing's catch-all sits at the host's absolute root. Unknown first segments now 404 instead of silently redirecting to the first group in the DB (which hijacked host-app paths like `/about`, `/contact`).
- `conn.params` rewrite after `Language.detect_*` reinterpretation — downstream code (including the fallback) now sees corrected `group`/`path` instead of the raw (wrong) bindings from the localized route.

### Removed
- `PhoenixKit.Modules.Publishing.Migrations.PublishingTables` — 311-line consolidated migration was dead code; every consumer pulls in `phoenix_kit` core whose V59 creates the same tables. Use `mix phoenix_kit.install` (has been the correct path since extraction).
- `constraints: %{...}` maps on public routes — Phoenix.Router has no per-segment regex constraint mechanism; these were always no-ops. Route declaration order + controller-layer disambiguation are the actual mechanisms.
- `created_by_email`/`updated_by_email` from `Shared.audit_metadata/2` — the publishing schema has no email columns; these keys were silently stripped by mass-assignment guard (dead plumbing from core's pre-extraction blogging module).

### Changed
- Test suite uses `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, ...)` instead of 178 lines of inline DDL — test/prod schema drift is now impossible by construction.
- `Listing.default_group_listing/1` removed — no longer a meaningful concept after the fallback-policy fix.
- `build_breadcrumbs/3` → `/4` — accepts `group_name` directly, eliminating a redundant group lookup per public page render. `render_published_post` and `build_versioned_post_response` now include `group_name` in their assigns maps; the controller consumes it instead of calling `Publishing.group_name/1` separately.
- `String.capitalize(@group_slug)` in `html.ex` and `preview.ex` replaced with `@group_name` assign — slugs like `"date12"` no longer render as `"Date12"` in the "Back to" link.

### Docs
- AGENTS.md and README.md updated: removed `migrations/` from lib-tree, documented smart-fallback semantics, noted that `constraints:` on public routes is a no-op.

## 0.1.5 - 2026-04-28

PR #10 — quality sweep + 4 coverage-push batches (33.34% → 63.79% line coverage).

### Added
- `PhoenixKit.Modules.Publishing.Errors` — central atom-to-gettext mapping (36 atoms + 4 tagged-tuple shapes) plus `truncate_for_log/2` to cap unbounded log payloads (AI responses, HTTP errors).
- `PhoenixKit.Modules.Publishing.ActivityLog.log_failed_mutation/5` — writes a `db_pending: true` audit row when a user-driven mutation fails, so the audit trail still captures intent on DB constraint failures.
- Activity logging on every Posts / Groups / Versions / TranslationManager mutation (success and failure paths).
- `phx-disable-with` on every async / destructive admin button.

### Changed
- **PubSub payload contract** — `broadcast_post_created/2`, `broadcast_post_updated/2`, `broadcast_post_status_changed/2`, and `broadcast_version_created/2` now emit a minimal `%{uuid:, slug:}` payload instead of the full post map. Receivers should refetch the post via `Publishing.read_post/4` (or any of the read helpers) rather than destructuring the broadcast. Internal consumers were already doing this; **host apps that subscribe to `PubSub.posts_topic/1` must update their pattern matches.**
- `DBStorage.upsert_group/1` rewritten as atomic `INSERT ... ON CONFLICT DO UPDATE` — closes a TOCTOU race where two concurrent callers with the same slug could both observe `nil` and then crash on the unique index.
- `Web.Settings.mount/3` moved DB reads into `handle_params/3` (Phoenix iron law: `mount/3` runs twice per page load).
- `StaleFixer.apply_stale_fix/3` retries once on `(group_uuid, slug)` unique-index conflict using a deterministic `post_uuid[0..8]` suffix.
- `StaleFixer.fix_all_stale_values/0` now streams posts under `Repo.checkout/1` so large catalogues don't hold every post in memory.
- Posts save path: `maybe_sync_datetime_and_audit/3` consolidates timestamp-mode date sync + audit field updates into a single `update_post/2` (halves round-trips per save).
- Three `rescue _` clauses narrowed to `UndefinedFunctionError | ArgumentError`: `LanguageHelpers.reserved_language_code?/1`, `LanguageHelpers.single_language_mode?/0`, `Web.Controller.Language.valid_language?/1`.
- `Web.Controller.Translations.language_enabled_for_public?/2` renamed to `exact_enabled_for_public?/2` to distinguish from `LanguageHelpers.language_enabled?/2` (the looser variant).
- `Workers.TranslatePostWorker.translate_content/4` → `/3` and `skip_already_translated/5` → `/4` — dropped unused `group_slug` parameter (internal callers only).

### Fixed
- `Errors.truncate_for_log/2` UTF-8 boundary handling — multibyte input could previously return an invalid binary if `max` landed mid-codepoint; clip now walks back to the previous codepoint boundary.

### Docs
- Earmark `escape: false` trust model documented inline in `renderer.ex` (admin-authored Markdown only; rewire `html_sanitize_ex` if untrusted input ever reaches `render_markdown/1`).

## 0.1.4 - 2026-04-24

PR #9 — closes issues #6, #7, #8 plus related content-normalization and admin URL consistency work.

### Added
- `publishing_default_language_no_prefix` setting (Issue #7) — opt-in URL convention where the default language is served prefixless (`/blog` instead of `/en/blog`); prefixed URLs 301-redirect to the canonical. `Language.request_matches_canonical_url?/2` prevents redirect loops.
- `LanguageHelpers.get_primary_language_base/0`, `url_language_code/1`, `use_language_prefix?/1` — normalize dialect codes (`"en-GB"`) to URL base codes (`"en"`) for public routing. (Issue #6)
- `StaleFixer.normalize_content_language/1` — self-healing for legacy base-only content rows (`"en"`) when a dialect (`"en-GB"`) becomes the default. Paired with `TranslationManager` legacy-base promotion and `Posts.read_post` lazy retry-on-miss.
- Activity-log events for self-healing mutations: `publishing.content.language_normalized`, `.merged`, `.promoted`.
- `PhoenixKit.Modules.Publishing.ActivityLog` wrapper — guarded with `Code.ensure_loaded?/1` + `try/rescue` so audit failures never crash the primary mutation.
- Controller test-endpoint infrastructure (`Test.Endpoint`, `Test.Router`, `Test.Layouts`, `PhoenixKitPublishing.ConnCase`).

### Changed
- Public URL builders (`group_listing_path/3`, `build_post_url/4`, `build_public_path_with_time/4`) normalize dialect codes via `url_language_code/1`.
- Admin preview URLs (`Web.Index`, `Web.Listing`, `Web.New`) now route through `PublishingHTML` builders instead of hand-rolling prefix logic. (Follow-up to #6)
- Public language switcher deduplicates base + dialect entries and highlights the active language exactly.

### Fixed
- Forward `phoenix_kit_current_scope` from `Web.HTML.all_groups/1` and `Web.HTML.index/1` into `LayoutWrapper.app_layout` so the parent app header sees authenticated users on public Publishing pages. (Issue #8)
- Translation bug in cache-toggle flashes.
- Dialyzer warning on a statically-true `is_binary/1` guard introduced in PR #3.

### Docs
- `AGENTS.md` and `README.md` updated with the new setting, scope-forwarding convention for public templates, controller-test infrastructure pointer, and activity-log event table.

## 0.1.3 - 2026-04-11

### Fixed
- Add routing anti-pattern warning to AGENTS.md
2026-04-02

### Changed
- Migrate select elements to daisyUI 5 label wrapper pattern
- Remove deprecated `select-bordered` class for daisyUI 5 compatibility
- Rename routes module to `PhoenixKitPublishing.Routes`

### Fixed
- Add `language_titles` to `to_post_map` so `list_posts` includes translated titles

### Maintenance
- Upgrade dependencies

## 0.1.1 - 2026-03-26

### Fixed
- Remove `Code.ensure_loaded?` guards on `LanguageHelpers` in `db_storage.ex` and `mapper.ex` — call directly via alias instead of silently falling back to `"en"`
- Add deprecation warning to `set_translation_status/5` no-op (was returning `:ok` silently)
- Remove duplicate `site_default_language/0` private functions from `db_storage.ex` and `mapper.ex` — use `LanguageHelpers.get_primary_language()` directly
- Fix unused `all_posts` variable warnings in `listing.ex` (leftover from primary language removal)
- Remove unused `Helpers` alias in `collaborative.ex`
- Remove unused `@content_statuses` and `LanguageHelpers` alias in `translation_manager.ex`
- Fix alias ordering (credo) in `editor.ex`, `translation.ex`, `translate_post_worker.ex`, `renderer.ex`
- Reduce nesting depth in `do_publish_version`, `translate_single_language`, `skip_already_translated`, `render_versioned_post`, `build_post_url`, `toggle_version_access`, `translate_content`, `translate_now`
- Alias nested module in `test_helper.exs`

## 0.1.0 - 2026-03-25

### Added
- Extract Publishing module from PhoenixKit into standalone `phoenix_kit_publishing` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add 4 Ecto schemas: PublishingGroup, PublishingPost, PublishingVersion, PublishingContent
- Add dual URL modes: timestamp-based (blog/news) and slug-based (docs/FAQ)
- Add multi-language support with per-language content per version
- Add version management (create, publish, archive, clone)
- Add collaborative editing with Phoenix.Presence (owner/spectator locking)
- Add two-layer caching: ListingCache (`:persistent_term`) and Renderer (ETS, 6hr TTL)
- Add Markdown + PHK component rendering (Image, Hero, CTA, Video, Headline, Subheadline, EntityForm)
- Add PageBuilder XML parser (Saxy) for inline PHK components
- Add admin LiveViews: Index, Listing, Editor, Preview, PostShow, Settings
- Add public Controller with language detection, slug resolution, pagination, and smart fallbacks
- Add Oban workers for AI translation and primary language migration
- Add PubSub broadcasting for real-time admin updates
- Add route module with `admin_routes/0`, `admin_locale_routes/0`, and `public_routes/0`
- Add `css_sources/0` for Tailwind CSS scanning support
- Add migration module (run by parent app) with `IF NOT EXISTS` guards for all 4 tables
- Add unit and integration test suites
