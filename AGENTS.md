# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

PhoenixKit Publishing module — a database-backed CMS providing content groups, posts with versioning, multi-language support, collaborative editing, and dual URL modes (timestamp-based for blogs/news, slug-based for docs/evergreen). Implements the `PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix application.

## Common Commands

### Setup & Dependencies

```bash
mix deps.get                                  # Install dependencies
createdb phoenix_kit_publishing_test          # First-time integration-test DB
```

### Testing

```bash
mix test                                      # All tests (excludes :integration if DB absent)
mix test test/phoenix_kit_publishing/posts_test.exs   # Specific file
mix test test/phoenix_kit_publishing/posts_test.exs:42 # Specific line
mix test --only integration                   # DB-backed tests only
for i in $(seq 1 10); do mix test; done       # Stability check (sandbox/activity-log flakes)
```

### Code Quality

```bash
mix format                                    # Format code (imports Phoenix LiveView rules)
mix credo --strict                            # Lint
mix dialyzer                                  # Type checking
mix precommit                                 # compile + format + credo --strict + dialyzer
mix quality                                   # format + credo --strict + dialyzer
mix quality.ci                                # format --check-formatted + credo --strict + dialyzer
mix docs                                      # Generate documentation
```

## Local cross-repo development

`phoenix_kit` (and any sibling `phoenix_kit_*` dep) resolves from Hex by
default. To build or test this module against a **local checkout** of a
dependency — e.g. an unpublished core change — export `<APP>_PATH` and Mix
swaps the Hex pin for a `path:` + `override: true` dep at resolve time:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test     # this module against local core
PHOENIX_KIT_AI_PATH=../phoenix_kit_ai mix test
```

The variable name is the dep's app name upper-cased with `_PATH` appended
(`:phoenix_kit` -> `PHOENIX_KIT_PATH`, `:phoenix_kit_ai` ->
`PHOENIX_KIT_AI_PATH`). Set several at once to override multiple deps. This
module's sibling overrides: `PHOENIX_KIT_AI_PATH`. **Unset = the
published pin**, so `mix hex.publish` and CI resolve exactly as before.
Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a `phoenix_kit*`
dep into a `path:` tuple (a committed path dep ships a broken package); set
the env var instead.

## Architecture

This is a **library** (not a standalone Phoenix app) that provides publishing/CMS capabilities as a PhoenixKit plugin module.

### Key Modules

- **`PhoenixKit.Modules.Publishing`** (`lib/phoenix_kit_publishing/publishing.ex`) — Main facade implementing `PhoenixKit.Module` behaviour. Delegates to all submodules.

- **`Publishing.Groups`** (`lib/phoenix_kit_publishing/groups.ex`) — Group CRUD (create, list, update, trash, restore). Slug auto-generation, type normalization.

- **`Publishing.Posts`** (`lib/phoenix_kit_publishing/posts.ex`) — Post CRUD, reading by UUID/slug/datetime, status transitions, timestamp collision detection.

- **`Publishing.Versions`** (`lib/phoenix_kit_publishing/versions.ex`) — Version creation, publishing, deletion, cloning. One published version per post.

- **`Publishing.TranslationManager`** (`lib/phoenix_kit_publishing/translation_manager.ex`) — Add/delete languages, translation status, AI translation via Oban workers.

- **`Publishing.DBStorage`** (`lib/phoenix_kit_publishing/db_storage.ex`) — Raw Ecto CRUD layer. Uses `PhoenixKit.RepoHelper.repo()` for multi-tenant support.

- **`Publishing.ListingCache`** (`lib/phoenix_kit_publishing/listing_cache.ex`) — `:persistent_term` cache (~0.1us reads) for post metadata. Invalidated on mutations. `invalidate/1` erases locally AND broadcasts `{:cache_invalidated, slug}`; `erase_local/1` is the no-broadcast variant `ListingCache.CacheSync` calls on receipt (calling `invalidate/1` there would storm the cluster).

- **`Publishing.ListingCache.CacheSync`** (`listing_cache/cache_sync.ex`) — supervised node-local subscriber that erases this node's cached terms when another node invalidates a group. `:persistent_term` is process-less, so a peer node's warm cache never misses on its own and kept serving pre-mutation listings until an unrelated LOCAL mutation. **Erase-only** — the next read rebuilds lazily, so an invalidation can never start a cluster-wide regeneration storm. Delivery is PubSub at-most-once: a partitioned node misses the purge until its next local mutation or restart. The listing cache is eventually consistent, not strongly.

- **`Publishing.Renderer`** (`lib/phoenix_kit_publishing/renderer.ex`) — Markdown→HTML via MDEx (comrak) with ETS caching (6hr TTL). Detects and renders inline PHK components.

- **`Publishing.PageBuilder`** (`lib/phoenix_kit_publishing/page_builder.ex`) — XML parser (Saxy) for PHK components (`<Image>`, `<Hero>`, `<CTA>`, etc.).

- **`Publishing.Presence`** (`lib/phoenix_kit_publishing/presence.ex`) — Phoenix.Presence for collaborative editing with owner/spectator locking.

- **`Publishing.PubSub`** (`lib/phoenix_kit_publishing/pubsub.ex`) — Real-time broadcasting for groups, posts, and editor forms.

- **`Publishing.Routes`** (`lib/phoenix_kit_publishing/routes.ex`) — Route definitions for admin LiveViews and public controller routes.

- **`Publishing.StaleFixer`** (`lib/phoenix_kit_publishing/stale_fixer.ex`) — Data consistency repair, auto-cleans empty posts.

- **`Publishing.Web.*`** (`lib/phoenix_kit_publishing/web/`) — Admin LiveViews (Index, Listing, Editor, Preview, PostShow, Settings) and public Controller with submodules (Routing, Language, SlugResolution, PostFetching, PostRendering, Listing, Translations, Fallback).

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `admin_tabs/0` callback registers admin pages; PhoenixKit generates routes at compile time
4. `route_module/0` provides additional admin and public routes
5. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
6. Permissions are declared via `permission_metadata/0` and checked via `Scope.has_module_access?/2`

### File Layout

```
lib/phoenix_kit_publishing/
├── publishing.ex              # Main facade (PhoenixKit.Module behaviour)
├── activity_log.ex            # Thin wrapper around PhoenixKit.Activity.log/1
├── constants.ex               # @valid_modes, default_title, max lengths, etc.
├── db_storage.ex              # Direct Ecto CRUD layer (RepoHelper)
├── db_storage/
│   └── mapper.ex              # struct → map projections (post + listing payloads)
├── groups.ex                  # Group CRUD context (delegates to DBStorage)
├── posts.ex                   # Post CRUD + save pipeline (legacy promotion, audit batching)
├── versions.ex                # Version create/publish/archive
├── translation_manager.ex     # Add/delete languages + AI translate dispatch
├── language_helpers.ex        # Dialect resolution, enabled-language gating
├── slug_helpers.ex            # Slug generation + URL-safe sanitisation
├── presence.ex                # Phoenix.Presence for the editor
├── presence_helpers.ex        # Owner/spectator locking helpers
├── pubsub.ex                  # Real-time broadcast helpers (groups/posts/editor forms)
├── routes.ex                  # admin_locale_routes/0, admin_routes/0, public routes
├── shared.ex                  # Cross-module helpers (audit_metadata, parse_timestamp_path)
├── stale_fixer.ex             # Self-healing: language normalize, slug uniqueness, active version
├── listing_cache.ex           # :persistent_term cache (~0.1us reads)
├── renderer.ex                # MDEx (comrak) + ETS render cache (6h TTL)
├── page_builder.ex            # Saxy XML parser for PHK components
├── page_builder/              # Per-component renderers (Image, Hero, CTA, ...)
├── metadata.ex                # YAML frontmatter parsing helpers
├── schemas/                   # 4 Ecto schemas (group, post, version, content)
├── web/                       # 8 admin LiveViews + Controller + HTML templates
└── workers/                   # Oban background jobs (translate worker)
```

