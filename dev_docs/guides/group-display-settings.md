# Per-group display settings and the translatable group name

What each group carries in its `data` JSONB, how a new setting is added, and how
a group's display name is translated.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Conventions and Feature notes.

## Per-group display settings (group `data` JSONB)

Distinct from the site-wide `publishing_*` settings keys: each group carries ~22
display settings in its `data` JSONB (scrollbar style, featured posts, the
latest-post band, scroll rails, post width, reading time, tags, post count, top
back link, clickable card images, etc.), edited on
`/admin/publishing/edit-group/:slug` and applied via
`Publishing.update_group(slug, params, opts)`.

All default off/neutral, so a fresh group's public pages look unchanged until an
admin opts in — with these nuances:

- `featured_enabled` defaults **true** (inert until a post is actually flagged
  featured in the editor, so still visually neutral).
- The breadcrumbs + post-count elements rendered unconditionally before these
  settings existed, so groups that had them need `show_breadcrumbs` /
  `show_post_count` turned on. That is a deliberate default-off migration, not a
  regression.
- `show_top_back_link` + `listing_image_links` default **true** (deliberate
  default-on features — the subtle top "Back to <group>" link on post pages and
  the card images clicking through to the post; the settings exist to turn them
  off per group).
- `newest_enabled` (+ `newest_layout`, hero/card) is default-off: when on, the
  chronologically newest post is pulled out of the grid into its own "Latest"
  band under any featured posts (a featured newest post stays in the Featured
  band — Latest takes the next-newest; `split_newest/2` in
  `controller/listing.ex`).
- `listing_animations` (default on) owns every card hover effect (the 4px
  motion-safe lift + shadow/image transitions) — off renders fully static cards.

Both bands also carry a **style** key (`featured_style` / `newest_style`:
`classic | cover | cover_panel | minimal | top`, default `classic`) orthogonal to
the layout — layout is size/placement (hero band vs card in the 2-col grid),
style is paint:

- `cover` — the featured image as the card background under a HARDCODED gradient
  scrim with fixed light text (a real lazy `<img>` layer, not a CSS background;
  no image → a branded primary/secondary gradient banner, secondary-leaning for
  Latest).
- `cover_panel` — image with an opaque `bg-base-100/95` text panel (the a11y-safe
  cover).
- `minimal` — text-only accent-border editorial band.
- `top` — 16:9 banner above the text.

Dispatch lives in `html.ex`'s `listing_band_card/1` — `classic`/unknown delegates
to the original `listing_post_card` variants, so pre-styles groups render
unchanged. Scrim strength, band height, and text placement are deliberately
hardcoded: good defaults over option bloat.

## Admin post-status classification

The admin group page shows each post by its LIVE state —
`list_posts_with_metadata` passes `:effective_status`, `:effective_published_at`,
AND `:effective_title` overrides (all read from the ACTIVE published version, the
same rule the public `list_posts_for_listing` applies) — while still mapping the
LATEST version for editing context.

Deliberate split: `metadata.status` / `title` / publish date are the card-level
truth (what readers see), the per-language/per-version maps stay version-accurate
so the editor lands on the newest draft. Versions are an ARCHIVAL tool here
(retain old legal text, branch a rewrite) — do not surface "unpublished edits"
style pending-work flags in listings.

## Write-path behaviour

