# AGENTS.md

Guidance for AI agents working on `phoenix_kit_publishing`.

## Overview

Database-backed CMS for PhoenixKit: content groups (blog, docs, faq), posts with
versioning, per-language content, collaborative editing, and dual URL modes
(timestamp-based for blogs/news, slug-based for docs/evergreen). It implements
the `PhoenixKit.Module` behaviour, so a host app gets it by adding the dependency
— no config, no route wiring. Public pages are served by a plain Phoenix
controller (dead views); the admin side is LiveView.

- **Depends on:** `phoenix_kit` `~> 2.14` (Hex), `phoenix_kit_ai` `~> 0.18`
  (hard — it owns the `Translatable` adapter behaviour, the per-language Oban
  fan-out, the LLM call and `ai_multilang_tabs/1`; publishing contributes only
  the adapters and the editor wiring), `phoenix_kit_comments` `~> 0.3`
  (`only: :test`; the production seam is optional and guarded with
  `Code.ensure_loaded?/1`), `phoenix_kit_og` (optional, no dep at all — guarded
  seam), plus `leaf`, `phoenix_live_view`, `mdex`, `saxy`, `oban`, `gettext`.
- **Consumed by:** core's Sitemap module, which calls
  `PhoenixKit.Modules.Publishing.{enabled?/0, list_groups/0, list_posts/2}`
  behind `Code.ensure_loaded?/1`; `phoenix_kit_projects`, whose extension
  registry duck-types `phoenix_kit_project_extensions/0` for its Docs project
  tab.
- **Admin surface:** one top-level tab `Publishing` at `/admin/publishing`
  (dynamic children, one per group, at `/admin/publishing/<slug>`), plus a
  settings subtab at `/admin/settings/publishing`. Public routes are served
  through `RouterDispatch`, not the router's route table.
- **Module key** `"publishing"`; settings prefix `publishing_`.

The core pin is a hard floor, not a preference (reasons in `mix.exs`):
`PublishingGroup.changeset/2` needs `PhoenixKit.Utils.Slug.put_slug/3`, and
`Constants.to_site_wall/2` / `from_site_wall/3` need a core that parses an IANA
time-zone id rather than reading it as offset 0 — under an older core every
timestamp post is stamped and syndicated on UTC while the editor shows the site
clock. Don't lower it.

The `leaf` requirement is `~> 0.4.1 or ~> 0.5`, and the two-branch form is
deliberate: plain `~> 0.4.1` reads as `< 0.5.0`, and because core declares
`~> 0.3` a host resolving both then silently held publishing a release behind.
The `0.4.1` floor is load-bearing (inline suggestions and `:flush`). Don't
re-tighten the range.

## What this module does NOT do

Deliberate non-features, so nobody adds them assuming they were missed.

- **No HTML sanitiser on Markdown output.** `Renderer` calls MDEx with
  `render: [unsafe: true]` so admin-authored `<div class="grid">` / inline HTML /
  `<script>` tags pass through (GFM `tagfilter` is deliberately left off). The
  trust boundary is "only admins author content"; if untrusted input ever reaches
  `render_markdown/1` (API import, AI prompt-injection on rotating roles), wire
  `html_sanitize_ex` in front of it. See `render_markdown_html/1` in
  `renderer.ex`.
- **No outbound HTTP from this module.** AI translation dispatches via
  `phoenix_kit_ai`, which owns the `Req` boundary and its SSRF allowlist. A
  future feature that needs direct HTTP should retrofit the
  `Req.Test`-via-app-config pattern.
- **No per-language Mailer or webhook delivery.** Publishing exposes posts via
  the public Controller; subscriptions and notifications are Newsletters /
  Emails territory.
- **No retry layer on AI translation failures.** `TranslationManager` returns
  `{:error, {:ai_translation_failed, reason}}` on the first failure; the user
  retries from the UI. Oban-backed retries would need backoff plus actor
  attribution — out of scope.
- **No editor-side conflict resolution beyond owner/spectator locking.** Two
  admins editing the same post in different tabs see Presence-driven indicators
  and the spectator's writes are blocked at the form level. There is no
  merge-on-conflict UX.
- **No client-side undo stack.** Versions are the undo mechanism — every save
  leaves a row in `phoenix_kit_publishing_versions`.
- **No frontend bundle and no LiveView JS hooks.** Tailwind/daisyUI classes are
  emitted by the renderer; the host's `app.css` gets an `@source` for
  `phoenix_kit_publishing` from `css_sources/0`.
- **No migrations of its own.** Every table ships in core's chain; see
  Database & migrations.
- **No all-groups public overview.** If one returns it returns as an opt-in
  reserved route, not as a catch-all sibling.
- **No guest commenting.** The comments seam requires a logged-in user because
  the comments schema `validate_required`s `user_uuid`; guest support is a
  cross-repo change in the comments module first.

## Commands

```bash
mix deps.get
createdb phoenix_kit_publishing_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
PHOENIX_KIT_AI_PATH=../phoenix_kit_ai mix test
```

`pk_dep/3` wraps `:phoenix_kit` and `:phoenix_kit_ai` only. `:phoenix_kit_comments`
is a plain `only: :test` tuple, so it always resolves from Hex.