### Database Tables

All 4 tables use UUIDv7 primary keys. **Migrations live in phoenix_kit core** — `phoenix_kit_publishing_*` tables are created by V59 and evolved in later V*.ex files. There is no module-owned migration; tests delegate schema setup to `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, ...)` (see `test/test_helper.exs`), the same call the host app makes in production.

> **TODO (next publishing core migration):** add a partial UNIQUE index on
> `phoenix_kit_publishing_contents (version_uuid?/group, language, url_slug)` for
> non-trashed rows. Custom `url_slug` uniqueness is currently enforced only at the
> application level (`SlugHelpers.url_slug_exists?/4`, which now fails closed) — a
> race or a path that skips the check can still write a duplicate, after which the
> public read-path auto-renamer has to clean it up. A DB constraint would make it
> impossible at the source. (Surfaced by the M13 audit fix.)

```
Group (1) ──→ (many) Post (1) ──→ (many) Version (1) ──→ (many) Content
```

**`phoenix_kit_publishing_groups`** — Content containers (blog, faq, docs)
- `name`, `slug` (unique), `mode` ("timestamp"/"slug"), `status` ("active"/"trashed"), `position`
- `data` JSONB: type, item names, icon, feature flags (comments/likes/views)
- `title_i18n` JSONB: translatable title keyed by language code (for future use)
- `description_i18n` JSONB: translatable description keyed by language code (for future use)

**`phoenix_kit_publishing_posts`** — Routing shell only
- `slug`, `mode`, `post_date`, `post_time` — URL identity
- `active_version_uuid` FK → versions — points to the live version (null = unpublished)
- `trashed_at` — soft delete timestamp (null = active)
- `created_by_uuid`, `updated_by_uuid` — audit
- **No content, status, or metadata** — all of that lives on versions

**`phoenix_kit_publishing_versions`** — Source of truth for published state
- `post_uuid`, `version_number` (unique per post), `status` (draft/published/archived)
- `published_at` — when first published
- `data` JSONB: featured_image_uuid, tags, seo, description, allow_version_access, notes, created_from
- **Status is version-level** — all languages in a version share the same status

**`phoenix_kit_publishing_contents`** — Per-language title + body
- `version_uuid`, `language` (unique per version), `title`, `content` (markdown body)
- `url_slug` — per-language URL slug for localized routing
- `status`, `data` JSONB — reserved columns for future per-language overrides (unused by UI currently)
- **Language fallback**: requested language → site default → first available

## Critical Conventions

