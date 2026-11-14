# Claude Maintainer Review — PR #64

**Reviewer:** Claude Fable 5.2 (maintainer-side sweep, independent of the contributor's
[CLAUDE_REVIEW.md](CLAUDE_REVIEW.md))
**PR:** A three-style pager, category colours and filters, a listing API for hosts, imports,
custom fields and readable URLs (mdon)
**Reviewed:** 2026-11-14, on the PR head `ec7384c` (based on `main` `7ae4349`)

## Overall Assessment

**APPROVE with the fixes below.** The migration (V3), the permission checks, the
group-settings wiring, the XSS surface of category colour and icon, the pager and filter
inputs and the smart-fallback contract all came out clean. The defects sit in the two
features that change a post's address (the conversion to slug URLs and
`public_url_prefix`) and on the edges of `import_post/3` and the custom fields.

Suite on the PR tree before the fixes: 2,972 tests, 0 failures, none excluded.

## Findings

### BUG - HIGH — converting a group published every scheduled post (fixed)

`Constants.scheduled_ahead?/3` holds back timestamp posts only, and the conversion sets
`mode: "slug"`. A live post dated ten days ahead went from hidden to listed at
`/group/<slug>` the moment the group was converted. The conversion is now refused with
`{:error, :scheduled_posts}` (new error atom, translated in the ten locales) while a live
post of the group is dated ahead.

### BUG - MEDIUM — a kit-prefixed URL was served, not redirected, on most language setups (fixed)

With `public_url_prefix` set, nothing compared the request's prefix with the public one:
the 301 fired only when the LANGUAGE was non-canonical, which the PR's test happened to
set up (a single `en-US` whose display code is `en`). With languages off, or with a
prefixless primary, `/phoenix_kit/<group>/<post>`, the listing and `feed.xml` all answered
200 beside their public URLs. `RouterDispatch` now marks a request that matched under the
non-public prefix and `Language.canonical_redirect?/4` reads the mark; the existing
"already canonical" guard keeps it loop-free and the query string is kept.

### BUG - MEDIUM — the conversion could put two posts on one URL (fixed)

Uniqueness was checked against `posts.slug` only. A timestamp post can already hold a
content `url_slug` (the editor writes it in any mode): post A with `url_slug: "hello"` and
post B titled "Hello" both ended at `/g/hello`. A generated slug now avoids every
`url_slug` another post of the group owns.

### BUG - MEDIUM — a save from an editor opened before the conversion committed, then raised (fixed)

`update_post_in_db` took the timestamp branch because the caller's stale map said
`mode: "timestamp"`, wrote the content with a slug of nil, and `read_updated_post` raised
`ArgumentError` on `p.slug == nil`: the title was written while the cache regeneration,
broadcast and activity entry were skipped. The stored row's mode decides now, and the
read-back falls back to the row's slug.

### BUG - MEDIUM — `import_post/3` still left a post behind on bad input (fixed for the reproduced inputs)

Only shapes were pre-checked. A missing title with the default `publish: true`
(`:title_required`), a NUL byte in any text and invalid UTF-8 in a version field each
failed after `create_post`, leaving a draft; an importer that retries made a duplicate per
attempt. The title and the storability of every text are checked before anything is
written.

### BUG - MEDIUM — a save rebuilt the custom-field rows under the writer (fixed)

After every save, autosave included, the form adopted the stored map: sorted by name,
blank rows gone. The row being typed vanished and the others changed index while the
inputs are named by index. `preserve_live_buffers/2` keeps the rows as the writer has them.

### BUG - MEDIUM — `update_post` accepted `custom_fields` it then cut or dropped (fixed)

39 fields answered `updated` with 30 stored; a 2,500-character value was cut to 2,000;
`"A b"` and `"a-b"` merged into one `a_b`; a nested value vanished. Every other API field
refuses instead. `PublishingVersion.check_custom_fields/1` refuses what the stored form
would lose (`invalid_custom_fields`, in the conformance test and the guide).

### BUG - LOW — smaller ones (all fixed)

- The conversion skipped `validate_slug/1`: a title that is a language code or a route
  word ("Admin") got an unreachable slug. It now gets the `-post` suffix.
- The conversion's activity entry had no `resource_uuid` and used `group_slug` where every
  other group entry uses `slug`; no sitemap refresh was requested although every URL of the
  group changed.
- The earlier-minute search crossed midnight backwards: a second post at 00:00 landed on
  the day before, so its URL date disagreed with `published_at`.
- One over-long category `seo_title` refused the whole `upsert_categories` batch at the
  schema, against the comment right above it; the schema caps are outer bounds again and
  padding is trimmed before the row's own check.
- A stored display value that fails today's rules blocked every later edit of another
  display field of that category; only the keys a write gives are validated.
- `list_published/2` returned `excerpt: ""` for a description of `""`.
- Category chips in the "cover" band sat inside the `pointer-events-none` strip and could
  not be clicked.
- An invalid `:public_url_prefix` logged a warning for every URL built; it warns once.

## Not changed, on record

- **`import_post/3` is still four commits** (create, backdate, update, publish). A failure
  the pre-checks do not cover (a database error mid-way, a backdate that runs out of
  retries) still leaves the created post. There is no permanent post delete to clean up
  with; trashing would hold the slot.
- **A post created while a conversion runs** can be inserted as a timestamp post after the
  conversion read the posts: `create_post` reads the mode without the group lock.
- **`SitemapRefresh` is not opt-in.** Its job is `manual: true`, which bypasses core's
  `schedule_enabled?`: every host with Sitemap enabled now regenerates about 30 s after a
  publish. It also does not fire on a live post's slug rename, a `sitemap_exclude` toggle
  or a group trash/restore.
- **Three things render differently with no setting changed:** post pages emit
  `<meta name="description">` inside the in-page OG block (a host whose layout emits one
  gets two); a derived description is cut at about 160 characters, not 300; an uncoloured
  category chip on a post page lost `badge-primary`. They read as deliberate; worth a
  CHANGELOG line each at release.
- **Group lookups per request:** with two prefixes, a non-publishing request under the
  longer one pays a second `fetch_group/1` (up to four when the first segment looks like a
  locale). `maybe_rewrite`'s moduledoc already names the fix (cache the slug set).
- **The category form cannot say what is wrong:** colour and icon errors land on `:data`
  and the flash is the generic one; the changeset messages are not gettext.
- `list_published(categories: ["typo"])` returns every post (documented); `total_pages`
  is 1 for an empty result here and 0 on the public listing.
- The dispatch e2e harness serves the kit at `/phoenix_kit` and public pages at `/`, so
  its sibling-dialect test now asserts the 301 to the public URL and then the 200 there.