This repo's `precommit` alias also runs `deps.unlock --check-unused` and
`mix hex.audit` (retired-dep scan) before `quality.ci`; both can fail a
`precommit` that compiles and tests cleanly.

```bash
mix test test/phoenix_kit_publishing/posts_test.exs      # one file
mix test test/phoenix_kit_publishing/posts_test.exs:42   # one line
mix test --only integration                              # DB-backed tests only
mix quality                                              # format + credo --strict + dialyzer
mix docs
for i in $(seq 1 10); do mix test; done                  # stability check for sandbox/activity-log flakes
```

## Conventions

- **Module key** `"publishing"`, identical in every callback, settings key,
  permission and activity `module` field.
- **Tab ids** are prefixed `:admin_publishing`; the per-group children are
  `:admin_publishing_<sanitized_slug>_<phash>` so two groups can never collide on
  a tab id.
- **URL segments use hyphens**, not underscores (`publishing/new-group`).
- **Admin navigation paths go through `PhoenixKit.Utils.Routes.path/1`.** Never
  hardcode, never use a relative path.
- **Public URLs go through the builders in `Web.HTML`** —
  `group_listing_path/3`, `build_post_url/4`, `build_public_path_with_time/4`,
  `feed_path/3`, `term_archive_path/3`. Never hand-roll prefix logic in an admin
  template; the prefix, the locale segment and the per-language slug all vary.
- **Routing is the route-module pattern.** `route_module/0` returns
  `PhoenixKitPublishing.Routes`; `admin_routes/0` and `admin_locale_routes/0`
  each declare every admin path (the localized variant adds the `:locale` segment
  and `_localized` `:as` aliases). `admin_tabs/0` carries only the parent
  Publishing entry, because the Listing/Editor/Preview/PostShow tree has dynamic
  `:group` / `:post_uuid` segments a `Tab` struct cannot express. In each list,
  literal paths must precede `:group` param paths.
- **Never hand-register plugin LiveView routes in a host router.** PhoenixKit
  injects them into `live_session :phoenix_kit_admin`; a hand-written route sits
  outside it, loses the admin layout and crashes the socket on navigation
  ("redirecting across live_sessions"). Core's `guides/custom-admin-pages.md` is
  the reference.
- **Never override `def call/2` in a host router.** Publishing's public dispatch
  owns the single `defoverridable call: 2` token that Phoenix.Router grants; a
  host override on either side of `phoenix_kit_routes()` silently bypasses one of
  the two. Put instrumentation in a pipeline plug or the endpoint instead. See
  [dev_docs/guides/router-dispatch.md](dev_docs/guides/router-dispatch.md).
- **`mix phx.routes` will not show the public routes** under their user-facing
  shape — they live under the `__phoenix_kit_publishing_dispatch` prefix. This is
  intentional, not a missing route.
- **`constraints: %{...}` on a Phoenix route is silently ignored** — there is no
  per-segment regex mechanism. Locale-vs-group disambiguation happens in
  `Web.Controller.Language.detect_language_or_group/2`, which rewrites
  `conn.params`.
- **Smart fallback is two rows, and both are load-bearing:**

  | Situation | Behaviour |
  |-----------|-----------|
  | Group exists; post / version / translation / time missing | redirect to the nearest valid parent (other language → other time on that date → group listing) with the `"Showing closest match"` flash |
  | Group does not exist | render 404. Never redirect to "the first group in the DB" |

  Under `url_prefix: "/"` the catch-all sits at the host's absolute root, so a
  first-group fallback would hijack `/about`, `/contact` and every other unclaimed
  host path.
- **LiveView macro:** admin LiveViews use `use PhoenixKitWeb, :live_view`, never
  `use Phoenix.LiveView` directly. The one exception is
  `web/project_docs_live.ex`, embedded in the projects hub and rendered without
  admin chrome. Admin LiveViews never wrap templates in `LayoutWrapper`; the
  public branches in `Web.HTML` do.
- **Public templates must forward `phoenix_kit_current_scope`.** Every
  `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` call in `Web.HTML` needs
  `phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}`, or the host
  header renders the page as logged-out even when the controller knows better.
- **Gettext:** this module owns `PhoenixKitPublishing.Gettext` and
  `priv/gettext` (en, et, fr, it, ru). Modules opt in with
  `use Gettext, backend: PhoenixKitPublishing.Gettext`; tabs pass
  `gettext_backend: PhoenixKitPublishing.Gettext`. Extract with
  `mix gettext.extract --merge`. Only the macro form `gettext("…")` is visible to
  the extractor — a runtime `Gettext.gettext(Backend, "…")` call enters no
  catalogue — and `gettext.merge` can reword an entry without a `fuzzy` flag, so
  diff new msgids against the pre-merge `.po`.
- **No JavaScript hooks and no `js_sources/0`.** The inline `<script>` / `<style>`
  blocks in `web/html.ex` are page scripts for dead views (reading-progress bar,
  scroll rails, scrollbar restyle, comment thread), not LiveView hooks. If a hook
  is ever needed, prefer a core hook, otherwise ship a prebuilt bundle via
  `js_sources/0` under a namespaced global. Never register a hook from an inline
  `<script>`: morphdom does not execute inserted script tags, so it vanishes on
  LiveView navigation.
