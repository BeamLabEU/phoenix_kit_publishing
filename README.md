# PhoenixKit Publishing

A standalone PhoenixKit plugin module that provides a database-backed content management system with multi-language support, collaborative editing, and dual URL modes.

## Installation

Add to your parent app's `mix.exs`:

```elixir
{:phoenix_kit_publishing, "~> 0.1.0"}
```

Or for local development:

```elixir
{:phoenix_kit_publishing, path: "../phoenix_kit_publishing"}
```

Then run `mix deps.get` and `mix phoenix_kit.install`. The module is auto-discovered by PhoenixKit at startup — no additional config needed. The installer also adds the necessary Tailwind CSS `@source` directive so all styles render correctly.

### Database Setup

The publishing tables are created by PhoenixKit's core migrations. If you need to set them up independently (e.g. fresh install without core migrations), the module includes a consolidated migration:

```elixir
PhoenixKit.Modules.Publishing.Migrations.PublishingTables.up(%{prefix: nil})
```

All statements use `IF NOT EXISTS`, so it's safe to run even when tables already exist.

### Enable the Module

Via admin UI: navigate to Admin > Modules > Publishing > toggle on.

Or via code:

```elixir
PhoenixKit.Modules.Publishing.enable_system()
```

## Features

- **Dual URL Modes** — Timestamp-based (blog/news) or slug-based (docs/FAQ), locked at group creation
- **Multi-Language Support** — Separate content per language with language switcher and smart fallbacks
- **Versioning** — Independent version history per post with publish/archive controls
- **Collaborative Editing** — Real-time presence tracking with owner/spectator locking
- **AI Translation** — Background translation via OpenRouter integration (Oban workers)
- **Two-Layer Caching** — Listing cache (`:persistent_term`, ~0.1us reads) + render cache (ETS, 6hr TTL)
- **Rich Content** — Markdown + inline PHK components (Image, Hero, CTA, Video, Headline, EntityForm)
- **Admin Interface** — Full CRUD with inline status controls, skeleton loading, trash management
- **Public Routes** — SEO-friendly URLs with smart language/date fallbacks, pagination, breadcrumbs
- **Featured Images** — Media library integration via PhoenixKit's MediaSelectorModal

## URL Modes

### Timestamp Mode (default)

Posts addressed by publication date and time. Ideal for news, announcements, changelogs.

```
/{language}/{group-slug}/{YYYY-MM-DD}/{HH:MM}
```

### Slug Mode

Posts addressed by semantic slug. Ideal for documentation, guides, evergreen content.

```
/{language}/{group-slug}/{post-slug}
```

Single-language mode omits the language segment automatically.

## Architecture

### Database Schema (4 tables)

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `phoenix_kit_publishing_groups` | Content groups | name, slug, mode, status, position |
| `phoenix_kit_publishing_posts` | Posts within groups | group_uuid, slug, status, mode, post_date/time |
| `phoenix_kit_publishing_versions` | Version history | post_uuid, version_number, status |
| `phoenix_kit_publishing_contents` | Per-language content | version_uuid, language, title, content, url_slug |

All tables use UUIDv7 primary keys and JSONB `data` columns for extensibility.

### Module Structure

```
lib/phoenix_kit_publishing/
  publishing.ex              # Main facade (PhoenixKit.Module behaviour)
  groups.ex                  # Group CRUD
  posts.ex                   # Post operations
  versions.ex                # Version management
  translation_manager.ex     # Language/translation ops
  db_storage.ex              # Database CRUD layer
  listing_cache.ex           # In-memory listing cache
  renderer.ex                # Markdown + component rendering
  page_builder.ex            # PHK XML component system
  stale_fixer.ex             # Data consistency repair
  presence.ex                # Collaborative editing presence
  pubsub.ex                  # Real-time broadcasting
  routes.ex                  # Admin route definitions
  schemas/                   # Ecto schemas (4 files)
  web/                       # LiveViews, controller, templates
  workers/                   # Oban background jobs
  migrations/                # Consolidated DB migration
```

### Core Modules

| Module | Role |
|--------|------|
| `PhoenixKit.Modules.Publishing` | Main context/facade — delegates to all submodules |
| `Publishing.DBStorage` | Direct Ecto queries for all CRUD operations |
| `Publishing.ListingCache` | `:persistent_term` cache with sub-microsecond reads |
| `Publishing.Renderer` | Earmark markdown + PHK component rendering with ETS cache |
| `Publishing.PageBuilder` | XML parser (Saxy) for `<Image>`, `<Hero>`, etc. components |
| `Publishing.StaleFixer` | Reconciles DB/cache state, auto-cleans empty posts |
| `Publishing.Presence` | Phoenix.Presence for collaborative editor locking |

