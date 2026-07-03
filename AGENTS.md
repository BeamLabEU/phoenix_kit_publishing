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

- **`Publishing.ListingCache`** (`lib/phoenix_kit_publishing/listing_cache.ex`) — `:persistent_term` cache (~0.1us reads) for post metadata. Invalidated on mutations.

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
- **Public URL building** — always go through `PublishingHTML.group_listing_path/3` / `build_post_url/4` / `build_public_path_with_time/4`; never hand-roll prefix logic in admin templates (see Issue #7)
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

Public routes (the Controller's `show/2`, `index/2`, `all_groups/2`) historically lived in `Publishing.Routes.public_routes/1`. **As of the routing-strategy change** that function returns an empty AST — public dispatch now routes through `PhoenixKitPublishing.RouterDispatch` (see "Public dispatch" below).

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
| `publishing.content.merged` | Legacy and dialect rows for the same version merged by `StaleFixer` | `publishing_content` |
| `publishing.content.promoted` | Legacy base-code row promoted in place when the admin adds the corresponding dialect translation | `publishing_content` |
| `publishing.content.metadata_promoted` | Legacy V1 content.data keys (`description`, `featured_image_uuid`, `seo_title`, `excerpt`) promoted to `version.data` on first edit so the V2 whitelist (`previous_url_slugs`, `updated_by_uuid`, `custom_css`) can wipe content.data without losing the value. Metadata: `language`, `version_uuid`, `promoted_keys`. Self-healing — runs at most once per legacy row | `publishing_content` |

All four run with `mode: "auto"` and no `actor_uuid` — they're system-triggered, not user-initiated. Metadata includes `from_language`/`to_language`/`version_uuid`.

### User-driven CRUD events

Every mutating context function in Posts / Groups / Versions / TranslationManager logs a corresponding `mode: "manual"` row via `ActivityLog.log_manual/5`. The full list:

| action | resource_type |
|--------|---------------|
| `publishing.post.created` | `publishing_post` |
| `publishing.post.updated` | `publishing_post` |
| `publishing.post.trashed` | `publishing_post` |
| `publishing.post.restored` | `publishing_post` |
| `publishing.post.unpublished` | `publishing_post` |
| `publishing.group.created` | `publishing_group` |
| `publishing.group.updated` | `publishing_group` |
| `publishing.group.trashed` | `publishing_group` |
| `publishing.group.restored` | `publishing_group` |
| `publishing.group.deleted` | `publishing_group` |
| `publishing.version.created` | `publishing_version` |
| `publishing.version.published` | `publishing_version` |
| `publishing.version.deleted` | `publishing_version` |
| `publishing.translation.added` | `publishing_content` |
| `publishing.translation.deleted` | `publishing_content` |
| `publishing.module.enabled` | `publishing_module` |
| `publishing.module.disabled` | `publishing_module` |

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

`PhoenixKit.Modules.Publishing.Errors` is the central atom→user-facing-string dispatcher. Every public-API error tuple in the module either returns one of the documented atoms (`@type error_atom` lists 36 of them) or one of four tagged tuples (`{:ai_translation_failed, _}`, `{:ai_extract_failed, _}`, `{:ai_request_failed, _}`, `{:source_post_read_failed, _}`). UI flash messages call `Errors.message/1` to translate via `gettext/1` from the `PhoenixKitWeb.Gettext` backend — keep the API layer locale-agnostic; let the UI decide presentation.

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
2. Publishing's three public render branches (`all_groups/1`, `index/1`, `show/1` in `Web.HTML`) pass it via the module-agnostic `module_assigns={%{phoenix_kit_publishing_translations: assigns[:phoenix_kit_publishing_translations]}}` to `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>`.
3. `LayoutWrapper.app_layout` (in phoenix_kit core) declares the generic `:module_assigns` map attr and merges its keys into the top-level assigns before invoking the host's `Layouts.app/1`.

Why the generic `:module_assigns` map instead of a specific attr per module: function-component attrs must be declared in advance, and we don't want phoenix_kit core to carry a hard-coded list of every external module's host-consumable keys. The single map attribute lets each module thread its own keys through without core touching the API.

If the host consumes the assign from `root.html.heex`, the forwarding chain is irrelevant. If the host consumes it from `Layouts.app/1` (the typical custom-switcher placement), all three steps must hold. The boundary test in `test/phoenix_kit_publishing/web/controller/language_switcher_exposure_test.exs` ("host-integration boundary" describe) pins the full chain by rendering through the test `Layouts.app/1` and comparing `length(conn.assigns[...])` to the rendered nav's `data-count`.

## OpenGraph metadata (`:og` conn assign)

Publishing assigns a `:og` map on every public response for host root layouts to render `<meta property="og:...">` tags. Two shapes:

- **Listing pages** — `%{title, url, locale, type: "website"}` (4 fields).
- **Post pages** — `%{title, description, image, url, locale, type: "article"}` (6 fields). `description` and `image` may be `nil` when the post has no SEO metadata or featured image.

`:og` lands on `conn.assigns` AND is forwarded through `LayoutWrapper.app_layout`'s `:module_assigns` map, so hosts can consume it from either `root.html.heex` (the conn assign) OR `Layouts.app/1` (the forwarded `@og` assign). The forwarding happens in publishing's three public render branches (`all_groups/1`, `index/1`, `show/1` in `Web.HTML`) the same way `:phoenix_kit_publishing_translations` does — see the function-component-layout callout above for the boundary mechanism.

### Automatic in-page rendering (default on)

Meta tags belong in `<head>`, which the **host app owns** — and most hosts ship their own `root.html.heex` that doesn't render the forwarded `:og`, so relying on the host alone left previews broken. So publishing **also renders the og/twitter tags itself**, in-page, via `Web.HTML.og_meta_tags/1` (rendered as the first child inside `LayoutWrapper.app_layout` in all three public branches). This mirrors the in-page language switcher: it works out of the box with zero host setup. Body placement is read by the major scrapers (FB/Slack/Discord/Telegram/LinkedIn); `<head>` is still the strict-standard location, which is what the `module_assigns` pass-along is for.

The `publishing_render_og_tags` setting (default `true`) gates the in-page copy. A host that renders the forwarded `:og` in its own `<head>` (e.g. via core's `root.html.heex`, which renders the full og+twitter+canonical block) should flip it **off** from `/admin/settings/publishing` to avoid duplicate tags. The setting is read per-request in `og_tags_enabled?/0` — it is **not** part of the Markdown render cache (that caches post-body HTML only), so toggling takes effect immediately. The component renders nothing when `:og` is absent (e.g. the groups overview).

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

Tags use a **`v` prefix** (`git ls-remote --tags` is the source of truth —
`v0.1.6` through `v0.2.3` all use it; only the earliest releases, `0.1.1`/
`0.1.3`, predate the switch to bare numbers):

```bash
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin v0.1.0
```

GitHub releases have lapsed since `v0.1.7` (2026-05-05) — `0.2.0`–`0.2.3`
were tagged and published to Hex but have no corresponding `gh release`.
When creating one, use `gh release create` with the tag as the release
name, title `<version> - <date>`, and body from the corresponding
`CHANGELOG.md` section:

```bash
gh release create v0.1.0 \
  --title "0.1.0 - 2026-03-25" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs`, `lib/phoenix_kit_publishing/publishing.ex` (`version/0`), and the version test
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag -a vx.y.z -m "Release x.y.z" && git push origin vx.y.z`
7. Create GitHub release (optional — see note above; skipped for the last several releases): `gh release create vx.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). See `dev_docs/pull_requests/README.md`.

## External Dependencies

- **PhoenixKit** (`~> 1.7.132`) — Module behaviour, Settings API, shared components, RepoHelper
- **PhoenixKitAI** (`~> 0.3`) — the AI-translation pipeline lives here (moved out of core): the
  `PhoenixKitAI.Translatable` adapter behaviour (publishing's `AITranslatable` implements it),
  `PhoenixKitAI.{Translations,TranslateWorker,Translation}`, and the `AITranslate` modal UI. The
  per-language Oban fan-out + the LLM call (`PhoenixKitAI.ask_with_prompt/4`, OpenRouter) are owned
  by this plugin; publishing only contributes the adapter + editor wiring.
- **Phoenix LiveView** (`~> 1.0`) — Admin LiveViews
- **MDEx** (`~> 0.13`) — Markdown rendering (comrak, GFM)
- **Saxy** (`~> 1.5`) — XML parsing for PHK page builder components
- **Oban** (`~> 2.18`) — Background translation and migration workers
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