- **`enabled?/0` must never raise.** It reads `publishing_enabled` through a
  swappable settings module (`PhoenixKit.Config` key
  `:publishing_settings_module`, default `PhoenixKit.Settings`); core's
  `get_boolean_setting/2` rescues to the default, so an unavailable DB yields
  `false`. Keep any new work off that path.
- **Dashboard tab loading rescues narrowly** — `publishing_children/1` and
  `load_publishing_groups_for_tabs/0` catch only `Ecto.QueryError`,
  `DBConnection.ConnectionError` and `Postgrex.Error`: tabs render on every admin
  mount, but a `MatchError` there is a real bug and must still surface.
- **Soft delete:** posts use `trashed_at` (nil = active), groups use
  `status` (`"active"` / `"trashed"`). There is no post status column — status is
  version-level.
- **Dual URL modes** (`"timestamp"` / `"slug"`) are locked at group creation and
  never change.
- **Content format** is Markdown plus inline PHK XML components (`<Image>`,
  `<Hero>`, `<CTA>`, `<Video>`, `<Headline>`, `<Subheadline>`, `<EntityForm>`,
  `<Audio>`), parsed by Saxy.
- **Hashtags in the body ARE the tag system** — writers type `#elixir` inline and
  tags derive from the prose on save; there is no tags field. `#` must be followed
  immediately by a letter, at line start or after whitespace/`(`, which excludes
  Markdown headings, URL fragments, code spans and link anchors by construction.
- **Version scopes ride PubSub as STRINGS.** `:translation_created` /
  `:translation_deleted` carry `to_string(version_number)` because the editor
  filters them against `to_string(socket.assigns.current_version)`. A raw integer
  compares unequal and the event is dropped silently.
- **Collaborative form keys are version-scoped:** `"<group>:<uuid>:v<N>:<lang>"`
  from `PubSub.generate_form_key/3` when the post map carries an integer
  `:version`; older 2- and 3-segment shapes remain for path/slug posts, and
  new-post keys also carry `socket.id` (two admins composing separate drafts have
  nothing to collaborate on). Anything comparing form keys by string must handle
  every shape — `same_post_and_version?/2` in `web/editor.ex` is the reference.
- **Admin LiveView assigns available on every admin page:**
  `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`.

### Language rules

Four rules; the mechanism is in
[dev_docs/guides/language-routing.md](dev_docs/guides/language-routing.md).

- **A language's URL segment is not its identity.** Builders resolve the segment
  through `LanguageHelpers.public_url_segment/1` but keep the ORIGINAL code for
  the per-language slug lookup and the `use_language_prefix?/1` decision. When
  dialects share a base, the base's owner (primary-preferred, then
  first-declared) keeps `/en/…` and a sibling gets its full lowercase code
  (`/en-gb/…`), so enabling a sibling never changes an existing URL.
- **Every dialect match site must be case-insensitive.** Lowercase URL segments
  normalize back to stored BCP-47 case (`en-gb` → `en-GB`) in
  `RouterDispatch.enabled_dialect_case_insensitive?/2`,
  `Language.detect_language_or_group/2`, `Posts.resolve_language_to_dialect/1`
  and `Listing.find_matching_language/2`. A new site that compares
  case-sensitively misses every sibling URL.
- **Only the PRIMARY language may go prefixless** under
  `default_language_no_prefix`. `LanguageHelpers.use_language_prefix?/1` and
  `Language.prefixed_default_language_request?/2` compare the resolved FULL code,
  never the base — a base comparison also claims the primary's siblings, and
  `/en-GB/…` would 301 onto the prefixless URL that serves `en-US`.
- **Normalize on read, not before it.** `Posts.read_post/4` and the slug finders
  retry through the legacy base language on `:not_found` and repair the row in
  place via `StaleFixer`. Don't pre-check for staleness on the hot path; the
  retry-on-miss shape keeps a healthy read at one query.

### Activity logging

Every mutation logs through `PhoenixKit.Modules.Publishing.ActivityLog`, a thin
wrapper over `PhoenixKit.Activity.log/1` that injects `module: "publishing"`,
guards with `Code.ensure_loaded?/1`, and rescues so an audit failure can never
crash the mutation it describes. Three call shapes:

```elixir
# Standard user-driven mutation — every CRUD context fn.
ActivityLog.log_manual(action, actor_uuid, resource_type, resource_uuid, metadata)

# Pulls :actor_uuid out of opts (keyword or map); nil when absent.
ActivityLog.actor_uuid(opts)

# Raw map shape, used by the self-healing auto-events.
ActivityLog.log(%{action: …, mode: "auto", resource_type: …, resource_uuid: …, metadata: …})
```

Rules: metadata is PII-safe keys only — `ActivityLog.reason_string/1` collapses
an `%Ecto.Changeset{}` to `"changeset_error"` precisely because a changeset
carries submitted names and free text. LiveView callers thread the actor with
`Shared.actor_uuid_from_socket/1` rather than reading
`socket.assigns.phoenix_kit_current_scope.user.uuid` inline. Failures log too, as
`db_pending` rows via `log_failed_mutation/5`, so a vanished admin action stays
auditable. Patterns and the auto-event details are in
[dev_docs/guides/activity-logging.md](dev_docs/guides/activity-logging.md).

