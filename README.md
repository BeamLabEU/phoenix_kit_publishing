# PhoenixKit Publishing

A standalone PhoenixKit plugin module that provides a database-backed content management system with multi-language support, collaborative editing, and dual URL modes.

## Installation

Add to your parent app's `mix.exs`:

```elixir
{:phoenix_kit_publishing, "~> 0.16"}
```

Or for local development:

```elixir
{:phoenix_kit_publishing, path: "../phoenix_kit_publishing"}
```

Then run `mix deps.get` and `mix phoenix_kit.install`. The module is auto-discovered by PhoenixKit at startup — no additional config needed. The installer also adds the necessary Tailwind CSS `@source` directive so all styles render correctly.

The editor requires Leaf 0.10.1 or later (`>= 0.10.1 and < 1.0.0`). When
upgrading, update any vendored `leaf.js` bundle or CDN version alongside the
dependency: language/version switches, Preview, version creation, and
translation wait for Leaf's correlated flush replies, and the component
previews need the 0.9 `tag_previews`, which older bundles do not have.

### Database Setup

The 7 publishing tables — `phoenix_kit_publishing_groups`, `_posts`,
`_versions`, `_contents` (core `V135` baseline) and `_categories`,
`_post_categories`, `_post_views` (core `V159`) — are created by PhoenixKit's
core versioned migrations. Run `mix phoenix_kit.install` in the host app and
they're set up automatically. This module also owns their *future* shape
through its own versioned chain, `PhoenixKitPublishing.Migrations`
(`migration_module/0`), which `mix phoenix_kit.update` discovers and drives
alongside core's own chain — no separate command to run. V1 adopts the shape
core already creates, stamping a version marker. V2 adds two expression
indexes for media-folder pointers without changing tables, columns, or content.
Run `mix phoenix_kit.update` in existing hosts to apply the current chain.

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
- **AI Translation** — Background translation through `phoenix_kit_ai` (one Oban job per target language)
- **Two-Layer Caching** — Listing cache (`:persistent_term`, ~0.1us reads) + render cache (ETS, 24h TTL)
- **Rich Content** — Markdown + inline PHK components (Image, Hero, CTA, Video, Audio, Embed, Headline, Subheadline, EntityForm, Showcase, Gallery, Note)
- **Admin Interface** — Full CRUD with inline status controls, skeleton loading, trash management
- **Public Routes** — SEO-friendly URLs with smart language/date fallbacks, pagination, breadcrumbs
- **Featured Images** — Media library integration through core's media picker

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

### Database Schema (7 tables)

```
Group (1) ──→ (many) Post (1) ──→ (many) Version (1) ──→ (many) Content
Group (1) ──→ (many) Category (self-referencing tree)
Post  (many) ──→ (many) Category   via PostCategory
Post  (1) ──→ (many) PostView (one row per day)
```

#### `phoenix_kit_publishing_groups` — Content containers