- **Module key** must be consistent across all callbacks: `"publishing"`
- **Tab IDs**: prefixed with `:admin_publishing_` (e.g., `:admin_publishing_groups`)
- **URL paths**: use hyphens, not underscores (`"publishing/new-group"`)
- **Navigation paths**: always use `PhoenixKit.Utils.Routes.path/1`, never relative paths
- **`enabled?/0`**: must rescue errors and return `false` as fallback (DB may not be available)
- **LiveViews use `PhoenixKitWeb` macros** — use `use PhoenixKitWeb, :live_view` (not `use Phoenix.LiveView` directly)
- **JavaScript hooks**: must be inline `<script>` tags; register on `window.PhoenixKitHooks`
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`
- **Dual URL modes**: `"timestamp"` or `"slug"` — locked at group creation, never changed
- **Content format**: Markdown with inline PHK XML components (Image, Hero, CTA, Video, Headline, Subheadline, EntityForm)
- **Admin routing** — plugin LiveView routes are auto-discovered by PhoenixKit and compiled into `live_session :phoenix_kit_admin`. Never hand-register them in a parent app's `router.ex`; use `live_view:` on a tab or a route module. See `phoenix_kit/guides/custom-admin-pages.md` for the authoritative reference
- **Public templates must forward `phoenix_kit_current_scope`** — every `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` call in `Web.HTML` needs `phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}` so the parent app's header sees the authenticated user. Omitting it renders the page as logged-out even when the controller knows otherwise (see Issue #8)
- **Public URL building** — always go through `PublishingHTML.group_listing_path/3` / `build_post_url/4` / `build_public_path_with_time/4` / `feed_path/3` / `term_archive_path/3`; never hand-roll prefix logic in admin templates (see Issue #7)
- **Language segment ≠ language identity** — every public URL builder resolves its path segment through `LanguageHelpers.public_url_segment/1`, but keeps the ORIGINAL code for the per-language slug lookup and the `use_language_prefix?/1` decision. When several enabled dialects share a base, the base's OWNER (primary-preferred, then first-declared) keeps the historical base segment (`/en/…`) and a NON-owner sibling gets its full lowercase code (`/en-gb/…`) — the only shape that can address it at all. Enabling a sibling therefore never changes an existing URL. Lowercase dialect segments are normalized back to the stored BCP-47 case (`en-gb` → `en-GB`) in `RouterDispatch.enabled_dialect_case_insensitive?/2`, `Web.Controller.Language.detect_language_or_group/2`, `Posts.resolve_language_to_dialect/1` and `Listing.find_matching_language/2` — a new match site must be case-insensitive too or it will miss every sibling URL
- **Only the PRIMARY language may go prefixless** under `publishing_default_language_no_prefix`. Both `LanguageHelpers.use_language_prefix?/1` and `Language.prefixed_default_language_request?/2` compare the resolved FULL code, not the base — a base comparison also claims the primary's siblings, and `/en-GB/…` would 301 to the prefixless URL that serves `en-US`
- **Collaborative form keys are version-scoped**: `"<group>:<uuid>:v<N>:<lang>"` from `PubSub.generate_form_key/3` when the post map carries an integer `:version` (older 2/3-segment shapes remain for path/slug posts). New-post keys additionally carry `socket.id` — two admins composing drafts have nothing to collaborate on. Anything comparing form keys by string must handle every shape; see `same_post_and_version?/2` in `web/editor.ex`
- **Version scopes ride PubSub as STRINGS.** `:translation_created` / `:translation_deleted` carry `to_string(version_number)` because the editor filters them against `to_string(socket.assigns.current_version)`. A raw integer compares unequal and the event is silently dropped — that exact bug shipped in PR #38 and was caught post-merge
- **Deleting a translation is a hard delete, and the primary language's row can't be deleted at all.** Both `TranslationManager.clear_translation/5` and `delete_language/5` `repo.delete` the content row (the old `status: "archived"` was reader-dead — nothing filtered archived rows, so a "deleted" translation kept serving publicly and `create_version_from` resurrected it) and both refuse the primary row with `:cannot_delete_primary_language`. A legacy base-code row (`"en"` while primary is `"en-US"`) counts as primary; an enabled sibling (`"en-GB"`) does not. Versions remain the only undo
- **Language normalization on read** — `Posts.read_post/4` and the slug finders retry through the legacy base language on `:not_found` and fix stale content in place via `StaleFixer`. Don't pre-check for staleness on the hot path — the retry-on-miss pattern keeps healthy reads at one query
- **Base→enabled-dialect resolution** — `Posts.resolve_language_to_dialect/1` (private, used by every `read_post*` entry point) maps a base code (`"en"`) to whichever enabled dialect actually exists. When several dialects share the base, prefers `LanguageHelpers.get_primary_language/0`, otherwise the first match in `enabled_language_codes/0` declaration order; falls back to `DialectMapper.base_to_dialect/1` only when no enabled dialect matches the base. The Listing builds `?lang=<primary_base>` for the editor's default click-through, so this resolver is on the hot path for every "click a post title" navigation. **The Editor's UUID-mode and path-mode `handle_params` clauses must run `Web.Controller.Language.resolve_language_for_post/2` (via the local `new_translation_request?/2` helper) against `post.available_languages` before deciding new-vs-existing translation.** A naive `language not in post.available_languages` check on the raw URL param routes `?lang=en` against `["en-GB", "ru"]` into `handle_new_translation_params/6` — which empties the form (see Issue #11).

  Two-stage flow on a click into the editor:

  ```
  URL ?lang=<code>
       │
       ▼
  new_translation_request?/2
       │   uses Web.Controller.Language.resolve_language_for_post/2
       │   against post.available_languages (Enum.find first match)
       ▼
  ┌──── resolved in available? ────┐
  │ yes                         no │
  ▼                                ▼
  load existing translation     handle_new_translation_params/6
       │                        (empty form)
       ▼
  Publishing.read_post_by_uuid(language, …)
       │
       ▼
  Posts.resolve_language_to_dialect/1
       │   against enabled_language_codes/0
       │   (primary tie-break, then declaration order;
       │    DialectMapper fallback if no enabled dialect)
       ▼
  read content for the resolved dialect
  ```

  The two stages answer the same "base → dialect" question with
  subtly different tie-break rules and against different lists. A
  future unification (`Languages.resolve_in/3` with a `:tie_break`
  opt) would close that divergence — flag for the next refactor that
  touches either layer.

## Routing: Single Page vs Multi-Page

> ⚠️ **Never hand-register plugin LiveView routes in the parent app's `router.ex`.** PhoenixKit injects module routes into its own `live_session :phoenix_kit_admin` automatically. A hand-written route sits outside that session, which (a) loses the admin layout — `:phoenix_kit_ensure_admin` only applies it inside the session — and (b) crashes the socket on navigation between admin pages (`navigate event failed because you are redirecting across live_sessions`).

Publishing uses the **route module** pattern via `Publishing.Routes`. Both `admin_locale_routes/0` and `admin_routes/0` declare every admin LiveView path (the localized variant gets `:locale` segment + `_localized` `:as` aliases). Tabs in `admin_tabs/0` carry only the parent-level Publishing entry; per-page routes come from the route module so we can express the full Listing/Editor/Preview/PostShow tree (including dynamic `:group` / `:post_uuid` segments) without enumerating each as a `Tab` struct.

Public routes (the Controller's `show/2`, `index/2`) historically lived in `Publishing.Routes.public_routes/1`. (The all-groups overview template was deleted 2026-08 — it had been unrouted dead code; an overview would come back as an opt-in reserved route, not a resurrection.) **As of the routing-strategy change** that function returns an empty AST — public dispatch now routes through `PhoenixKitPublishing.RouterDispatch` (see "Public dispatch" below).

> Phoenix.Router has **no per-segment regex constraint mechanism** — `constraints: %{...}` on a route is silently ignored. Don't add one expecting it to filter. Locale-vs-group disambiguation is done in the controller by `Web.Controller.Language.detect_language_or_group/2`, which rewrites `conn.params` so the smart-fallback below reads the corrected interpretation.

## Public dispatch — `RouterDispatch`

`PhoenixKitPublishing.RouterDispatch` is the host-side routing strategy that lets publishing's catch-all coexist with host routes shaped `/:locale/<literal>/...` declared after `phoenix_kit_routes()` in the parent's router. Without this, publishing's `/:language/:group/*path` matches every two-or-more-segment URL (Phoenix matches by declaration order with no fall-through), silently shadowing host routes — most painfully under `url_prefix: "/"`. See `lib/phoenix_kit_publishing/router_dispatch.ex` moduledoc for the full mechanism.

Three pieces:

1. **Internal-prefix scope with root/localized discriminators.** Publishing's catch-all is registered under `/__phoenix_kit_publishing_dispatch/...` with **two sub-scopes** — `/localized` (binds `:language` + `:group`) and `/root` (binds `:group` only). The discriminator is load-bearing: without it, both `/:language/:group` and `/:group/*path` match a 2-segment internal path and Phoenix's first-match-wins picks the localized form even when the URL had no locale prefix, sending the controller `language=<group-slug>, group=<post-slug>` and 404'ing because the post slug isn't a group. With the discriminator, the override picks the right shape based on which segment matched a known group, and Phoenix unambiguously dispatches the right route. Core's `phoenix_kit_routes/0` macro emits the parent scope with the standard `:browser` + `:phoenix_kit_*` pipelines plus an extra `:phoenix_kit_publishing_internal` pipeline that runs `RouterDispatch.restore_path/2`.

2. **`call/2` override on the host router.** Phoenix.Router's `match_dispatch/0` emits `def call/2` with `defoverridable init: 1, call: 2` (a documented extension point). The macro emits an override that calls `RouterDispatch.maybe_rewrite/1`:
   - cache hit on a known group slug → rewrites `path_info` + `request_path` to prepend the internal prefix, stashes originals in `conn.private`, then `super(conn, opts)` runs Phoenix's matcher against the internal-prefix route and dispatches via the standard pipeline.
   - cache miss → conn passes through unchanged; `super` matches host routes normally.

3. **Path restore.** `restore_path/2` (run as part of the internal scope's pipeline, after route bindings are extracted into `conn.params`) un-mutates `request_path` and `path_info` so controllers reading them for canonical-URL generation see the URL the client sent. **Without this**, publishing's `default_language_no_prefix` redirect computes a Location header with the internal prefix, the browser follows, the override re-rewrites — infinite loop. The redirect-loop trap is the single failure mode worth pinning a test for.

The override is emitted unconditionally inside `phoenix_kit_routes/0` (compile-time gated on `Code.ensure_loaded?(PhoenixKitPublishing.RouterDispatch)`), so installs that don't have publishing in the dep tree get a no-op.

**`mix phx.routes` blind spot.** The publishing routes appear under the `__phoenix_kit_publishing_dispatch` prefix. Devs grepping for `:group` or `/blog` won't find a top-level route; they need to know to look for the internal prefix. Documented here so the mismatch with the user-facing URLs is intentional, not surprising.

**Host with their own `def call/2` override.** Phoenix.Router's `defoverridable init: 1, call: 2` consumes one override token. The macro emits ours via `def call(conn, opts) do ... super(conn, opts) end` and does NOT re-arm `defoverridable [call: 2]` afterwards. If a host app's router has their own `def call/2` (e.g., a hand-rolled instrumentation hook before `use PhoenixKitWeb, :router`), there are two cases:
* Host's override comes BEFORE `phoenix_kit_routes()` — host consumes the token; our subsequent `def call/2` would emit a "redefining" warning AND not call host's via super (we'd call Phoenix's instead). Host's instrumentation is bypassed silently.
* Host's override comes AFTER `phoenix_kit_routes()` — same warning shape but with the directions reversed; host's def replaces ours and bypasses publishing dispatch.

Recommendation for hosts: put instrumentation in a pipeline plug or in the endpoint's plug stack, not in `def call/2`. A pipeline plug runs through Phoenix's normal flow and composes cleanly with the override. If you absolutely must override `call/2`, do it inside the endpoint module rather than the router (endpoints have their own override surface that doesn't conflict with router-level overrides).

## Smart fallback semantics

The public Controller delegates 404 handling to `Web.Controller.Fallback`. The policy is two-layer:

| Situation | Behavior |
|-----------|----------|
| Requested **group exists**, post/version/translation/time missing | redirect to nearest valid parent (other language → other time on date → group listing) with the `"Showing closest match"` flash |
| Requested **group does not exist** | render 404. Never redirect to "the first group in the DB" |

This split is **load-bearing when `url_prefix` is `"/"`** — publishing's `/:group/*path` catch-all then sits at the host's absolute root and sees every URL the host's own routes don't claim earlier. Falling back to the first group in that mode would hijack random host-app paths (`/about`, `/contact`, ...) and silently redirect them to an unrelated publishing page.

Tests pin the exact contract in `test/phoenix_kit_publishing/web/controller/public_routes_test.exs` — "smart fallback contract" describe block. Don't loosen those to `assert conn.status in [...]` matches; the bug they prevent only shows up when the assertion is exact.

## Activity Logging

Mutations route through `PhoenixKit.Modules.Publishing.ActivityLog` — a thin wrapper around `PhoenixKit.Activity.log/1` that injects `module: "publishing"`, guards with `Code.ensure_loaded?/1`, and rescues `Postgrex.Error` (the missing-`phoenix_kit_activities`-table case) silently plus all other exceptions with a `Logger.warning`. Audit failures must never crash the primary mutation.

The wrapper exposes three call shapes:

```elixir
# Standard "user-driven mutation" — used by every CRUD context fn.
ActivityLog.log_manual(action, actor_uuid, resource_type, resource_uuid, metadata)

# Extracts `:actor_uuid` from opts (keyword or map). Returns nil when the
# key isn't present — context fns thread this through every mutation.
ActivityLog.actor_uuid(opts)

# Raw map shape (used by the self-healing auto-events).
ActivityLog.log(%{action: …, mode: "auto", resource_type: …, resource_uuid: …, metadata: …})
```

Pattern for new call sites:

```elixir
def my_mutation(arg, opts \\ []) do
  case do_mutation(arg) do
    {:ok, record} = result ->
      ActivityLog.log_manual(
        "publishing.<resource>.<verb>",
        ActivityLog.actor_uuid(opts),
        "publishing_<resource>",
        record.uuid,
        %{... PII-safe keys only ...}
      )

      result

    other ->
      other
  end
end
```

LiveView callers thread the actor UUID via `Shared.actor_uuid_from_socket/1`:

```elixir
def handle_event("trash_post", %{"uuid" => post_uuid}, socket) do
  case Publishing.trash_post(group_slug, post_uuid,
         actor_uuid: Shared.actor_uuid_from_socket(socket)
       ) do
    ...
  end
end
```

Reading the actor in one place keeps `socket.assigns.phoenix_kit_current_scope.user.uuid` from being copy-pasted into every event handler.

Currently auto-logged self-healing events:

Current auto-events:

| action | when | resource_type |
|--------|------|---------------|
| `publishing.content.language_normalized` | Legacy base-code content (e.g. `"en"`) rewritten to the enabled dialect (`"en-US"`) by `StaleFixer` | `publishing_content` |
| `publishing.content.merged` | Legacy and dialect rows for the same version merged by `StaleFixer`. Metadata includes `discarded_body` — true when a divergent non-blank legacy body lost to the target's; its text is stashed in the merged row's `data["_stale_fixer"]["discarded"]` (whitelisted in Posts' content-data preservation, so edits keep it) | `publishing_content` |
| `publishing.content.promoted` | Legacy base-code row promoted in place when the admin adds the corresponding dialect translation | `publishing_content` |
| `publishing.content.metadata_promoted` | Legacy V1 content.data keys (`description`, `featured_image_uuid`, `seo_title`, `excerpt`) promoted to `version.data` on first edit so the V2 whitelist (`previous_url_slugs`, `updated_by_uuid`, `custom_css`, `og`, `_stale_fixer`) can wipe content.data without losing the value. Metadata: `language`, `version_uuid`, `promoted_keys`. Self-healing — runs at most once per legacy row | `publishing_content` |
| `publishing.post.auto_trashed` | An empty post (no content in any version) past the grace period, trashed by `StaleFixer` | `publishing_post` |

All five run with `mode: "auto"` and no `actor_uuid` — they're system-triggered, not user-initiated. Metadata includes `from_language`/`to_language`/`version_uuid`.

`StaleFixer` runs on the public READ path, so it tracks whether any fixer actually wrote (a process-local dirty flag set by `mark_listing_dirty/0`) and invalidates the group's listing cache exactly once, only when something changed — invalidating unconditionally would nuke the cache on every post read.

### User-driven CRUD events

Every mutating context function in Posts / Groups / Versions / TranslationManager / Categories / Comments logs a corresponding `mode: "manual"` row via `ActivityLog.log_manual/5`. The full list:

| action | resource_type |
|--------|---------------|
| `publishing.post.created` | `publishing_post` |
| `publishing.post.updated` | `publishing_post` |
| `publishing.post.trashed` | `publishing_post` |
| `publishing.post.restored` | `publishing_post` |
| `publishing.post.unpublished` | `publishing_post` |
| `publishing.post.categorized` | `publishing_post` |
| `publishing.group.created` | `publishing_group` |
| `publishing.group.updated` | `publishing_group` |
| `publishing.group.trashed` | `publishing_group` |
| `publishing.group.restored` | `publishing_group` |
| `publishing.group.deleted` | `publishing_group` |
| `publishing.version.created` | `publishing_version` |
| `publishing.version.published` | `publishing_version` |
| `publishing.version.deleted` | `publishing_version` |
| `publishing.translation.added` | `publishing_content` |
| `publishing.translation.cleared` | `publishing_content` |
| `publishing.translation.deleted` | `publishing_content` |
| `publishing.category.created` | `publishing_category` |
| `publishing.category.updated` | `publishing_category` |
| `publishing.category.deleted` | `publishing_category` |
| `publishing.category.reordered` | `publishing_group` (failure rows say `publishing_category` — see below) |
| `publishing.comment.created` | `publishing_post` |
| `publishing.comment.replied` | `publishing_post` |
| `publishing.module.enabled` | `publishing_module` |
| `publishing.module.disabled` | `publishing_module` |

`cleared` vs `deleted` on translations distinguishes the two entry points
(`clear_translation/5` vs `delete_language/5`) in the feed — both hard-delete
the row since 2026-08.

**Failure side.** Every user-driven mutation also leaves a `db_pending` row
via `ActivityLog.log_failed_mutation/5` when it fails, so a vanished admin
action is still auditable. Categories and translations funnel their error
branches through single chokepoints (`log_category_failure/5`,
`log_translation_failure/6`) rather than logging at each site. Reasons go
through `ActivityLog.reason_string/1`, which collapses an `%Ecto.Changeset{}`
to `"changeset_error"` — changesets carry the submitted params (names, free
text) and must never reach metadata.

> **Known drift:** `reorder_categories/3` logs success against
> `"publishing_group"` (the reorder is a group-scoped operation) but its
> failure rows go through the shared `log_category_failure/5` chokepoint,
> which hardcodes `"publishing_category"`. Filtering an activity feed by
> `resource_type` therefore splits reorder successes from failures. Harmless
> today; fix by passing the resource type into the chokepoint.

Mutating context fns accept `opts \\ []` (or already accept it) and pull `actor_uuid` out via `ActivityLog.actor_uuid/1`. `update_post/4` additionally falls back to the audit-metadata path's `:updated_by_uuid` when no explicit `actor_uuid` opt is present, so legacy LV callers that only thread `:scope` continue to attribute correctly.

Caller pattern from a LiveView (admin pages):

```elixir
defp actor_opts(socket) do
  case socket.assigns[:phoenix_kit_current_scope] do
    %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
    _ -> []
  end
end

# in handle_event/3:
Posts.trash_post(group_slug, post_uuid, actor_opts(socket))
```

Module enable/disable runs without an actor (`actor_uuid: nil`) since it can be triggered from IEx as well as the UI; if you need attribution add it from the admin LV before calling `enable_system/0`.

## Errors module

`PhoenixKit.Modules.Publishing.Errors` is the central atom→user-facing-string dispatcher. Every public-API error tuple in the module either returns one of the documented atoms (`@type error_atom` lists 44 of them) or one of four tagged tuples (`{:ai_translation_failed, _}`, `{:ai_extract_failed, _}`, `{:ai_request_failed, _}`, `{:source_post_read_failed, _}`). UI flash messages call `Errors.message/1` to translate via `gettext/1` from this module's own `PhoenixKitPublishing.Gettext` backend (`priv/gettext/`) — keep the API layer locale-agnostic; let the UI decide presentation.

`Errors.truncate_for_log/2` is the canonical way to render an opaque error reason inside `Logger.*` calls that target external HTTP responses or large AI payloads. Default budget 500 chars; appends `(truncated, N bytes)` so the log line is still grep-able.

```elixir
case AI.extract_content(response) do
  {:ok, text} -> {:ok, text}
  {:error, reason} -> {:error, {:ai_extract_failed, reason}}  # Errors.message/1 turns this into "Failed to extract AI response: …"
end
```

Add new error atoms by extending `@type error_atom`, the doctest example, and adding a `def message(:new_atom), do: gettext(...)` clause. The per-atom test in `test/phoenix_kit_publishing/errors_test.exs` enforces that every atom has a documented English string.

## Settings Keys

| Key | Default | Description |
|-----|---------|-------------|
| `publishing_enabled` | `false` | Master on/off switch (via `enable_system/0`) |
| `publishing_public_enabled` | `true` | Serve public routes |
| `publishing_default_language_no_prefix` | `false` | Omit the locale prefix from the default-language public URL (e.g. `/blog` instead of `/en/blog`). Prefixed requests 301-redirect to the canonical prefixless form |
| `publishing_posts_per_page` | `20` | Listing pagination size |
| `publishing_memory_cache_enabled` | `true` | Toggle the listing cache |
| `publishing_render_cache_enabled` | `true` | Toggle the Markdown render cache (global) |
| `publishing_render_cache_enabled_<slug>` | `true` | Per-group override for the render cache |
| `publishing_show_language_switcher` | `true` | Render the in-page language switcher on listing + post pages. Disable when the host layout already provides one (see "Language switcher integration" below) |
| `publishing_render_og_tags` | `true` | Render OpenGraph + Twitter Card meta tags **in-page** (inside the public body) so social previews work even when the host root layout doesn't render the forwarded `:og` assign in `<head>`. Disable when the host renders `:og` in `<head>` itself, to avoid duplicate tags (see "OpenGraph metadata" below) |
| `publishing_feeds_enabled` | `true` | Serve an RSS 2.0 feed per group at `/<group>/feed.xml` (localized variants too; newest 50 published posts for the requested language). `feed.xml` is a reserved tail segment in `Routing.parse_path/1`. Off → feed URLs 404 (never the smart fallback — a feed URL must not redirect to HTML). Canonical-prefix 301s ARE emitted feed-to-feed (a redundantly-prefixed default-language feed URL 301s to its prefixless twin), matching the `rel="self"` link |
| `publishing_render_jsonld` | `true` | Emit a schema.org `Article` JSON-LD script in-page on post pages (same body-placement rationale as the OG tags; built from the same refined `:og` map). `escape: :html_safe` on the encode so no value can close the script tag early |

### Per-group display settings (group `data` JSONB)

Distinct from the site-wide keys above: each group carries ~22 display settings
in its `data` JSONB (scrollbar style, featured posts, the latest-post band,
scroll rails, post width, reading time, tags, post count, top back link,
clickable card images, etc.), edited on
`/admin/publishing/edit-group/:slug` and applied via
`Publishing.update_group(slug, params, opts)`. All default off/neutral, so a
fresh group's public pages look unchanged until an admin opts in — with these
nuances: `featured_enabled` defaults **true** (inert until a post is actually
flagged featured in the editor, so still visually neutral); the
breadcrumbs + post-count elements used to render unconditionally pre-settings,
so groups that had them now need `show_breadcrumbs` / `show_post_count` turned
on (a deliberate default-off migration, not a regression); and
`show_top_back_link` + `listing_image_links` default **true** (deliberate
default-on features — the subtle top "Back to <group>" link on post pages and
the card images clicking through to the post; the settings exist to turn them
off per group). `newest_enabled` (+ `newest_layout`, hero/card) is default-off:
when on, the chronologically newest post is pulled out of the grid into its own
"Latest" band under any featured posts (a featured newest post stays in the
Featured band — Latest takes the next-newest; `split_newest/2` in
`controller/listing.ex`). `listing_animations` (default on) owns every card
hover effect (the 4px motion-safe lift + shadow/image transitions) — off
renders fully static cards. Both bands also carry a **style** key
(`featured_style` / `newest_style`: `classic | cover | cover_panel | minimal |
top`, default `classic`) orthogonal to the layout — layout is size/placement
(hero band vs card in the 2-col grid), style is paint. `cover` = the featured
image as the card background under a HARDCODED gradient scrim with fixed light
text (a real lazy `<img>` layer, not a CSS background; no image → a branded
primary/secondary gradient banner, secondary-leaning for Latest);
`cover_panel` = image with an opaque `bg-base-100/95` text panel (the
a11y-safe cover); `minimal` = text-only accent-border editorial band; `top` =
16:9 banner above the text. Dispatch lives in `html.ex`'s
`listing_band_card/1` — `classic`/unknown delegates to the original
`listing_post_card` variants, so pre-styles groups render unchanged. Scrim
strength, band height, and text placement are deliberately hardcoded (5-AI
panel consensus: good defaults over option bloat).

**Admin post-status classification** (2026-07-21; title added 2026-07-27):
the admin group page shows each post by its LIVE state —
`list_posts_with_metadata` passes `:effective_status`,
`:effective_published_at`, AND `:effective_title` overrides (all read from
the ACTIVE published version, the same rule the public
`list_posts_for_listing` applies) — while still mapping the LATEST version
for editing context. Deliberate split: `metadata.status`/`title`/publish
date are the card-level truth (what readers see), the
per-language/per-version maps stay version-accurate so the editor lands on
the newest draft. Versions are an ARCHIVAL
tool here (retain old legal text, branch a rewrite) — do not surface
"unpublished edits" style pending-work flags in listings (boss call).

**Group-name AI translation**: a second `PhoenixKitAI.Translatable` adapter,
`PhoenixKitPublishing.GroupAITranslatable` (`resource_type "publishing_group"`,
uuid-keyed — the public group map exposes `"uuid"` for this). One field
(`{{name}}`), merged into `data["name_i18n"]` under a `FOR UPDATE` row lock
(all languages share one JSONB — sibling-safe), audit row
`publishing.group.updated` (mode `"auto"`, `source: "ai_translation"`), NO
per-merge `:group_updated` broadcast (see `log_translated/3`). The Edit Group
LV wires it via `AITranslate.Embed` + `FormGlue` with a params-map
`GroupAITranslateBinding` (deliberately not `@behaviour` — the callbacks type
an Ecto changeset). The editor imports `ai_multilang_tabs/1` directly —
shipped in phoenix_kit_ai **0.17.0** (2026-07-21), and the mix.exs floor is
`~> 0.17` accordingly. (The interim forward-compat dodge that let 0.4.3 build
against 0.16.0 was dropped once the release landed.)

Two write-path behaviors to know: `update_group/3` is **lenient** (an
out-of-whitelist enum value is ignored, a non-truthy bool becomes `false` — the
admin-form path can't fail on settings), while `validate_group_settings/1` is
**strict** (returns per-key errors) — programmatic callers should validate
first if they want feedback. `name_i18n` overrides are hardened at merge:
non-binary values (nested maps from crafted params) are dropped, and each
override is capped to `Constants.max_group_name_length()`.

**Host contract for the scroll aids** (scrollbar restyle, reading-progress
bar, heading rail, timeline rail): they ship as self-contained inline
`<style>`/`<script>` blocks in the public templates (dead views — full page
loads, no LiveView). Two consequences: (1) a host with a strict CSP (no
`'unsafe-inline'`) silently loses them — the pages still render fine without
them; (2) the scroll math reads `document.documentElement` / `window.scrollY`,
so the **window must be the scroll owner** — a host app-shell that scrolls an
inner `overflow-y-auto` container instead of the body disables the aids
(progress bar never fills, rails hide/stall). The rails' month labels +
aria-labels localize via `data-months`/`data-label` on the hidden config
elements (`#pk-timeline-config`, `#pk-headings-config`) — the JS falls back to
English when absent. The timeline rail bins cards by `data-post-date`, which
carries the same *effective* publish date the listing sorts by
(`effective_post_date/1` in `web/html.ex` mirrors `Listing.listing_sort_key/1`
— don't let the two drift). Known limit: the listing (and so `oldest` sort)
runs over the listing cache, which caps at the most recent 5,000 posts.

`PhoenixKit.Modules.Publishing.GroupSettings` is the **machine-readable spec**
of those settings — for AI/agent/MCP/script-driven configuration without the UI:

- `Publishing.group_settings_schema/0` — list of `%{key, type, allowed, default, scope, label, description, depends_on}` (values/defaults derived from `Constants`, so it can't drift from what `update_group/3` accepts).
- `Publishing.group_settings_defaults/0` / `group_settings_keys/0`.
- `Publishing.validate_group_settings/1` — casts/validates a proposed params map, returning `{:ok, normalized}` (booleans + enums coerced, unknown keys like `name`/`slug` passed through) or `{:error, [%{key:, reason:}]}`. Feed the `:ok` result straight to `update_group/3`.

The accessor + default source of truth for each setting is the `PublishingGroup`
schema moduledoc; add a new setting in `Constants` → `publishing_group.ex`
accessor → `groups.ex` (`merge_group_config` + `db_group_to_map`) → `edit.ex`
form → `group_settings.ex` spec (its test asserts the key set matches
`merge_group_config`).

### Translatable group name

The group's **display name** is translatable per language via the core
`PhoenixKitWeb.Components.MultilangForm` tabs on the edit page. The
primary-language name stays in the `name` column; per-language overrides live in
an isolated `data["name_i18n"]` map (`%{lang => name}`) — NOT the multilang
helper's `data`-owning convention, which would clobber the settings above. The
**slug is intentionally not translated** (single canonical URL). Public pages
resolve the name via `Publishing.translated_group_name(group_map, lang)` /
`PublishingGroup.translated_name/2`, which is base-language tolerant (the form
stores the full code `fr-FR`, the public side asks by the short code `fr`).
Every public surface that shows a group name resolves through it: the listing
h1 / page title / OG title / breadcrumb, the post page's breadcrumb + "Back
to …" footer (via `PostRendering.fetch_group/1` + `resolve_group_name/3` — the
same fetched group map also feeds the controller's
`assign_group_display_config/2`, one fetch per request), and the feed channel
title. (The all-groups overview cards were deleted with the template in
2026-08 — see the Routing section.) Admin surfaces intentionally show the
canonical primary-language name. `display_settings_render_test.exs` pins the
reach.

## Comments (optional seam)

`PhoenixKit.Modules.Publishing.Comments` is a guarded seam to the optional
`phoenix_kit_comments` package (same posture as the `phoenix_kit_og` seam —
no dep in mix.exs except `only: :test`; every call `Code.ensure_loaded?` +
rescued). When the module is installed AND enabled AND a group's
`comments_enabled` setting is on, post pages render a dead-view comment
thread (`resource_type "publishing_post"`, sanitized markdown via the
comments module's renderer) and a plain POST form — Phoenix-first, no JS.
Submission rides new POST routes in core's publishing dispatch scope
(method-agnostic rewrite) to `Controller.create_comment/2`, guarded in
order: module/public/group gates → honeypot (`website` field; filled =
pretend success) → signed time-trap (`Phoenix.Token`, 3s–1day window) →
post-in-published-set check → logged-in user. Every outcome redirects back
with a flash. **Logged-in only for now** — the comments schema
`validate_required`s `user_uuid`; guest commenting is a cross-repo
follow-up (nullable user + author fields in BeamLab's comments module).
Moderation uses the comments module's own admin (statuses + bulk updates);
a publishing-scoped moderation surface is a follow-up.

## Language switcher integration

Publishing renders an in-page language switcher on group-listing and post pages by default. Most host apps already have one in their header, in which case the in-page switcher is duplicate UI. Three integration points:

1. **`publishing_show_language_switcher` setting** (default `true`) — flip to `false` in `/admin/settings/publishing` to suppress the in-page switcher. The host layout is then responsible for rendering its own.

2. **`:phoenix_kit_publishing_translations` conn assign** — the public API contract for external switchers. Always set on listing + post conns (regardless of the setting above) as a list of maps with exactly these five fields: `%{code: <display_code>, name: <language_name>, flag: <flag_emoji_or_"">, url: <full_url>, current: <bool>}`. Same fields on listing and post routes — the controller normalises at the boundary, stripping internal-only fields (`display_code`, and on post routes `enabled`/`known`) so external consumers get a uniform shape. Custom switchers iterate this list directly.

3. **Core's `<.language_switcher_dropdown>` integration** — the host's root layout passes the assign via the new `:per_translation_urls` attr:

   ```heex
   <PhoenixKitWeb.Components.Core.LanguageSwitcher.language_switcher_dropdown
     current_locale={@current_locale}
     current_path={@url_path}
     per_translation_urls={assigns[:phoenix_kit_publishing_translations]}
   />
   ```

   When the assign is present, the switcher uses publishing's per-translation URLs (important for groups with per-language URL slugs where simple locale-rewrite produces wrong URLs). When absent (non-publishing pages), the switcher falls back to the locale-rewrite default. Languages without a publishing translation also fall back per-language.

Per-translation URLs are exposed regardless of `publishing_show_language_switcher`, so the host can render them whether the in-page switcher is on or off.

### ⚠️ Function-component layouts ONLY see declared attrs

`:phoenix_kit_publishing_translations` is set on `conn.assigns` by the controller. The assign reaches `root.html.heex` (a plain Phoenix template), but **NOT** inner function-component layouts (`<.app_layout>`, the host's `Layouts.app`) unless every wrapper component along the path declares the attr and forwards it explicitly. Phoenix 1.7+ function-components see only declared attrs, not surrounding `conn.assigns`.

Today's forwarding chain:

1. Controller sets `conn.assigns[:phoenix_kit_publishing_translations]` (in `Web.Controller`).
2. Publishing's public render branches (`index/1`, `show/1` in `Web.HTML`) pass it via the module-agnostic `module_assigns={%{phoenix_kit_publishing_translations: assigns[:phoenix_kit_publishing_translations]}}` to `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>`.
3. `LayoutWrapper.app_layout` (in phoenix_kit core) declares the generic `:module_assigns` map attr and merges its keys into the top-level assigns before invoking the host's `Layouts.app/1`.

Why the generic `:module_assigns` map instead of a specific attr per module: function-component attrs must be declared in advance, and we don't want phoenix_kit core to carry a hard-coded list of every external module's host-consumable keys. The single map attribute lets each module thread its own keys through without core touching the API.

If the host consumes the assign from `root.html.heex`, the forwarding chain is irrelevant. If the host consumes it from `Layouts.app/1` (the typical custom-switcher placement), all three steps must hold. The boundary test in `test/phoenix_kit_publishing/web/controller/language_switcher_exposure_test.exs` ("host-integration boundary" describe) pins the full chain by rendering through the test `Layouts.app/1` and comparing `length(conn.assigns[...])` to the rendered nav's `data-count`.

## OpenGraph metadata (`:og` conn assign)

Publishing assigns a `:og` map on every public response for host root layouts to render `<meta property="og:...">` tags. Two shapes:

- **Listing pages** — `%{title, url, locale, type: "website"}` (4 fields).
- **Post pages** — `%{title, description, image, url, locale, type: "article"}`, plus up to three `og:image:*` hint fields (`image_width`, `image_height`, `image_type`) added by `maybe_put` when the resolved image has known variant dimensions/mime — so 6–9 fields. `description` and `image` may be `nil` when the post has no SEO metadata or featured image.

`:og` lands on `conn.assigns` AND is forwarded through `LayoutWrapper.app_layout`'s `:module_assigns` map, so hosts can consume it from either `root.html.heex` (the conn assign) OR `Layouts.app/1` (the forwarded `@og` assign). The forwarding happens in publishing's public render branches (`index/1`, `show/1` in `Web.HTML`) the same way `:phoenix_kit_publishing_translations` does — see the function-component-layout callout above for the boundary mechanism.

### Automatic in-page rendering (default on)

Meta tags belong in `<head>`, which the **host app owns** — and most hosts ship their own `root.html.heex` that doesn't render the forwarded `:og`, so relying on the host alone left previews broken. So publishing **also renders the og/twitter tags itself**, in-page, via `Web.HTML.og_meta_tags/1` (rendered as the first child inside `LayoutWrapper.app_layout` in all three public branches). This mirrors the in-page language switcher: it works out of the box with zero host setup. Body placement is read by the major scrapers (FB/Slack/Discord/Telegram/LinkedIn); `<head>` is still the strict-standard location, which is what the `module_assigns` pass-along is for.

The `publishing_render_og_tags` setting (default `true`) gates the in-page copy. A host that renders the forwarded `:og` in its own `<head>` (e.g. via core's `root.html.heex`, which renders the full og+twitter+canonical block) should flip it **off** from `/admin/settings/publishing` to avoid duplicate tags. The setting is read per-request in `og_tags_enabled?/0` — it is **not** part of the Markdown render cache (that caches post-body HTML only), so toggling takes effect immediately. The component renders nothing when `:og` is absent (e.g. the groups overview).

### How the post-page `:og` map is built (overrides + `phoenix_kit_og`)

`build_og_data/4` (`web/controller.ex`) resolves each field through three layers, highest precedence last:

1. **Derived defaults** — post title, version description, effective featured image.
2. **Per-post simple override** — per-language `content.data["og"] = %{"title", "description", "image_uuid"}`, edited in the "Social / OpenGraph" section of the post editor. Each field falls back independently to the default. Read by `PublishingContent.get_og/1`, surfaced as `post.metadata.og` by the mapper.
3. **`phoenix_kit_og` plugin (optional)** — renders an OG image from an admin-designed template and gets the final say on `image`. Publishing is its first consumer: it implements `og_variables/0` + `og_resolve/2` (in `publishing.ex`) declaring/resolving the template variables (`post_title`, `post_featured_image`, `post_group_name`, `post_first_words`, …), and `build_og_data/4` ends by calling `maybe_refine_og_with_module/4` → `PhoenixKitOG.refine_og/4`. The seam is fully guarded (`Code.ensure_loaded?` + `function_exported?` + `rescue`), so a host without the plugin — or one whose refine call raises — falls back to the override/default map unchanged. The editor shows a live "what the plugin will produce" preview via `PhoenixKitOG.preview_og_image_url/3` (`og_preview_url/2` in `web/editor.ex`), gated on `PhoenixKitOG.enabled?/0`.

## Testing

Integration tests live in `test/phoenix_kit_publishing/integration/` and controller tests in `test/phoenix_kit_publishing/web/controller/`. Both need a PostgreSQL database — automatically excluded when unavailable.

```bash
createdb phoenix_kit_publishing_test      # first-time setup
mix test                                  # full suite
mix test --only integration               # DB-backed tests only
```

### Controller integration tests

`phoenix_kit_publishing` has no endpoint of its own in production — the host app provides one. For controller tests we ship a tiny test endpoint + router + layouts under `test/support/`:

- `PhoenixKitPublishing.Test.Endpoint` — minimal `Phoenix.Endpoint` with a `Phoenix.LiveView.Socket` so LV tests work too
- `PhoenixKitPublishing.Test.Router` — routes matching `Web.Controller.show/2`, plus admin LV routes wrapped in `live_session :admin_publishing` (and `:admin_publishing_settings`) with the `:assign_scope` on_mount hook
- `PhoenixKitPublishing.Test.Layouts` — minimal root + parent layout stand-in. **`Layouts.app/1` renders flash divs** (`#flash-info`, `#flash-error`, `#flash-warning`) so LV tests can assert flash content via `render(view) =~ "..."`
- `PhoenixKitPublishing.Test.Hooks` — `:assign_scope` `on_mount` hook that pulls `phoenix_kit_test_scope` out of the session (set via `LiveCase.put_test_scope/2`) and assigns `:phoenix_kit_current_scope` / `:phoenix_kit_current_user` / `:current_locale_base` / `:current_locale` / `:url_path` onto the socket — mirrors what core's auth hook does in production
- `PhoenixKitPublishing.ConnCase` — ExUnit case template for controller tests; sandbox checkout + `with_scope/1` helper
- `PhoenixKitPublishing.LiveCase` — ExUnit case template for LV smoke tests; sandbox in shared mode, `put_test_scope/2`, `fake_scope/1` helper
- `PhoenixKitPublishing.ActivityLogAssertions` — `assert_activity_logged/2`, `refute_activity_logged/2`, `list_activities/0`. Imported into both DataCase and LiveCase. Queries `phoenix_kit_activities` directly via raw SQL; normalises Postgres's 16-byte UUIDs against the string UUIDs callers pass

`config/test.exs` points `PhoenixKit.Config :layout` at the test layouts so `LayoutWrapper.app_layout` doesn't fall back to `PhoenixKitWeb.Layouts.root` (which requires `PhoenixKitWeb.Endpoint`). Reference tests:
- Controller: `test/phoenix_kit_publishing/web/controller/show_layout_test.exs`
- LiveView smoke: `test/phoenix_kit_publishing/web/settings_live_test.exs`
- Activity log assertions: `test/phoenix_kit_publishing/integration/activity_logging_test.exs`

`test_helper.exs` creates a minimal `phoenix_kit_activities` table that mirrors core's V90 migration so `PhoenixKit.Activity.log/1` INSERTs land cleanly instead of poisoning the sandbox transaction with `relation does not exist`.

## Pre-commit Commands

Always run before committing:

```bash
mix precommit      # compile + format + credo --strict + dialyzer
```

## Tailwind CSS Scanning

This module implements `css_sources/0` returning `[:phoenix_kit_publishing]` so PhoenixKit's installer adds the correct `@source` directive to the parent's `app.css`. Without this, Tailwind purges CSS classes unique to this module's templates.

## Versioning & Releases

### Tagging & GitHub releases

Tags use a **`v` prefix** (`git tag --sort=v:refname` is the source of
truth — every tag from `v0.1.6` on uses it; only the two earliest,
`0.1.1`/`0.1.3`, predate the switch from bare numbers):

```bash
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin v0.1.0
```

GitHub releases lapsed between `v0.1.7` (2026-05-05) and `v0.4.4`, and
`0.4.5`/`0.4.6` were backfilled on 2026-08-04 — so **`v0.4.4` onward all
have a `gh release`; `v0.1.8`–`v0.4.3` do not.** Keep the streak going.
Use the tag as the release name, title `<version> - <date>` (the release
date from `CHANGELOG.md`, not today's), and the body copied from that
version's `CHANGELOG.md` section:

```bash
# Extract the section, then create the release from it.
awk '/^## 0\.4\.7 /{f=1;next} /^## 0\.4\.6 /{f=0} f' CHANGELOG.md > /tmp/notes.md
gh release create v0.4.7 --title "0.4.7 - 2026-08-04" --notes-file /tmp/notes.md
```

Pass `--latest=false` when **backfilling an older version** — `gh` otherwise
marks the newest-created release as Latest, which would demote the current
one.

### Full release checklist

Two version sources must move together — `mix.exs`'s `@version` and
`Publishing.version/0` in `lib/phoenix_kit_publishing/publishing.ex`.
Nothing pins them to each other (`facade_callbacks_test.exs` only asserts
`is_binary`), so a missed one goes unnoticed: `version/0` sat at `0.4.5`
through the entire `0.4.6` release. **Grep both before committing.**

1. Update the version in `mix.exs` (`@version`) AND `Publishing.version/0`
2. Add a changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Update version to x.y.z"`
5. Push to main and **verify the push succeeded**
6. Publish to Hex: `mix hex.publish --yes`
7. Create and push the git tag: `git tag -a vx.y.z -m "Release x.y.z" && git push origin vx.y.z`
8. Create the GitHub release (see the command above)

**IMPORTANT:** The order is commit → push → **publish → then tag**. Never
tag before a successful `mix hex.publish`: tags are immutable pointers, and
tagging first leaves a tag for a release that may never exist. Equally,
never tag before pushing — the tag would point at the wrong commit.

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). See `dev_docs/pull_requests/README.md`.

## External Dependencies

- **PhoenixKit** (`~> 1.7.189`) — Module behaviour, Settings API, shared components, RepoHelper
- **PhoenixKitAI** (`~> 0.17`) — the AI-translation pipeline lives here (moved out of core): the
  `PhoenixKitAI.Translatable` adapter behaviour (publishing's `AITranslatable` implements it),
  `PhoenixKitAI.{Translations,TranslateWorker,Translation}`, and the `AITranslate` modal UI. The
  per-language Oban fan-out + the LLM call (`PhoenixKitAI.ask_with_prompt/4`, OpenRouter) are owned
  by this plugin; publishing only contributes the adapter + editor wiring.
- **Leaf** (`~> 0.4.1 or ~> 0.5`) — the post editor. The 0.4.1 floor is
  load-bearing (inline suggestions + `:flush`); the range is deliberately
  **not** `~> 0.4.1`, which reads as `< 0.5.0` and silently held hosts a
  release behind because phoenix_kit core declares `~> 0.3` and resolves to
  leaf 0.5.x. Don't re-tighten it — see the 0.4.6 changelog entry
- **Phoenix LiveView** (`~> 1.0`) — Admin LiveViews
- **MDEx** (`~> 0.13`) — Markdown rendering (comrak, GFM)
- **Saxy** (`~> 1.5`) — XML parsing for PHK page builder components
- **Oban** (`~> 2.18`) — Background translation and migration workers
- **Gettext** (`~> 1.0`) — this module's own `PhoenixKitPublishing.Gettext`
  backend + `priv/gettext` catalogues (en, et, fr, it, ru)
- **PhoenixKitComments** (`~> 0.2`, `only: :test`) — exercises the OPTIONAL
  comments seam. Production installs opt in by adding it themselves
- **Req** (via PhoenixKit) — HTTP client for AI translation
- **Jason** (via PhoenixKit) — JSON encoding/decoding

## Two Module Types

Publishing is a **full-featured** module: admin tabs, route module, DB-backed schemas, settings, public Controller, Oban workers, real-time Presence/PubSub, multi-layer caching. The contrasting **headless** type (functions/API only, no UI) still gets auto-discovery, toggles, and permissions — see `phoenix_kit_ai` for that shape.

## What This Module Does NOT Have

Deliberate non-features — surfacing here so future contributors don't try to add them under the assumption they were missed:

- **No HTML sanitiser on Markdown output.** `Renderer` calls MDEx with `render: [unsafe: true]` so admin-authored `<div class="grid">` / inline HTML / `<script>` tags pass through (GFM `tagfilter` is deliberately left off). The trust boundary is "only admins author content"; if untrusted input ever reaches `render_markdown/1` (API import, AI prompt-injection on rotating roles), wire `html_sanitize_ex` in front of it. See `render_markdown_html/1` in `renderer.ex`.
- **No outbound HTTP from this module.** AI translation dispatches via `phoenix_kit_ai` which owns the `Req` boundary (and its SSRF allowlist). If a future feature adds direct HTTP calls, the Req.Test-via-app-config pattern (see workspace AGENTS.md "Coverage push pattern #6") is the canonical retrofit.
- **No per-language Mailer or webhook delivery.** Publishing exposes posts via the public Controller; subscriptions / notifications are Newsletters / Emails territory.
- **No retry layer on AI translation failures.** `TranslationManager` returns `{:error, {:ai_translation_failed, reason}}` on the first failure; the user retries from the UI. Oban-backed retries would need backoff + actor attribution — out of scope.
- **No editor-side conflict resolution beyond owner/spectator locking.** Two admins editing the same post in different tabs see Presence-driven indicators and the spectator's writes are blocked at the form level. There is no merge-on-conflict UX.
- **No client-side undo stack.** Versions are the undo mechanism — every save creates an audit trail in `phoenix_kit_publishing_versions`.
- **No frontend bundle.** Tailwind/daisyUI classes are emitted by the renderer; the host app's `app.css` includes `@source` for `phoenix_kit_publishing` via the installer.

## TODOs

Workspace-tracked items surfaced by reviewers / triage agents that didn't make the immediate fix batch but are worth picking up. Each has a clear scope; ordered roughly by impact.

- **Multi-tab sync flicker in `collaborative.ex:168`.** Same user with two tabs of the same post AND a concurrent spectator → both owner tabs respond to the spectator's initial sync; the spectator's view flickers once and settles. Owner tabs stay consistent and no data is lost — it's a UX glitch with narrow trigger conditions, but the fix (elect one tab as primary-sync-responder via socket_id ordering, route sync responses through it) is mechanical once the design call is made. Needs its own PR with a dedicated test that mounts two LV processes for the same user and asserts only one responds.
- **Centralize the `"published"` status string** (~75 occurrences across `db_storage.ex`, `stale_fixer.ex`, `versions.ex`, controllers, LVs, …). Move to `Constants.status_published/0` or similar. Best done with `ast-grep` to catch every occurrence in one pass; the "missed one of 75 sites" risk is real if done by hand. Low practical urgency (the value hasn't changed and won't without a DB migration), but the moment it DOES need to change, having the constant in place saves the change from being a 75-site grep-and-pray.
- **Preview-tab loading indicator** (`web/preview.ex`). Markdown rendering can be slow for large PHK XML; pushing a `phx-update="ignore"` skeleton or a `phx-disable-with`-style placeholder before `render_markdown_content/1` returns would smooth the perceived hang. Trivial once we have a benchmark showing it matters.
- **Translation button immediate-disable** in the editor. `phx-disable-with` covers most cases; the residual risk is double-enqueue on very slow networks before the server's `ai_translation_status` assign comes back. A small JS hook that disables the button on click (before the round-trip) closes that gap.