User-driven actions (`mode: "manual"`):

| action | resource_type |
|--------|---------------|
| `publishing.post.created` / `.updated` / `.trashed` / `.restored` / `.unpublished` / `.categorized` | `publishing_post` |
| `publishing.group.created` / `.updated` / `.trashed` / `.restored` / `.deleted` | `publishing_group` |
| `publishing.version.created` / `.published` / `.deleted` | `publishing_version` |
| `publishing.translation.added` / `.cleared` / `.deleted` | `publishing_content` |
| `publishing.category.created` / `.updated` / `.deleted` | `publishing_category` |
| `publishing.category.reordered` | `publishing_group` (failure rows say `publishing_category` — known drift) |
| `publishing.comment.created` / `.replied` | `publishing_post` |
| `publishing.module.enabled` / `.disabled` | `publishing_module` |

Self-healing actions (`mode: "auto"`, no actor):
`publishing.content.language_normalized`, `publishing.content.merged`,
`publishing.content.promoted`, `publishing.content.metadata_promoted`,
`publishing.post.auto_trashed`.

### Landmines

- **A publishing setting that stopped being a publishing setting.**
  `publishing_default_language_no_prefix` is legacy — core's Languages module
  migrates it to `default_language_no_prefix` and owns it. Reading the
  `publishing_`-prefixed key gets a value nobody writes; go through
  `LanguageHelpers.default_language_no_prefix?/0`.
- **`ListingCache.invalidate/1` from a PubSub receiver storms the cluster.**
  `invalidate/1` erases locally AND broadcasts; the no-broadcast variant is
  `erase_local/1`, which is what `ListingCache.CacheSync` must call on receipt.
- **A peer node's `:persistent_term` listing cache never misses on its own.**
  It is process-less, so without `CacheSync` a peer kept serving pre-mutation
  listings until an unrelated LOCAL mutation. Delivery is at-most-once PubSub:
  a partitioned node stays stale until its next local mutation or restart. The
  listing cache is eventually consistent, by design; erase-only, so an
  invalidation can never trigger a cluster-wide regeneration storm.
- **A version number compared as an integer against a PubSub payload always
  loses** — the payloads are strings. Symptom: the editor silently ignores
  `:translation_created` / `:translation_deleted`.
- **Custom `url_slug` uniqueness is application-level only.** There is no partial
  UNIQUE index, so a race or a path that skips
  `SlugHelpers.url_slug_exists?/4` can write a duplicate, after which the public
  read path's auto-renamer has to clean it up.
- **`mix precommit` can fail on a green suite.** `deps.unlock --check-unused` and
  `mix hex.audit` run in the alias; an unused lock entry or a retired transitive
  package fails the run with no test or compile error in sight.

## Architecture

A library, not an application: no endpoint, no repo, no supervision tree of its
own. The host app supplies all three; `children/0` contributes processes into
PhoenixKit's supervisor.

```
lib/phoenix_kit_publishing/
├── publishing.ex          # facade + PhoenixKit.Module callbacks + OG variable resolution
├── {groups,posts,versions,categories}.ex + db_storage.ex (+ mapper)   # contexts + the Ecto layer
├── {translation_manager,ai_translatable,group_ai_translatable,group_ai_translate_binding}.ex
├── {language_helpers,slug_helpers,hashtags,views,metadata,constants,shared,errors}.ex
├── {presence,presence_helpers,pubsub}.ex        # collaborative editing + broadcasts
├── {routes,router_dispatch}.ex                  # admin route tree; host-side public dispatch
├── stale_fixer.ex, activity_log.ex, group_settings.ex, comments.ex, gettext.ex
├── listing_cache.ex (+ cache_sync, lock_table_owner), renderer.ex
├── page_builder.ex (+ parser, renderer, components/)
├── schemas/               # 6 Ecto schemas
└── web/                   # admin LiveViews, public Controller (+ 9 submodules), HTML
```

### Key modules

- `PhoenixKit.Modules.Publishing` — facade and behaviour implementation. Also
  carries `og_variables/0` / `og_resolve/2` for the `phoenix_kit_og` seam and
  `phoenix_kit_project_extensions/0` for the projects hub. The latter lives here,
  not in `PhoenixKitPublishing`, because the projects registry scans modules
  rather than file paths.
- `Publishing.DBStorage` — the only Ecto layer. Resolves the repo through
  `PhoenixKit.RepoHelper.repo()`, so multi-tenant hosts work.
- `Publishing.ListingCache` — `:persistent_term` listing metadata, capped at the
  most recent 5,000 posts per group. `invalidate/1` erases locally AND
  broadcasts; `erase_local/1` is the receive-side variant.
  `ListingCache.LockTableOwner` owns the regeneration-lock ETS table so it
  outlives request processes; `ListingCache.CacheSync` erases on peer
  invalidation.