## IEx / CLI Usage

```elixir
alias PhoenixKit.Modules.Publishing

# Groups
{:ok, _} = Publishing.add_group("Documentation", mode: "slug")
{:ok, _} = Publishing.add_group("Company News", mode: "timestamp")
Publishing.list_groups()

# Posts
{:ok, post} = Publishing.create_post("docs", %{title: "Getting Started"})
{:ok, post} = Publishing.read_post("docs", "getting-started")
{:ok, _} = Publishing.update_post("docs", post, %{"content" => "# Updated"})

# Translations
{:ok, _} = Publishing.add_language_to_post("docs", post_uuid, "es")
:ok = Publishing.delete_language("docs", post_uuid, "fr")

# Versions
{:ok, v2} = Publishing.create_version_from("docs", post_uuid, 1)
:ok = Publishing.publish_version("docs", post_uuid, 2)

# Cache
Publishing.regenerate_cache("docs")
Publishing.invalidate_cache("docs")
```

## Admin Routes

| Route | LiveView | Purpose |
|-------|----------|---------|
| `/admin/publishing` | Index | Groups overview |
| `/admin/publishing/new-group` | New | Create group |
| `/admin/publishing/edit-group/:group` | Edit | Group settings |
| `/admin/publishing/:group` | Listing | Posts list with status tabs |
| `/admin/publishing/:group/new` | Editor | Create post |
| `/admin/publishing/:group/:uuid/edit` | Editor | Edit post |
| `/admin/publishing/:group/preview` | Preview | Live preview |
| `/admin/settings/publishing` | Settings | Cache config |

## Public Routes

Multi-language mode:
```
/{language}/{group-slug}                           # Group listing
/{language}/{group-slug}/{post-slug}               # Slug-mode post
/{language}/{group-slug}/{post-slug}/v/{version}   # Versioned post
/{language}/{group-slug}/{date}/{time}             # Timestamp-mode post
```

Single-language mode omits the `/{language}` segment.

### Fallback Behavior

- Missing language → tries default language, then other available languages
- Missing timestamp post → tries other times on same date, then group listing
- All fallbacks include a flash message explaining the redirect
- Invalid group slugs fall back to 404 only after exhausting all alternatives

## Caching

### Listing Cache

Uses `:persistent_term` for near-zero-cost reads. Invalidated on post create/update, status change, translation add, or version create.

```elixir
Publishing.regenerate_cache("my-blog")
Publishing.find_cached_post("my-blog", "post-slug")
```

### Render Cache

ETS-based with 6-hour TTL and content-hash keys. Toggled globally or per-group:

```elixir
# Global toggle
PhoenixKit.Settings.update_setting("publishing_render_cache_enabled", "true")

# Per-group toggle
PhoenixKit.Settings.update_setting("publishing_render_cache_enabled_docs", "false")

# Manual clear
PhoenixKit.Modules.Publishing.Renderer.clear_group_cache("docs")
PhoenixKit.Modules.Publishing.Renderer.clear_all_cache()
```

## Content Format

Posts use Markdown with optional PHK components:

```markdown
# My Post Title

Regular **Markdown** content with all GitHub-flavored features.

<Image file_id="019a6f96-..." alt="Description" />

<Hero variant="centered">
  <Headline>Welcome</Headline>
  <CTA primary="true" action="/signup">Get Started</CTA>
</Hero>

<EntityForm entity="contact" />
```

Supported components: `Image`, `Hero`, `CTA`, `Headline`, `Subheadline`, `Video`, `EntityForm`.

## Settings

| Key | Default | Description |
|-----|---------|-------------|
| `publishing_enabled` | `false` | Enable/disable module |
| `publishing_public_enabled` | `true` | Show public routes |
| `publishing_posts_per_page` | `20` | Listing pagination |
| `publishing_memory_cache_enabled` | `true` | Listing cache toggle |
| `publishing_render_cache_enabled` | `true` | Render cache global toggle |
| `publishing_render_cache_enabled_<slug>` | `true` | Per-group render cache |

## Testing

Unit tests run without a database. Integration tests require PostgreSQL:

```bash
createdb phoenix_kit_publishing_test
mix test
```

Integration tests are automatically excluded when the database is unavailable.

## Dependencies

| Package | Purpose |
|---------|---------|
| `phoenix_kit` | Module behaviour, Settings, Auth, Cache, shared components |
| `phoenix_live_view` | Admin LiveView pages |
| `earmark` | Markdown rendering |
| `saxy` | XML parsing for PHK components |
| `oban` | Background translation and migration workers |

## License

MIT
