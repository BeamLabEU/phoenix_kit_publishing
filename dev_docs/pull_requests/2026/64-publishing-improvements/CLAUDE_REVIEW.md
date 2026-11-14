# Claude Review — PR #64

**Reviewer:** Claude Opus 5.5, with the external panel (codex GPT-6.1, zai GLM-5.3, vibe Mistral Medium 3.5)
**PR:** A three-style pager, category colours and filters, a listing API for hosts, imports, custom fields and readable URLs (mdon)
**Reviewed:** 2026-11-14

The author's own review of the branch before opening it. The diff was reviewed in three
areas, one seat each:
- routing, URL identity, mode conversion and import (codex, given the full source, since its sandbox cannot read files in the container);
- listing, categories, the listing API, custom fields and the editor (zai);
- the renderer and components, the sitemap refresh and the settings (vibe).

The fixes went back to codex for a second round. Every finding was reproduced before it was
fixed, and each fix has a test.

## Findings

### BUG - MEDIUM — import_post left a post behind on a malformed attr (fixed, 8062c36, f63189f)
`og: 42`, and later `og: %{title: 123}`, raised after `create_post` had written the post. Every
attr's shape is now checked before anything is written (`:invalid_format`).

### BUG - MEDIUM — overlapping prefixes misrouted kit-prefixed URLs (fixed, 27a9627)
With the kit at `/cms` and `public_url_prefix: "/"`, `/cms/news/x` was read as post `news` of a
group named `cms`. The dispatch now tries the longer prefix first.

### BUG - MEDIUM — a draft's old date URL revealed its new slug (fixed, 27a9627)
After a conversion, the old URL of an unpublished post 301'd to the slug made from its title. Only
a live post redirects now.

### BUG - LOW — an existing unroutable slug survived the conversion (fixed, 27a9627)
A timestamp post already holding a date-shaped or reserved slug kept it, and the router then read
its URL as a date. Such slugs are now made anew.

### BUG - LOW — concurrent backdates could collide (fixed, 27a9627, f63189f)
Two imports into the same free minute: the unique index refused one. The backdate retries on that
index only (not on any other unique error).

### BUG - LOW — category dry-run preview showed `from: nil` (fixed, 4c93b4c)
`upsert_categories`' preview read colour, icon and the SEO texts off the struct; they live in `data`.

### BUG - LOW — a 21st category pick did nothing (fixed, 4c93b4c)
The request keeps 20 slugs and dropped the one just added. Adding one past twenty now drops the
oldest instead.

### BUG - LOW — excerpt of a fence holding a blank line (fixed, dfc285c, f63189f)
The paragraph cut left the fence open, so a component shown in it was stripped. The cut fence is
now closed with the opener's own marker (backticks, tildes, four backticks).

### Checked, sound
XSS through category colour, icon and custom fields; the filter against hostile params and
canonical loops; `list_published/2` paging and sort; `url_context/1` against the language path; the
custom-field editor rows and dirty state; the dark-image stylesheet and `raw/1`;
`trim_description/2`; `SitemapRefresh`'s uniqueness on the locked Oban; the permission checks of the
new events.

## Open, for the maintainer

- Core's sitemap source builds Publishing URLs with the kit prefix; with `public_url_prefix` set they go through a 301 until core reads the setting.
- `mix phoenix_kit.repair` reports V3's column as an info-level extra column on a module-owned table.