- `Publishing.Renderer` — Markdown → HTML via MDEx/comrak, cached in
  `PhoenixKit.Cache` under `:publishing_posts` (24h TTL, max 2000, FIFO). The key
  folds a content hash and a `@cache_version` token, so an edit or a renderer
  change mints a new key instead of needing a purge.
- `Publishing.StaleFixer` — read-path repair; also auto-trashes empty posts past
  a grace period.
- `Publishing.Errors` — every public-API error tuple returns either an atom
  listed in `@type error_atom` or one of four tagged tuples
  (`{:ai_translation_failed, _}`, `{:ai_extract_failed, _}`,
  `{:ai_request_failed, _}`, `{:source_post_read_failed, _}`). `message/1`
  translates through this module's gettext backend, keeping the API layer
  locale-agnostic; `truncate_for_log/2` is the canonical way to put an opaque
  reason in a `Logger` call (500-char budget, appends `(truncated, N bytes)`). A
  new atom needs `@type error_atom`, the doctest example and a
  `def message(:new_atom)` clause — `errors_test.exs` enforces that every atom
  has a string.
- `Publishing.Web.*` — admin LiveViews (Index, New, Edit, Listing, Editor,
  Preview, PostShow, CategoriesLive, Settings) plus the public Controller and its
  submodules (Routing, Language, SlugResolution, PostFetching, PostRendering,
  Listing, Translations, Feed, Fallback) and `Web.HTML`.

### Discovery flow

PhoenixKit scans `.beam` files at startup, so adding the dep is the whole
install. `admin_tabs/0` + `settings_tabs/0` register pages and `route_module/0`
supplies the admin route tree, both compiled into routes at build time; settings
persist through `PhoenixKit.Settings`; `permission_metadata/0` declares the
permission that `Scope.has_module_access?/2` checks; `css_sources/0` returns
`[:phoenix_kit_publishing]` so the installer adds the Tailwind `@source` without
which Tailwind purges this module's classes.

### Data model

```
Group (1) ──→ (many) Post (1) ──→ (many) Version (1) ──→ (many) Content
```

- **`..._groups`** — content containers. `name`, `slug` (unique), `mode`
  (`"timestamp"` / `"slug"`), `status` (`"active"` / `"trashed"`), `position`;
  `data` JSONB holds type, item names, icon, feature flags, the ~22 display
  settings and `name_i18n`; `title_i18n` / `description_i18n` are reserved.
- **`..._posts`** — routing shell only: `slug`, `mode`, `post_date`, `post_time`
  (URL identity), `active_version_uuid` FK (null = unpublished), `trashed_at`
  (null = active), `created_by_uuid` / `updated_by_uuid`. No content, status or
  metadata — those live on versions.
- **`..._versions`** — source of truth for published state: `post_uuid`,
  `version_number` (unique per post), `status` (draft/published/archived),
  `published_at`, `data` JSONB (`featured_image_uuid`, tags, seo, description,
  `allow_version_access`, notes, `created_from`). Status is version-level: every
  language in a version shares it.
- **`..._contents`** — per-language title and body: `version_uuid`, `language`
  (unique per version), `title`, `content` (markdown), `url_slug` (per-language
  routing), plus reserved `status` / `data`. Read fallback: requested language →
  site default → first available.
- **`..._categories`** — hierarchical per-group taxonomy; nullable `parent_uuid`
  self-FK, `slug` unique per group, `name_i18n` display names. Deleting a group
  cascades; deleting a parent lifts children to the root.
- **`..._post_categories`** — post ↔ category M:N, post-level not per-version.
  Both sides cascade.
- **`..._post_views`** — one `(post_uuid, view_date)` counter row per day, queried
  without a schema module.

### PubSub topics