| Column | Type | Purpose |
|--------|------|---------|
| uuid | UUIDv7 | PK |
| name | string | Display name |
| slug | string | URL identifier (unique) |
| mode | string | `"timestamp"` or `"slug"` — locked at creation |
| status | string | `"active"` or `"trashed"` |
| position | integer | Display ordering |
| data | JSONB | type, item_singular/plural, icon, comments/likes/views_enabled, `media_folder_uuid` (see [Media folders](#media-folders)) |
| title_i18n | JSONB | Translatable group title (keyed by language code) |
| description_i18n | JSONB | Translatable group description (keyed by language code) |

#### `phoenix_kit_publishing_posts` — Routing shell

Posts hold URL identity and point to their live version. No content or metadata — that lives on versions.

| Column | Type | Purpose |
|--------|------|---------|
| uuid | UUIDv7 | PK |
| group_uuid | UUIDv7 | FK → groups |
| slug | string | URL path segment (slug mode, unique per group) |
| mode | string | `"timestamp"` or `"slug"` |
| post_date | date | URL date segment (timestamp mode) |
| post_time | time | URL time segment (timestamp mode, unique per group+date) |
| active_version_uuid | UUIDv7 | FK → versions — the live version (null = unpublished) |
| trashed_at | utc_datetime | Soft delete timestamp (null = active) |
| created_by_uuid | UUIDv7 | FK → users (audit) |
| updated_by_uuid | UUIDv7 | FK → users (audit) |

Publishing = setting `active_version_uuid`. Trashing = setting `trashed_at`.

#### `phoenix_kit_publishing_versions` — Source of truth

Each post has one or more versions. The version holds all metadata that applies across languages.

| Column | Type | Purpose |
|--------|------|---------|
| uuid | UUIDv7 | PK |
| post_uuid | UUIDv7 | FK → posts |
| version_number | integer | Sequential (v1, v2, ...), unique per post |
| status | string | `"draft"` / `"published"` / `"archived"` |
| published_at | utc_datetime | When this version was first published |
| created_by_uuid | UUIDv7 | FK → users (audit) |
| data | JSONB | featured_image_uuid, tags, seo, description, allow_version_access, notes, created_from, `media_folder_uuid` (the post's folder, on every version — see [Media folders](#media-folders)) |

#### `phoenix_kit_publishing_contents` — Per-language title + body

One row per language per version. All languages share the version's status and metadata.

| Column | Type | Purpose |
|--------|------|---------|
| uuid | UUIDv7 | PK |
| version_uuid | UUIDv7 | FK → versions |
| language | string | Language code (unique per version) |
| title | string | Post title in this language |
| content | text | Markdown/PHK body in this language |
| url_slug | string | Per-language URL slug (for localized URLs) |
| status | string | Reserved for future per-language overrides (unused by UI) |
| data | JSONB | Reserved for future per-language overrides (unused by UI) |

#### `phoenix_kit_publishing_categories` — Hierarchical per-group taxonomy

WordPress-parity categories. `slug` is unique per group (not globally).

| Column | Type | Purpose |
|--------|------|---------|
| uuid | UUIDv7 | PK |
| group_uuid | UUIDv7 | FK → groups (`ON DELETE CASCADE`) |
| parent_uuid | UUIDv7 | FK → categories, self-referencing (`ON DELETE SET NULL` — deleting a parent lifts children to the root) |
| name | string | Display name |
| slug | string | URL segment, unique per group |
| name_i18n | JSONB | Per-language display-name overrides |
| description | string | Optional description |
| position | integer | Display ordering |

#### `phoenix_kit_publishing_post_categories` — Post ↔ category assignment

Many-to-many, post-level (not per-version) — WordPress semantics. Composite
primary key `(post_uuid, category_uuid)`; both FKs cascade.

#### `phoenix_kit_publishing_post_views` — Per-day view counters

One `(post_uuid, view_date)` row incremented in place; no per-request rows,
no reader PII. Composite primary key `(post_uuid, view_date)`; `post_uuid`
FK cascades. Queried schemaless (no Ecto schema module) via `Publishing.Views`.

All tables use UUIDv7 primary keys. Language fallback chain: requested language → site default → first available.

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
  media_folders.ex           # Group media folders + ready-made host hooks
  media_adoption.ex          # One-time filing of existing post media
  media_reorganizer.ex       # Plan source for core's media reorganizer
  presence.ex                # Collaborative editing presence
  pubsub.ex                  # Real-time broadcasting
  routes.ex                  # Admin route definitions
  schemas/                   # Ecto schemas (6 files)
  api/                       # Machine API tools (20)
  web/                       # LiveViews, controller, templates
```

### Core Modules

| Module | Role |
|--------|------|
| `PhoenixKit.Modules.Publishing` | Main context/facade — delegates to all submodules |
| `Publishing.DBStorage` | Direct Ecto queries for all CRUD operations |
| `Publishing.ListingCache` | `:persistent_term` cache with sub-microsecond reads |
| `Publishing.Renderer` | MDEx markdown + PHK component rendering with ETS cache |
| `Publishing.PageBuilder` | XML parser (Saxy) for `<Image>`, `<Hero>`, etc. components |
| `Publishing.StaleFixer` | Reconciles DB/cache state, auto-cleans empty posts |
| `Publishing.Presence` | Phoenix.Presence for collaborative editor locking |
| `Publishing.MediaFolders` | One media folder per group; files picked in the editor go there |
| `Publishing.MediaAdoption` | Files the media posts already use into their group's folder |
| `Publishing.MediaReorganizer` | Group folders for `mix phoenix_kit.media.reorganize` |

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

## Listing posts from a host

A host that draws its own listing (a news page with its own filters, a "latest
posts" block) reads the published posts as data instead of rendering
Publishing's page:

```elixir
{:ok, %{entries: entries, total: total, total_pages: pages}} =
  PhoenixKit.Modules.Publishing.list_published("news",
    language: "en",
    categories: ["billing", "crm"],   # any of them, subcategories included
    page: 3,
    per_page: 20
  )

{:ok, counts} = PhoenixKit.Modules.Publishing.category_counts("news", language: "en")
# %{"billing" => 44, "crm" => 12, ...}
```

Each entry has `uuid`, `title`, `description`, `excerpt`, `url`, `published_at`,
`featured_image_uuid` (`featured_image_url` with `images: true`), `categories`
(`slug`, `name`, `color`, `color_css`, `icon`, `url`) and `custom` (the post's
custom fields, edited in the post editor's sidebar). Building many post URLs
yourself, pass `Web.HTML.url_context(language)` in place of the language to
`build_post_url/4`, with `build_date_counts/1` for a timestamp group: the
settings are then read once, and no URL costs a query.

## Admin Routes

| Route | LiveView | Purpose |
|-------|----------|---------|
| `/admin/publishing` | Index | Groups overview |
| `/admin/publishing/new-group` | New | Create group |
| `/admin/publishing/edit-group/:group` | Edit | Group settings |
| `/admin/publishing/categories/:group` | CategoriesLive | Category tree |
| `/admin/publishing/:group` | Listing | Posts list with status tabs |
| `/admin/publishing/:group/new` | Editor | Create post |
| `/admin/publishing/:group/:post_uuid` | PostShow | Post overview |
| `/admin/publishing/:group/:post_uuid/edit` | Editor | Edit post |
| `/admin/publishing/:group/:post_uuid/preview` | Preview | Preview |
| `/admin/settings/publishing` | Settings | Module settings and caches |

A group can't be named `new-group`, `edit-group` or `categories`: those are
the literal admin segments beside `/admin/publishing/:group`.

## Public Routes

Multi-language mode:
```
/{language}/{group-slug}                           # Group listing
/{language}/{group-slug}/{post-slug}               # Slug-mode post
/{language}/{group-slug}/{post-slug}/v/{version}   # Versioned post
/{language}/{group-slug}/{date}/{time}             # Timestamp-mode post
```

Single-language mode omits the `/{language}` segment.

When core's `default_language_no_prefix` setting is enabled (Languages module; it replaced the legacy `publishing_default_language_no_prefix`), the primary language's URL also drops its prefix (e.g. `/blog` instead of `/en/blog`), and requests to the prefixed form 301-redirect to the canonical prefixless URL.

### Fallback Behavior

- Missing language → tries default language, then other available languages
- Missing timestamp post → tries other times on same date, then group listing
- All fallbacks include a flash message explaining the redirect
- A group that does not exist is a 404, never a redirect: under `url_prefix: "/"`
  a fallback would claim every unclaimed path of the host

### How Dispatch Works (and how it interacts with host routes)

Public URLs are dynamic — the group slug is a database row, not a compile-time
literal — so these routes can't be declared normally. Publishing registers its
catch-all under an internal prefix and overrides the host router's `call/2`
(`RouterDispatch`): on each `GET`/`HEAD`, if the first non-locale path segment
matches a known group slug, the path is rewritten to the internal prefix and
Phoenix matches it there. Otherwise the request passes through untouched.

Two consequences worth knowing:

- **A host route whose first segment equals a group slug will never match.** The
  rewrite happens in `call/2`, before route matching — declaration order in
  `router.ex` doesn't help. Only `GET`/`HEAD` are rewritten, so a `POST /blog/...`
  still reaches the host.
- **`mix phx.routes` shows these routes under `__phoenix_kit_publishing_dispatch`**,
  not at their public paths.

### Reserved Route Prefixes

Another PhoenixKit module can claim a top-level segment by implementing
`PhoenixKit.Module.reserved_route_prefixes/0`:

```elixir
@impl PhoenixKit.Module
def reserved_route_prefixes, do: ["shop"]
```

`RouterDispatch.known_group?/1` consults
`PhoenixKit.ModuleRegistry.all_reserved_route_prefixes/0` and refuses to claim a
reserved segment **even when a group with that exact slug exists in publishing's
own data**.

Reserve a prefix only if your module actually renders that route — a reservation
removes the path from publishing's dispatch, and if nothing takes over, the result
is a 404. `phoenix_kit_legal` reserved `"legal"` in its 0.1.6 without shipping a
renderer and 404'd public legal pages on every host app; it was reverted in 0.1.7,
and legal pages are once again served here as an ordinary group. If your module
stores its content as publishing posts, letting publishing render them is usually
the right call — you inherit languages, translations, canonical/`og:*`/hreflang,
and the editor for free.

## Caching

### Listing Cache

Uses `:persistent_term` for near-zero-cost reads. Invalidated on post create/update, status change, translation add, or version create.

```elixir
Publishing.regenerate_cache("my-blog")
Publishing.find_cached_post("my-blog", "post-slug")
```

### Render Cache

ETS-based with a 24-hour TTL and content-hash keys. A page holding a form that
carries the visitor's CSRF token (`<EntityForm>`) is never cached. Toggled
globally or per-group:

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

<!-- A light/dark pair: the reader sees the one matching the site theme -->
<Image file_uuid="019a6f96-..." dark_file_uuid="019a6f97-..." alt="Description" />

<Hero variant="centered">
  <Headline>Welcome</Headline>
  <CTA primary="true" action="/signup">Get Started</CTA>
</Hero>

<EntityForm entity="contact" />
```

Supported components: `Image`, `Hero`, `CTA`, `Headline`, `Subheadline`, `Video`, `Audio`, `Embed`, `EntityForm`, `Showcase`, `Gallery`, `Note`. The full format is in `phk-publishing-format.md`.

## Settings

| Key | Default | Description |
|-----|---------|-------------|
| `publishing_enabled` | `false` | Enable/disable module |
| `publishing_public_enabled` | `true` | Show public routes |
| `publishing_posts_per_page` | `20` | Listing pagination (1–200) |
| `publishing_pagination_style` | `"numbered"` | The listing pager: `numbered` (windowed page numbers), `compact` ("Page 7 of 62" with a go-to-page box) or `simple` (Previous / Next) |
| `publishing_reading_wpm` | `200` | Words per minute for the reading time (50–1000) |
| `publishing_editor_lock_minutes` | `30` | Editor owner-lock timeout (1–480) |
| `publishing_slug_style` | `transliterate` | `transliterate`, `unicode` or `ascii` |
| `publishing_show_language_switcher` | `true` | In-page language switcher on public pages |
| `publishing_render_og_tags` | `true` | In-page OpenGraph/Twitter meta tags; turn off once your root layout renders them in `<head>` (see below) |
| `publishing_render_jsonld` | `true` | schema.org `Article` JSON-LD on post pages |
| `publishing_feeds_enabled` | `true` | RSS 2.0 per group at `/<group>/feed.xml` |
| `publishing_unique_views` | `true` | One view per visitor per post per day |
| `publishing_memory_cache_enabled` | `true` | Listing cache toggle |
| `publishing_render_cache_enabled` | `true` | Render cache global toggle |
| `publishing_render_cache_enabled_<slug>` | `true` | Per-group render cache |
| `publishing_media_folder_uuid` | — | The module's media folder, written by the ready-made media hook (see below) |

### OpenGraph tags belong in `<head>`

Out of the box the post and listing pages print their `og:*`, `twitter:*` and
`<meta name="description">` tags **in the page body**
(`publishing_render_og_tags`, on by default), so link previews work with any
root layout. Some scrapers only read `<head>`, so a host that owns its root
layout should render the tags there and turn the in-page copy off.

The controller puts the page's OpenGraph map on `conn.assigns.og` (`nil` on
pages without one). Render it in the `<head>` of your root layout with the
module's own component, which prints nothing when there is no map:

```heex
<%!-- lib/my_app_web/components/layouts/root.html.heex --%>
<head>
  <meta charset="utf-8" />
  <%!-- … --%>
  <PhoenixKit.Modules.Publishing.Web.HTML.og_meta_tags og={assigns[:og]} />
</head>
```

Then turn **In-Page OpenGraph Tags** off at `/admin/settings/publishing`
(or set `publishing_render_og_tags` to `false`), otherwise every tag appears
twice. Core's own root layout (`PhoenixKitWeb.Layouts.root`) already prints
`@og` in `<head>`, so a host on it only needs the setting turned off. Read the
assign in `root.html.heex`, not in a function-component layout such as
`Layouts.app/1`, which sees only the attrs it declares.

A description derived from the post body is cut to about 160 characters at a
sentence end; one the author wrote (the post's OG override or its
description) is used whole.

## Media folders

Off by default: a host that configures nothing keeps today's behaviour and no
folder is created. To keep each group's media in its own folder —
`Publishing/News`, `Publishing/Legal` — add the ready-made hooks:

```elixir
config :phoenix_kit_publishing,
  attachments_parent_folder: {PhoenixKit.Modules.Publishing.MediaFolders, :module_folder},
  attachments_folder_name: {PhoenixKit.Modules.Publishing.MediaFolders, :folder_name}
```

For a folder per post inside its group's — `Publishing/News/spring-fair`, a
timestamp post's named by its date and time — add:

```elixir
config :phoenix_kit_publishing, :post_media_folders, true
```

Or point either hook key at your own function (core's `Storage.ResourceFolders`
convention): `parent_for(:group, actor_uuid, group)` answers
`{:ok, folder_uuid}` or `nil` for the media root; `name_for(subject, actor_uuid)`
— a group, or a post with post folders on — answers `{:ok, name}` or `nil` for
`publishing-group-<uuid>` / `publishing-post-<uuid>`. A group or post keeps its
folder when it is renamed later.

Then, once:

```bash
mix phoenix_kit_publishing.media.adopt           # dry run: what would be filed
mix phoenix_kit_publishing.media.adopt --apply   # file it
```

(In a release: `PhoenixKit.Modules.Publishing.MediaAdoption.run(actor_uuid, apply?: true)`.)

This files every file a group's posts use — featured, OG and audio slots,
`<Image>`/`<Audio>`/`<Showcase>` components, baked `/file/<uuid>/…` URLs — into
the group's folder, or each post's. A file with no folder is moved in; a file
that already lives in another folder stays there and is linked in (with post
folders, one in the group's own folder moves down into the post's). A file
several posts use lives in the first post's folder and is linked into the
others'. File URLs do not change.

From then on every file picked in the post editor lands in the post's (or
group's) folder by itself, and `mix phoenix_kit.media.reorganize` moves the group folders when
you change the hooks later — post folders travel with their group's (it also
reports a group or post whose files are outside its folder, the folder of a
trashed group or post, and a name hook that can't be called).
With the ready-made hooks, even its dry run may create the `Publishing` folder
if it is missing: the parent hook creates it on first use.

Folders are only ever looked up and created in the site's media library
(Media), never in a person's own library. If a configured hook cannot be
called, the adoption step refuses to plan; if one fails while applying, that
group is left unfiled rather than filed at the media root.

> #### Trashing a group's folder trashes the posts' pictures {: .warning}
>
> After adoption, a file that used to have no folder lives in its group's (or
> post's) folder. Moving `Publishing/<group>`, a post's folder, or `Publishing`
> itself to the trash in
> the media browser trashes every file whose home is inside it — including one
> that is also shown somewhere else by URL (a page, another module) — and those
> pictures stop showing until the folder is restored from the trash. A file
> that is only *linked* into the folder keeps its own home and is not affected.
> Rename or move these folders freely; trash them only together with their
> group or post.

## Machine API

The module declares 20 admin tools for core's machine API (`/api/admin/v1` over
REST, `/mcp/admin` over MCP): an AI agent, a script or an integration can read
and edit groups, posts, versions, translations and categories the way an admin
does in the editor. Core owns keys, scopes, rate limits, validation and the
confirmation flow; this module declares the tools and the data rules. It needs
`phoenix_kit` 2.63.0 or later, the first release that carries the machine API; the
module as a whole requires 2.65.0. The tools appear only while
Publishing is enabled.

**Enable it.** Switch on `api_admin_enabled` and create a key in
`/admin/settings/api`. A key has scopes, and its owner must hold the role
permission `publishing`, checked on every request; `upsert_groups`,
`trash_groups` and `restore_groups` also need `publishing.manage`. The scopes:

| Scope | Tools |
|---|---|
| `publishing.posts:read` | `list_posts`, `get_post` |
| `publishing.posts:write` | `create_post`, `update_post`, `create_version`, `set_translation` |
| `publishing.posts:publish` | `publish_post`, `unpublish_post`, `schedule_post` |
| `publishing.posts:delete` | `trash_posts`, `restore_posts` |
| `publishing.categories:read` | `list_categories` |
| `publishing.categories:write` | `upsert_categories` |
| `publishing.categories:delete` | `delete_categories` |
| `publishing.groups:read` | `list_groups`, `get_group_settings_schema` |
| `publishing.groups:write` | `upsert_groups` |
| `publishing.groups:delete` | `trash_groups`, `restore_groups` |
| `publishing.translations:ai` | `translate_post` |

**The confirmation rule.** Anything that changes what a visitor sees needs a
confirmation: publishing, unpublishing, scheduling, trashing, restoring a post
that has a live version, editing a live or archived version, a slug change on a
live post, changing an existing category or group, a body that holds HTML or a
component, text the renderer turns into a link of another scheme (`ftp://`, `xmpp:`), every AI translation (it costs money) and the permanent
`delete_categories`. The call answers `confirmation_required` with a preview
and a `confirm_token`; the agent repeats the same call with the token (and
should ask its user first), or, when the key requires approval, a person
approves it in `/admin/settings/api/approvals`. Everything else (reading,
drafting, creating a version, editing a draft in plain Markdown, creating a
category or a group) runs at once. `dry_run: true` shows the preview of any
write without writing.

**The tools.**
`publishing.list_groups`, `publishing.get_group_settings_schema`,
`publishing.list_posts`, `publishing.get_post`, `publishing.list_categories`,
`publishing.create_post`, `publishing.update_post`, `publishing.create_version`,
`publishing.set_translation`, `publishing.translate_post`,
`publishing.publish_post`, `publishing.unpublish_post`,
`publishing.schedule_post`, `publishing.trash_posts`,
`publishing.restore_posts`, `publishing.upsert_categories`,
`publishing.delete_categories`, `publishing.upsert_groups`,
`publishing.trash_groups`, `publishing.restore_groups`.

```bash
curl -s -X POST https://example.com/api/admin/v1/publishing.list_groups \
  -H "Authorization: Bearer pk_0123abcd_..." \
  -H "Content-Type: application/json" -d '{}'
```

The API never hard-deletes a group, post, version or language; the one
permanent delete is `delete_categories`. See
[dev_docs/guides/machine-api.md](dev_docs/guides/machine-api.md) for references,
output shapes, previews, the confirmation round trip, error codes and limits.

**Public URLs.** A published post's `public_paths` hold one URL per language,
absolute unless the site has no origin configured (then a language without a
domain gets the bare root-relative path). On a multi-domain site (host app
config `:canonical_host_resolver`) a language served from its own domain gets
that domain and no base-language segment (`/de` goes); a sibling dialect keeps
its own segment (`/en-gb`), so it is `https://<domain>/en-gb/...`. Any other
language gets the site origin and the prefixed path.

## Removing this module

There is deliberately **no automated uninstall**.
`PhoenixKitPublishing.Migrations.down/1` never drops any of the 7 tables or a
row in them, for any target version — a host that merely removes this
dependency from `mix.exs` has not consented to deleting every content group,
post, version, per-language content row, category, category assignment, and
view counter, and a migration whose result depended on which packages happen
to be compiled in would be nondeterministic. Removing the data is therefore
a deliberate, manual operator step:

```sql
-- Only after removing :phoenix_kit_publishing from mix.exs, and only if you
-- actually want every group, post, version, content row, category,
-- assignment, and view counter gone for good.
--
-- One statement, on purpose: posts <-> versions is a genuine FK cycle
-- (posts.active_version_uuid points forward to the live version,
-- versions.post_uuid points back to the owning post), so dropping the tables
-- one at a time fails with "other objects depend on it". A single DROP TABLE
-- listing all 7 resolves the cycle itself, without naming any constraint —
-- which matters on a host whose constraints were renamed.
DROP TABLE
  phoenix_kit_publishing_post_views,
  phoenix_kit_publishing_post_categories,
  phoenix_kit_publishing_categories,
  phoenix_kit_publishing_contents,
  phoenix_kit_publishing_versions,
  phoenix_kit_publishing_posts,
  phoenix_kit_publishing_groups;
```

Dropping `phoenix_kit_publishing_groups` last also removes the
`pkpub_schema:<N>` version marker, which is a `COMMENT` on that table — no
separate step is needed.

If you want to keep the tables (e.g. you plan to reinstall the module
later) but stop this chain from tracking them, clear the version marker
instead:

```sql
COMMENT ON TABLE phoenix_kit_publishing_groups IS NULL;
```

## Testing

Unit tests run without a database. Integration and controller tests require PostgreSQL:

```bash
createdb phoenix_kit_publishing_test
mix test
```

Integration tests are automatically excluded when the database cannot be reached. A
database that is reachable but cannot be brought to the current schema (one left
behind by an older core, say) fails the run instead; rebuild it with `mix test.reset`.
Controller tests run through a minimal `Phoenix.Endpoint` + `Router` + `Layouts` shipped under `test/support/` — see `AGENTS.md` for details.

## Dependencies

| Package | Purpose |
|---------|---------|
| `phoenix_kit` | Module behaviour, Settings, Auth, Cache, shared components, machine API |
| `phoenix_kit_ai` | AI translation pipeline (adapters live here, the jobs and LLM call there) |
| `leaf` | The post editor |
| `phoenix_live_view` | Admin LiveView pages |
| `mdex` | Markdown rendering (comrak) and the HTML sanitiser (ammonia) |
| `saxy` | XML parsing for PHK components |
| `oban` | Background jobs (AI translation) |
| `gettext` | This module's own translations (de, en, es, et, fr, it, pl, ru, uk, zh), Leaf's editor strings included |

## License

MIT
