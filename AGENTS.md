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

- **`Publishing.Renderer`** (`lib/phoenix_kit_publishing/renderer.ex`) — Markdown→HTML via Earmark with ETS caching (6hr TTL). Detects and renders inline PHK components.

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
├── renderer.ex                # Earmark + ETS render cache (6h TTL)
├── page_builder.ex            # Saxy XML parser for PHK components
├── page_builder/              # Per-component renderers (Image, Hero, CTA, ...)
├── metadata.ex                # YAML frontmatter parsing helpers
├── schemas/                   # 4 Ecto schemas (group, post, version, content)
├── web/                       # 8 admin LiveViews + Controller + HTML templates
├── workers/                   # Oban background jobs (translate worker)
└── migrations/                # Standalone consolidated migration (reference)
```

### Database Tables

All 4 tables use UUIDv7 primary keys. **Migrations live in phoenix_kit core** (versioned system, currently V88). The publishing package includes a consolidated standalone migration (`lib/phoenix_kit_publishing/migrations/publishing_tables.ex`) for reference/independent installs.

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

## Routing: Single Page vs Multi-Page

> ⚠️ **Never hand-register plugin LiveView routes in the parent app's `router.ex`.** PhoenixKit injects module routes into its own `live_session :phoenix_kit_admin` automatically. A hand-written route sits outside that session, which (a) loses the admin layout — `:phoenix_kit_ensure_admin` only applies it inside the session — and (b) crashes the socket on navigation between admin pages (`navigate event failed because you are redirecting across live_sessions`).

Publishing uses the **route module** pattern via `Publishing.Routes`. Both `admin_locale_routes/0` and `admin_routes/0` declare every admin LiveView path (the localized variant gets `:locale` segment + `_localized` `:as` aliases). Tabs in `admin_tabs/0` carry only the parent-level Publishing entry; per-page routes come from the route module so we can express the full Listing/Editor/Preview/PostShow tree (including dynamic `:group` / `:post_uuid` segments) without enumerating each as a `Tab` struct.

Public routes (the Controller's `show/2`, `index/2`, `all_groups/2`) live in `Publishing.Routes.public_routes/1` — NOT in `generate/1`. Catch-all paths must go in `public_routes/1` because routes in `generate/1` are placed early and would intercept `/admin/*` paths.

The `regex` constraint on `:group` (`~r/^(?!admin$|assets$|images$|fonts$|js$|css$|favicon)/`) prevents the `/:group/*path` catch-all from swallowing assets and admin URLs.

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

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.0
git push origin 0.1.0
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.0 \
  --title "0.1.0 - 2026-03-25" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs`, `lib/phoenix_kit_publishing/publishing.ex` (`version/0`), and the version test
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). See `dev_docs/pull_requests/README.md`.

## External Dependencies

- **PhoenixKit** (`~> 1.7`) — Module behaviour, Settings API, shared components, RepoHelper
- **PhoenixKitAI** (`~> 0.1`) — AI translation dispatch (OpenRouter via core's `AI.ask_with_prompt/4`)
- **Phoenix LiveView** (`~> 1.0`) — Admin LiveViews
- **Earmark** (`~> 1.4`) — Markdown rendering (GFM)
- **Saxy** (`~> 1.5`) — XML parsing for PHK page builder components
- **Oban** (`~> 2.18`) — Background translation and migration workers
- **Req** (via PhoenixKit) — HTTP client for AI translation
- **Jason** (via PhoenixKit) — JSON encoding/decoding

## Two Module Types

Publishing is a **full-featured** module: admin tabs, route module, DB-backed schemas, settings, public Controller, Oban workers, real-time Presence/PubSub, multi-layer caching. The contrasting **headless** type (functions/API only, no UI) still gets auto-discovery, toggles, and permissions — see `phoenix_kit_ai` for that shape.

## What This Module Does NOT Have

Deliberate non-features — surfacing here so future contributors don't try to add them under the assumption they were missed:

- **No HTML sanitiser on Markdown output.** `Renderer` calls Earmark with `escape: false` so admin-authored `<div class="grid">` / inline HTML / `<script>` tags pass through. The trust boundary is "only admins author content"; if untrusted input ever reaches `render_markdown/1` (API import, AI prompt-injection on rotating roles), wire `html_sanitize_ex` in front of it. See `renderer.ex:201-209`.
- **No outbound HTTP from this module.** AI translation dispatches via `phoenix_kit_ai` which owns the `Req` boundary (and its SSRF allowlist). If a future feature adds direct HTTP calls, the Req.Test-via-app-config pattern (see workspace AGENTS.md "Coverage push pattern #6") is the canonical retrofit.
- **No per-language Mailer or webhook delivery.** Publishing exposes posts via the public Controller; subscriptions / notifications are Newsletters / Emails territory.
- **No retry layer on AI translation failures.** `TranslationManager` returns `{:error, {:ai_translation_failed, reason}}` on the first failure; the user retries from the UI. Oban-backed retries would need backoff + actor attribution — out of scope.
- **No editor-side conflict resolution beyond owner/spectator locking.** Two admins editing the same post in different tabs see Presence-driven indicators and the spectator's writes are blocked at the form level. There is no merge-on-conflict UX.
- **No client-side undo stack.** Versions are the undo mechanism — every save creates an audit trail in `phoenix_kit_publishing_versions`.
- **No frontend bundle.** Tailwind/daisyUI classes are emitted by the renderer; the host app's `app.css` includes `@source` for `phoenix_kit_publishing` via the installer.