All broadcast through `PhoenixKit.PubSub.Manager` (the host's PubSub), never a
raw `Phoenix.PubSub` call.

| Topic | Built by | Payloads |
|-------|----------|----------|
| `publishing:groups` | `PubSub.groups_topic/0` | `{:group_created, group}`, `{:group_updated, group}`, `{:group_deleted, slug}` |
| `publishing:<group>:posts` | `posts_topic/1` | `:post_created`, `:post_updated`, `:post_deleted`, `:post_status_changed`, `:version_created`, `:version_live_changed`, `:version_deleted` |
| `publishing:<group>:post:<slug>:versions` | `post_versions_topic/2` | version lifecycle for one post |
| `publishing:<group>:post:<slug>:translations` | `post_translations_topic/2` | `:translation_created` / `:translation_deleted`, version scope as a STRING |
| `publishing:editor_forms` + per-key topics | `editor_form_topic/1` | collaborative form sync |
| per-group cache topics | `cache_topic/1`, `cache_invalidation_topic/0` | `{:cache_invalidated, slug}` |
| `publishing:<group>:editors` | `group_editors_topic/1` | editor presence for a group |

### Settings keys

Site-wide keys, all read through `PhoenixKit.Settings`.

| Key | Default | Description |
|-----|---------|-------------|
| `publishing_enabled` | `false` | Master on/off switch (via `enable_system/0`) |
| `publishing_public_enabled` | `true` | Serve public routes |
| `publishing_posts_per_page` | `20` | Listing pagination size (clamped 1–200) |
| `publishing_reading_wpm` | `200` | Words per minute for the reading-time estimate (clamped 50–1000) |
| `publishing_editor_lock_minutes` | `30` | Editor owner-lock timeout (clamped 1–480) |
| `publishing_slug_style` | `"transliterate"` | `transliterate` / `unicode` / `ascii`; anything else, or any error, falls back to `:transliterate` |
| `publishing_memory_cache_enabled` | `true` | Toggle the listing cache |
| `publishing_render_cache_enabled` | `true` | Toggle the Markdown render cache (global) |
| `publishing_render_cache_enabled_<slug>` | `true` | Per-group override for the render cache |
| `publishing_show_language_switcher` | `true` | Render the in-page language switcher on listing + post pages. Turn off when the host layout provides one |
| `publishing_render_og_tags` | `true` | Render og/twitter meta tags **in-page** (inside the public body), so previews work even when the host root layout ignores the forwarded `:og`. Turn off when the host renders `:og` in `<head>`, to avoid duplicates |
| `publishing_render_jsonld` | `true` | schema.org `Article` JSON-LD in-page on post pages, from the same refined `:og` map. `escape: :html_safe` on the encode so no value can close the script tag early |
| `publishing_feeds_enabled` | `true` | RSS 2.0 per group at `/<group>/feed.xml` (localized variants too; newest 50 published posts for the language). `feed.xml` is a reserved tail segment in `Routing.parse_path/1`. Off → 404, never the smart fallback (a feed URL must not redirect to HTML). Canonical-prefix 301s ARE emitted feed-to-feed, matching `rel="self"` |
| `publishing_translation_endpoint_uuid` | unset | Admin override for the AI endpoint used by translation |
| `publishing_translation_prompt_uuid` | unset | Admin override for the AI prompt used by translation |

`default_language_no_prefix` is **core's** Languages setting, not a publishing
key; core migrates the legacy `publishing_default_language_no_prefix` key onto
it. Read it via `LanguageHelpers.default_language_no_prefix?/0`.

Per-group display settings live in each group's `data` JSONB, not in settings
keys — see
[dev_docs/guides/group-display-settings.md](dev_docs/guides/group-display-settings.md).

### Permissions

One permission, `"publishing"` (`permission_metadata/0`: label "Publishing", icon
`hero-document-duplicate`). No sub-permissions. Every admin tab and settings tab
carries `permission: "publishing"`.

### Host-consumable conn assigns

Both are set on `conn.assigns` by `Web.Controller` and forwarded through
`LayoutWrapper.app_layout`'s generic `:module_assigns` map from the public render
branches (`index/1`, `show/1` in `Web.HTML`).

| Assign | Shape | Notes |
|--------|-------|-------|
| `:phoenix_kit_publishing_translations` | list of `%{code, name, flag, url, current}` | Always set on listing + post conns, regardless of `publishing_show_language_switcher`. Exactly those five fields on both route types — the controller normalises at the boundary, stripping internal-only fields (`display_code`; on post routes also `enabled`/`known`) so external consumers get one uniform shape |
| `:og` | listing: `%{title, url, locale, type: "website"}`; post: `%{title, description, image, url, locale, type: "article"}` plus up to three `og:image:*` hints (`image_width`, `image_height`, `image_type`) | 4 fields on listings, 6–9 on posts. `description` and `image` may be `nil` |

**Function-component layouts only see declared attrs.** Both assigns reach
`root.html.heex` (a plain template) but NOT `<.app_layout>` or the host's
`Layouts.app` unless every wrapper declares and forwards them. The chain is:
controller sets the assign → publishing's public render branches pass it in
`module_assigns={%{…}}` → core's `LayoutWrapper.app_layout` declares the generic
`:module_assigns` map attr and merges its keys into the top-level assigns before
invoking `Layouts.app/1`. The map is generic on purpose — core must not carry a
hard-coded list of every module's host-consumable keys. A host reading from
`root.html.heex` needs none of this; a host reading from `Layouts.app/1` needs
all three steps. `language_switcher_exposure_test.exs` ("host-integration
boundary") pins the chain.

Core's switcher takes the translations assign directly through
`per_translation_urls={assigns[:phoenix_kit_publishing_translations]}` on
`PhoenixKitWeb.Components.Core.LanguageSwitcher.language_switcher_dropdown`. With
it, the switcher uses publishing's per-translation URLs — necessary for groups
with per-language URL slugs, where a simple locale rewrite produces wrong URLs;
without it (and per-language, for languages with no translation) it falls back to
the locale-rewrite default.

## Database & migrations

None. All seven `phoenix_kit_publishing_*` tables ship in core's chain — the
group/post/version/content four in the V135 squash baseline, categories,
post_categories and post_views in a later core migration — and
`migration_module/0` is unset. A schema change is a core migration first, then
schema edits here.

All tables use UUIDv7 primary keys, and every table-backed schema declares
`use PhoenixKit.SchemaPrefix`.

## Testing

Test database `phoenix_kit_publishing_test`. Unit tests (schemas, changesets,
pure functions) always run; DB-backed tests are tagged `:integration` and
`test_helper.exs` excludes them when `psql -lqt` cannot find the database or the
connection fails. Integration tests live in
`test/phoenix_kit_publishing/integration/`, controller tests in
`test/phoenix_kit_publishing/web/controller/`.

`test_helper.exs` builds the schema with
`PhoenixKit.Migration.ensure_current(TestRepo, log: false)` — the same call a
host makes in production, and the one that re-applies newly shipped `Vxxx`
migrations on every boot by handing Ecto.Migrator a fresh wall-clock version.
There is no module-side DDL anywhere, so test/prod schema drift is impossible by
construction. It then starts `PhoenixKit.PubSub.Manager`,
`PhoenixKit.ModuleRegistry`, `PhoenixKit.Cache.Registry` (without it the render
cache's rescue clauses swallow every cache path), a `PhoenixKit.TaskSupervisor`
(the Listing LV spawns a stale-fixer task and would otherwise crash `:noproc`), a
supervisor for `Publishing.Presence` (Presence-via-`use` needs a live registry
before any test runs), and — only when the DB is available — the two test
endpoints. It also pins `{PhoenixKit.Config, :url_prefix}` to `"/"` in
`:persistent_term` so public URL builders match the test router.

Support modules under `test/support/` (compiled via `elixirc_paths(:test)`):

- `Test.Repo`; `Test.Endpoint` / `Test.DispatchEndpoint` (minimal
  `Phoenix.Endpoint`s with a `Phoenix.LiveView.Socket`; the dispatch pair
  exercises `RouterDispatch`); `Test.Router` / `Test.DispatchRouter` (routes
  matching `Web.Controller.show/2` plus admin LV routes wrapped in
  `live_session :admin_publishing` / `:admin_publishing_settings` with the
  `:assign_scope` on_mount hook).
- `Test.Layouts` — minimal root + parent layout stand-in. `Layouts.app/1` renders
  flash divs (`#flash-info`, `#flash-error`, `#flash-warning`) so LV tests can
  assert flash content with `render(view) =~ …`.
- `Test.Hooks` — the `:assign_scope` `on_mount` hook: pulls
  `phoenix_kit_test_scope` from the session (set with `LiveCase.put_test_scope/2`)
  and assigns `:phoenix_kit_current_scope`, `:phoenix_kit_current_user`,
  `:current_locale_base`, `:current_locale`, `:url_path`, mirroring core's
  production auth hook.
- `PhoenixKitPublishing.{ConnCase, LiveCase, DataCase}` plus `PhoenixKit.DataCase`
  (in `phoenix_kit_data_case.ex`) — case templates. ConnCase does sandbox checkout
  plus `with_scope/1`; LiveCase runs the sandbox in shared mode and adds
  `put_test_scope/2` and `fake_scope/1`.
- `PhoenixKitPublishing.ActivityLogAssertions` — `assert_activity_logged/2`,
  `refute_activity_logged/2`, `list_activities/0`, imported into DataCase and
  LiveCase. Queries `phoenix_kit_activities` with raw SQL and normalises
  Postgres's 16-byte UUIDs against the string UUIDs callers pass.
- `PhoenixKitOG` (in `phoenix_kit_og_stub.ex`) — test-only stand-in taking the
  real plugin's module name so `maybe_refine_og_with_module/4` dispatches to it.
  Its `refine_og/4` raises for exactly one post title so the guarded seam can be
  proven; it must NOT raise unconditionally, or the clause is inferred as
  returning `none()` and the compiler flags the controller's handling of the
  result as unreachable.

`config/test.exs` points `PhoenixKit.Config :layout` at the test layouts so
`LayoutWrapper.app_layout` does not fall back to `PhoenixKitWeb.Layouts.root`,
which needs `PhoenixKitWeb.Endpoint`. `PhoenixKit.Config` key
`:publishing_settings_module` swaps the settings backend, which is how tests
drive `enabled?/0` without a DB.

Reference tests: `web/controller/show_layout_test.exs` (controller through the
layout), `web/settings_live_test.exs` (LV smoke),
`integration/activity_logging_test.exs`, `web/controller/public_routes_test.exs`
(smart-fallback contract), `web/controller/language_switcher_exposure_test.exs`
(host-integration boundary), `errors_test.exs`, `group_settings_test.exs`,
`core_pin_conformance_test.exs`, `schema_prefix_conformance_test.exs`.

Known noise on a green run: the editor's deferred language switch logs a
`GenServer terminating … cannot push_patch/2 … does not point to the current root
view` report while the test itself passes. The suite has also flaked on
sandbox/activity-log timing; the repeat loop in Commands is the stability check.

## Feature notes

| Feature | The constraint that must hold | Guide |
|---------|-------------------------------|-------|
| Public dispatch (`RouterDispatch`) | The host router's `call/2` override and `restore_path/2` are a pair: without the restore, the canonical-URL redirect emits the internal prefix and loops forever. Never add a second `call/2` override. | [dev_docs/guides/router-dispatch.md](dev_docs/guides/router-dispatch.md) |
| Smart fallback / 404 policy | A missing GROUP renders 404; only a missing child of an existing group redirects. Under `url_prefix: "/"` the alternative hijacks host paths. | [dev_docs/guides/router-dispatch.md](dev_docs/guides/router-dispatch.md) |
| Per-group display settings | A new setting must be added in all five places (`Constants` → schema accessor → `merge_group_config`/`db_group_to_map` → edit form → `GroupSettings` spec) or the spec test fails; `update_group/3` stays lenient, `validate_group_settings/1` stays strict. | [dev_docs/guides/group-display-settings.md](dev_docs/guides/group-display-settings.md) |
| Translatable group name | Overrides live in an isolated `data["name_i18n"]` map, never in the multilang helper's `data`-owning convention, which would clobber the display settings. The slug is never translated. | [dev_docs/guides/group-display-settings.md](dev_docs/guides/group-display-settings.md) |
| Activity logging | An audit failure never crashes its mutation, and a changeset never reaches metadata. | [dev_docs/guides/activity-logging.md](dev_docs/guides/activity-logging.md) |
| Language routing and dialects | Segment ≠ identity, every dialect match is case-insensitive, only the primary goes prefixless, and the editor resolves base → dialect through `resolve_language_for_post/2` before deciding new-vs-existing translation. | [dev_docs/guides/language-routing.md](dev_docs/guides/language-routing.md) |
| OpenGraph metadata | `build_og_data/4` layers derived defaults → per-post `content.data["og"]` override → the optional `phoenix_kit_og` plugin, highest last; the plugin seam stays fully guarded (`Code.ensure_loaded?` + `function_exported?` + rescue) so a host without it falls back unchanged. The in-page copy is gated per request by `publishing_render_og_tags` and deliberately sits outside the render cache, so toggling takes effect immediately. | `@moduledoc` on `Web.Controller` |
| Language switcher | `:phoenix_kit_publishing_translations` is exposed regardless of `publishing_show_language_switcher`, so a host can render its own switcher either way. | Host-consumable conn assigns, above |
| Comments seam | Optional and guarded: no production dep, every call `Code.ensure_loaded?` + rescued, and rendering needs module installed AND enabled AND the group's `comments_enabled`. Submission is Phoenix-first (no JS) via POST routes in core's dispatch scope to `Controller.create_comment/2`, guarded in this order: module/public/group gates → honeypot (`website` field; filled = pretend success) → signed `Phoenix.Token` time trap (3s–1 day) → post-in-published-set → logged-in user. Every outcome redirects back with a flash; moderation uses the comments module's own admin. | `@moduledoc` on `Publishing.Comments` |

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

This repo does do GitHub releases. Name the release after the tag, title it
`<version> - <date>` using the CHANGELOG's release date, and take the body from
that version's CHANGELOG section:

```bash
# Extract this version's section (stop at the previous heading), then release from it.
awk '/^## x\.y\.z /{f=1;next} /^## /{f=0} f' CHANGELOG.md > /tmp/notes.md
gh release create vx.y.z --title "x.y.z - <changelog date>" --notes-file /tmp/notes.md
```

Pass `--latest=false` when backfilling an older version, or `gh` marks the
newest-created release as Latest and demotes the current one.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

`dev_docs/pull_requests/README.md` and `TEMPLATE.md` exist in this repo.

## TODOs

- **Add a partial UNIQUE index for custom `url_slug`s** on
  `phoenix_kit_publishing_contents (version_uuid/group, language, url_slug)` for
  non-trashed rows, so a duplicate becomes impossible at the source instead of
  something the read path's auto-renamer cleans up. This module owns no chain, so
  it is a core migration — do it when the next core migration touches publishing.
- **Unify the two base→dialect resolvers.** `new_translation_request?/2` (against
  `post.available_languages`) and `Posts.resolve_language_to_dialect/1` (against
  `enabled_language_codes/0`) answer the same question with different tie-breaks;
  a `Languages.resolve_in/3` with a `:tie_break` opt would close it. Trigger: the
  next refactor touching either layer.
- **Fix the `reorder_categories/3` resource_type drift** by passing the resource
  type into `log_category_failure/5`, which hardcodes `publishing_category` while
  success rows log `publishing_group`.
- **Multi-tab sync flicker in the editor's collaborative module.** Same user with
  two tabs of one post plus a concurrent spectator: both owner tabs answer the
  spectator's initial sync, so the spectator's view flickers once and settles
  (nothing is lost). The fix — elect one tab as primary sync responder by
  socket_id ordering — needs a test mounting two LV processes for the same user.
- **Centralize the `"published"` status string** (~75 sites across
  `db_storage.ex`, `stale_fixer.ex`, `versions.ex`, controllers and LVs) into
  `Constants.status_published/0`. Use `ast-grep`; missing one of 75 by hand is
  the real risk. Low urgency while the value cannot change without a migration.
- **Preview-tab loading indicator** (`web/preview.ex`): a `phx-update="ignore"`
  skeleton before `render_markdown_content/1` returns would smooth the hang on
  large PHK XML. Trigger: a benchmark showing it matters.
- **Translation button immediate-disable** in the editor. `phx-disable-with`
  covers most cases; the gap is a double-enqueue on slow networks before the
  server's `ai_translation_status` assign returns. Closing it means this module's
  first JS, so it arrives via `js_sources/0`, never an inline script.
