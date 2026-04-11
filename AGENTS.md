# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

PhoenixKit Publishing module — a database-backed CMS providing content groups, posts with versioning, multi-language support, collaborative editing, and dual URL modes (timestamp-based for blogs/news, slug-based for docs/evergreen). Implements the `PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix application.

## Common Commands

```bash
mix deps.get          # Install dependencies
mix test              # Run all tests
mix test test/phoenix_kit_publishing/unit_test.exs  # Run specific test file
mix test --only tag   # Run tests matching a tag
mix format            # Format code (imports Phoenix LiveView rules)
mix credo             # Static analysis / linting
mix dialyzer          # Type checking
mix docs              # Generate documentation
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
- **Phoenix LiveView** (`~> 1.0`) — Admin LiveViews
- **Earmark** (`~> 1.4`) — Markdown rendering (GFM)
- **Saxy** (`~> 1.5`) — XML parsing for PHK page builder components
- **Oban** (`~> 2.18`) — Background translation and migration workers
- **Req** (via PhoenixKit) — HTTP client for AI translation
- **Jason** (via PhoenixKit) — JSON encoding/decoding