`update_group/3` is **lenient** (an out-of-whitelist enum value is ignored, a
non-truthy bool becomes `false` — the admin-form path can't fail on settings),
while `validate_group_settings/1` is **strict** (returns per-key errors) —
programmatic callers should validate first if they want feedback.

`name_i18n` overrides are hardened at merge: non-binary values (nested maps from
crafted params) are dropped, and each override is capped to
`Constants.max_group_name_length()`.

## Machine-readable spec

`PhoenixKit.Modules.Publishing.GroupSettings` is the machine-readable spec of
those settings — for AI/agent/MCP/script-driven configuration without the UI:

- `Publishing.group_settings_schema/0` — list of
  `%{key, type, allowed, default, scope, label, description, depends_on}`
  (values/defaults derived from `Constants`, so it can't drift from what
  `update_group/3` accepts).
- `Publishing.group_settings_defaults/0` / `group_settings_keys/0`.
- `Publishing.validate_group_settings/1` — casts/validates a proposed params map,
  returning `{:ok, normalized}` (booleans + enums coerced, unknown keys like
  `name`/`slug` passed through) or `{:error, [%{key:, reason:}]}`. Feed the `:ok`
  result straight to `update_group/3`.

The accessor + default source of truth for each setting is the `PublishingGroup`
schema moduledoc. Add a new setting in `Constants` → `publishing_group.ex`
accessor → `groups.ex` (`merge_group_config` + `db_group_to_map`) → `edit.ex`
form → `group_settings.ex` spec (its test asserts the key set matches
`merge_group_config`).

## Host contract for the scroll aids

The scroll aids (scrollbar restyle, reading-progress bar, heading rail, timeline
rail) ship as self-contained inline `<style>`/`<script>` blocks in the public
templates (dead views — full page loads, no LiveView). Two consequences:

1. A host with a strict CSP (no `'unsafe-inline'`) silently loses them — the
   pages still render fine without them.
2. The scroll math reads `document.documentElement` / `window.scrollY`, so the
   **window must be the scroll owner** — a host app-shell that scrolls an inner
   `overflow-y-auto` container instead of the body disables the aids (progress
   bar never fills, rails hide/stall).

The rails' month labels + aria-labels localize via `data-months`/`data-label` on
the hidden config elements (`#pk-timeline-config`, `#pk-headings-config`) — the
JS falls back to English when absent. The timeline rail bins cards by
`data-post-date`, which carries the same *effective* publish date the listing
sorts by (`effective_post_date/1` in `web/html.ex` mirrors
`Listing.listing_sort_key/1` — don't let the two drift). Known limit: the listing
(and so `oldest` sort) runs over the listing cache, which caps at the most recent
5,000 posts.

## Group-name AI translation

A second `PhoenixKitAI.Translatable` adapter,
`PhoenixKitPublishing.GroupAITranslatable` (`resource_type "publishing_group"`,
uuid-keyed — the public group map exposes `"uuid"` for this). One field
(`{{name}}`), merged into `data["name_i18n"]` under a `FOR UPDATE` row lock (all
languages share one JSONB — sibling-safe), audit row `publishing.group.updated`
(mode `"auto"`, `source: "ai_translation"`), NO per-merge `:group_updated`
broadcast (see `log_translated/3`).

The Edit Group LV wires it via `AITranslate.Embed` + `FormGlue` with a params-map
`GroupAITranslateBinding` (deliberately not `@behaviour` — the callbacks type an
Ecto changeset). The editor imports `ai_multilang_tabs/1` directly from
`phoenix_kit_ai`, which is why the mix.exs floor on that package is load-bearing.

## Translatable group name

The group's **display name** is translatable per language via the core
`PhoenixKitWeb.Components.MultilangForm` tabs on the edit page. The
primary-language name stays in the `name` column; per-language overrides live in
an isolated `data["name_i18n"]` map (`%{lang => name}`) — NOT the multilang
helper's `data`-owning convention, which would clobber the display settings
above.

The **slug is intentionally not translated** (single canonical URL).

Public pages resolve the name via `Publishing.translated_group_name(group_map, lang)`
/ `PublishingGroup.translated_name/2`, which is base-language tolerant (the form
stores the full code `fr-FR`, the public side asks by the short code `fr`). Every
public surface that shows a group name resolves through it: the listing h1 / page
title / OG title / breadcrumb, the post page's breadcrumb + "Back to …" footer
(via `PostRendering.fetch_group/1` + `resolve_group_name/3` — the same fetched
group map also feeds the controller's `assign_group_display_config/2`, one fetch
per request), and the feed channel title. Admin surfaces intentionally show the
canonical primary-language name. `display_settings_render_test.exs` pins the
reach.
