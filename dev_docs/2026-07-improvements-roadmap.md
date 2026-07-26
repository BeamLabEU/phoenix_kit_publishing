# Publishing improvements roadmap — 2026-07 brainstorm

Planning record for the post-0.4.3 improvement wave. Sources: the boss's
list (via Max, 2026-07-25) + Max's clarifications + our own proposals.
Living doc — update as items land or decisions change.

## Boss's list (clarified)

| # | Item | Clarified intent |
|---|------|------------------|
| 1 | Search | Public per-group search (GET form, no-JS, ILIKE title+body, language-aware) + admin hybrid search (core `TableLocalSearch` ≤100 rows, SQL + load-more above). tsvector only if proven necessary (core migration). |
| 2 | List view & other views | **Must-have: minimalist "date — title" layout, no image.** Per-group `listing_layout` setting: `grid` (default) \| `minimal` (date—title) \| `list` (thumb-left rows) \| `compact`; settings to tweak. Rides GroupSettings machinery end-to-end. |
| 3 | Align buttons | Public listing cards: content height pushes footer buttons around. Fix: card = `flex flex-col`, footer `mt-auto`. Small, first PR. |
| 4 | Categories & tags | **WordPress parity minimum**: hierarchical categories (multi-assign per post, archive pages, default category, admin management + editor assignment UI), flat tags with archive pages. Needs real `publishing_categories` table (self-FK tree, catalogue-V103 shape) → core migration. Our improvements: AI-translatable category names (group-name adapter pattern), per-term RSS. |
| 5 | Images/titles beyond the column | Gutenberg-style alignment lanes: post body renders in a CSS grid with content / wide / full-bleed lanes; PHK components take `align="wide\|full"` or `stretch="<percent>"`. Foundation for PullQuote/Gallery/TOC and item 6's sidenotes. |
| 6 | Annotations | **Author-side** notes that clarify text for readers. Inline PHK syntax wrapping a phrase + note body; superscript marker + popover (progressive enhancement); collected Notes section at bottom = no-JS baseline; true margin sidenotes on wide screens (rides item 5 lanes). MDEx already parses GFM footnotes (`[^1]`) — candidate base syntax. Editor UX: "annotate selection" toolbar action + notes list. Design sign-off before build. Name them "notes/sidenotes" — core already uses "annotations" for Etcher media markup. |
| 7 | Comments | Comments under posts via `phoenix_kit_comments` (optional seam, not hard dep). Server-rendered list + plain POST form baseline (public pages are dead views; Phoenix-first), LV island as enhancement. Guest comments → `pending` default + bot protection (mirror entities' public-form guard). Moderation = publishing-scoped surface over comments' existing `published/hidden/deleted/pending` + `bulk_update_status/2`. **Anchored (part-of-post) comments**: comments `metadata` map precedent exists (core AnnotationComposer's `metadata.annotation_uuid`) → `resource_type: "publishing_post"` + `metadata.anchor` on rendered-block ids; degrade to general comment when anchor disappears. |
| 8 | Stats | **Views specifically.** Public show route tracking (hashed IP+UA dedupe window, bot filter, no PII), counter + daily rollup table (core migration), admin views column + sort, popular-posts sort, optional public "N views" chip setting, dashboards widgets. |
| +1 | Audio in posts | Boss extra. Tier 1: `<Audio>` PHK component (native `<audio>`, signed Storage URL; MediaBrowser already supports audio type) + post-level "audio version" slot in `version.data`. Tier 2: AI narration via `PhoenixKitAI.speak/3` (shipped; per-language narration; Oban worker mirroring TranslateWorker; xAI `with_timestamps` → future read-along highlighting). Tier 3: RSS `<enclosure>` + iTunes tags → group-as-podcast. |
| +2 | (unremembered) | Boss has at least one more item Max couldn't recall — slot reserved. |

## Our additions (proposed, Max approved direction 2026-07-25)

- RSS/Atom per group (+ per-category/tag feeds once taxonomy lands) — table stakes, feeds the podcast + newsletter stories.
- JSON-LD `Article` structured data (complements shipped OG work).
- Prev/next post navigation (group chronology, cache-backed).
- Related posts (same category/tags heuristic — sequel to item 4).
- Year/month archive index for timestamp groups (`date_counts` machinery exists).
- New PHK components on the lanes: `PullQuote`, `Gallery`, in-post `TOC` (reads existing heading ids).
- Popular posts (needs views): sort + widgets + count chips.
- Comment counts on listing cards (setting-gated).
- Scheduled publishing (`publish_at` + Oban).
- Draft preview share links (signed URL, pairs with editorial review).
- Author bylines + author archive pages (`created_by_uuid` exists).
- Subscribe-by-email seam via newsletters module (soft dep; "published" event → notify).
- Sitemap coverage verification for publishing URLs.
- **Core extraction proposal**: shared public-form guard (honeypot + time-trap + rate limit) — consumers: entities forms, publishing comments, future contact forms. Needs boss sign-off.

## Cross-repo scope

(Max 2026-07-25: improving other modules alongside ours is in scope when it
makes sense.)

- **phoenix_kit core** — one bundled migration PR: categories tables + views tables. Optionally the public-form guard extraction.
- **phoenix_kit_comments** — guest commenting (nullable `user_uuid` + author name/email — currently `validate_required`), per-resource-prefix moderation filter.
- **phoenix_kit_entities** — read-only reference (bot-protection pattern); second consumer if the guard extracts to core.
- **phoenix_kit_newsletters** — thin seam later; BeamLab-side, keep our half minimal.
- **dashboards / ai** — no changes needed (we implement `phoenix_kit_widgets/0`; `speak/3` + Translatable patterns already shipped).

## Execution log (2026-07-25 session)

- **Done, committed on fork main** (each gate: precommit clean + full suite + quorum round):
  - `f640b7b` step 1 — listing_layout (grid/list/minimal) + card-footer mt-auto pin.
  - `9e5e8eb` step 2 — RSS feeds (/­<group>/feed.xml, Feed module, reserved segment), JSON-LD Article, prev/next nav (show_prev_next), settings toggles.
  - `d8afe84` step 3 — public search (?q=, search_enabled, DBStorage.search_published_post_uuids + cache intersect) + admin in-memory post filter.
  - core `848f5dab` — restore_path before locale validation (fixed internal-prefix leak in language redirects, found in C0).
  - core `9b17027b` — **V159** publishing categories + post_categories + post_views (authored V157, renumbered after upstream sync; prefix oracle green).
  - `bb8425d` step 5 slice 1 — category/post-category schemas + Categories context, public category/tag archives (+descendants rule), term feeds, linked chips (show_categories), cache carries category_uuids + tags.
- `91ae88d` step 5 slice 2 — CategoriesLive admin page (+ group-header link, LV tests), editor CategoriesPicker LC (persists on toggle) + Tags input through the form pipeline.
- `4fe8be1` step 6 — Views: daily rollups, session-cookie dedup (cap = viewed), bot filter, EXIT-safe async record, admin card totals, show_view_counts chip, top_posts window API.
- `87f1739` step 7 — stretch/align on every PHK component (renderer-level negative-margin lanes, viewport-clamped); step 9 extended it to the self-closing inline path.
- `a5a11f9` step 8 — author notes: <Note note="…">phrase</Note> → numbered refs + collected Notes section (no-JS) + CSS-only popovers; code-fence immune; document-sequential.
- `128dac6` step 9 — audio: <Audio> component (signed Storage/https srcs), post audio-version slot (editor field → player above content), RSS podcast enclosures.
- `071fd4f` step 10 — comments over an optional seam: dead-view thread + POST form (honeypot + signed 3s time-trap + CSRF), logged-in only, core POST routes in the dispatch scope; comments module admin = the moderation surface for now.
- core `5838f766` — POST routes in the publishing dispatch scope.

### Follow-ups (surfaced, not silently dropped)
- **Guest commenting** — needs BeamLab's phoenix_kit_comments: nullable user_uuid + author name/email fields (+ core migration); publishing then adds the guest form path (pending status default). Cross-repo — needs Max/BeamLab coordination.
- **Publishing-scoped moderation page** — a filtered surface over comments' status machinery ("maybe" per boss; comments admin covers it today).
- **AI narration (audio tier 2)** — PhoenixKitAI.speak/3 per language + Oban worker + editor action; endpoint-selection UX to design.
- **AI-translatable category names** — third Translatable adapter (group-name pattern) + multilang tabs on the category form.
- **Dashboard widgets** (Top posts / Views this week via Views.top_posts) — publishing implements phoenix_kit_widgets/0 (hello_world reference pair).
- **Popular listing sort** — "popular" in listing_sorts backed by Views window counts.
- **Related posts** — same-category/tag heuristic over the cached maps.
- **PullQuote / Gallery / TOC components** — ride the stretch lanes.
- **Editor annotate-selection toolbar action** — core MarkdownEditor hook change.
- **Restore-path e2e pin** — a publishing test through a real phoenix_kit_routes()-built router (core fix 848f5dab's regression test).
- **Step 11 extras** (scheduled publishing, draft share links, author pages, year/month archives, newsletters subscribe seam, sitemap verification) — opportunistic as planned.
- **i18n catch-up** — ~85 new gettext messages across the wave are extracted but untranslated (et/ru/fr…).
- **Environment notes**: parent server restart needed per publishing/core change (hot-reload misses path deps). Playwright screenshots wedge after first capture — kill `pgrep -f mcp-chrome` + relaunch; geometry probes + curl are the reliable verification. Quorum diffs must include untracked files (`git add -N` first). zai CLI currently errors (ANTHROPIC_API_KEY conflict); agy+grok reliable.
- **Cross-repo state**: core fork merged upstream 1.7.211 (V157/V158 upstream); publishing needs PHOENIX_KIT_PATH=../phoenix_kit until a core release carries V159. Parent dev DB migrates on next boot.

## Sequencing (PR-shaped, order = dependency + value)

1. **Quick wins** — card footer pin (item 3) + `listing_layout` family with minimal date—title (item 2).
2. **RSS/Atom + JSON-LD + prev/next** (unlocks podcast tier later).
3. **Search** (item 1).
4. **Core migration bundle** — categories + views tables (gates 5 & 6).
5. **Categories & tags** (item 4) + related posts + per-term feeds + archives.
6. **Views/stats** (item 8) + popular sort + widgets + chips.
7. **Layout lanes + stretch** (item 5) + PullQuote/Gallery/TOC.
8. **Annotations/notes** (item 6) — after lanes; design sign-off first.
9. **Audio** (+1) — component + narration; podcast enclosures ride the existing RSS.
10. **Comments** (item 7) — comments-module guest PR + integration + moderation + form guard.
11. Newsletter seam / scheduled publishing / share links / author pages — slot in opportunistically.

## Needs boss sign-off

- Annotations design (syntax + reader UX) before build.
- Public-form guard extraction to core.
- Category URL shape (`/blog/category/x` segment? hierarchical permalinks?).
- Guest comments: allowed at all, or logged-in only v1?
- Podcast feeds: worth the iTunes-tag polish?
- The forgotten extra item(s).
