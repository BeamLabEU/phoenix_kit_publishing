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

### Boss feedback round 2 (2026-07-29)
- **Hashtag tags (this commit)** — tags moved INTO the body: `#elixir` in the
  prose is the tag system; the sidebar Tags input is gone. Save derives
  `version.data.tags` from the union of hashtags across the version's language
  bodies (explicit `"tags"` list still honored — normalized — for content-less
  API callers; content wins when both are sent). Public + preview render
  hashtags as tag-archive links (mask: code, unclosed fences, markdown links,
  PHK components/attributes; notes' `#` entity-encoded). Cache v6. Public
  tag archives/feeds/chips unchanged.
- **Pending on the editor developer**: popup-suggestion API in the core
  MarkdownEditor — when it lands, feed it group-level tag suggestions
  (distinct tags across the group's posts) for `#` autocomplete.
- **Category page modernization (this commit)** — CategoriesLive rebuilt in
  the catalogue/entities house style: full-width indented tree table
  (folder/tag icons, per-depth padding), SortableGrid handle-only drag
  reorder among siblings (server groups by EXISTING parent and renumbers
  the FULL sibling group — drag can never re-parent; stale partial payloads
  can't collide positions), kebab `<.table_row_menu>` (Edit / New
  subcategory / Move to… / Delete), Move-to dialog (depth-indented picker,
  self+descendants excluded, preselects the current parent,
  `move_category/3` appends at the end of the new sibling group), modal
  add/edit form. Every uuid event is page-group-scoped (foreign uuids
  rejected). Deliberately NOT drag-onto-row nesting: catalogue/entities
  both use menu/dialog re-parenting; mixing SortableJS with native HTML5
  DnD on the same rows conflicts.
- **Core follow-up (surfaced, not fixed here)**: core MarkdownEditor's
  textarea syncs content via `phx-keyup` — value changes without key
  events (paste via context menu, drag-dropped text, automation `fill`)
  never reach the server and silently save empty. Should be `phx-change`
  (input event). Found while browser-verifying hashtags.

### Boss feedback round 3 (2026-07-29)
- **Note styles, properly labeled (this commit)** — group setting
  `notes_style`: "Footnotes — numbered refs, notes collected at the
  bottom" (default, the original) | "Slide-out panel — click the phrase,
  note opens on the right". Panel style: refs target per-note fixed
  panels rendered by the POST TEMPLATE (never baked into cached HTML);
  pure CSS `:target` slide-in, backdrop/✕ close back to the phrase; hover
  popover kept in both styles. Cache key gets a `:np` token in panel mode.
- **Comments on notes** — each panel carries its own comment list + form;
  comments store `metadata["note_id"]` = 12-char content digest of the
  note text (`Renderer.note_dom_id/2`; duplicates get occurrence-suffixed
  digests). Note comments are excluded from the main-thread count; the
  POST redirect reopens the panel via the fragment.
- **Threaded replies** — the comments module's native `parent_uuid`/
  `depth`/max-depth; publishing's seam validates the parent is a
  published comment on the SAME post (module doesn't check resource
  ownership) and replies inherit the parent's `note_id` (client-sent
  note_id ignored on replies — threads can't straddle the panel and the
  main list). Reply forms behind `<details>` (no JS); recursive
  `comment_node` rendering with indent; success redirects anchor from the
  CREATED comment's stored thread location.
- **Panel threads + no-reload posting (Max feedback, same day)** —
  note-panel comment lists are now full TREES with the same `<details>`
  Reply controls as the main thread (seam builds per-note trees;
  `tree_size/1` drives the panel header count). All comment forms carry
  `data-pk-comment-form`; an inline enhancement script (same pattern as
  `reading_progress/1`) POSTs over fetch (`x-pk-comment-fetch` header →
  the controller answers JSON 200/422 instead of flash+redirect) and
  swaps `#comments` + `#pk-note-panels` in place — no page reload, scroll
  and the open panel survive (`.pk-open` mirrors `:target`, which
  browsers drop when the target node is replaced; cleared on hashchange).
  A refetch/swap failure downgrades to `location.reload()` — never a
  re-POST (duplicate-comment guard); a failed/non-JSON POST falls back to
  the native form submit. No-JS behavior unchanged (flash + redirect
  reopens the panel via the fragment).
- **Known limits (deliberate, surfaced)**: `note_id` is format-validated
  but not checked against the post's actual notes (junk ids from a
  logged-in client create comments visible only in the comments admin —
  listing content isn't available in the POST path without extra reads);
  the CSS-only dialog has no focus trap/aria-modal (inherent no-JS
  limits; panel aside is focusable via tabindex).

### Boss feedback round 4 (2026-07-29)
- **Categories moved below the post body** — they're filing metadata, not
  something a reader needs before the first paragraph. Chips unchanged
  (still gated on `show_categories`, still link to the archives); only the
  position moved. Pinned by an ordering assertion, not just presence.
- **Tags are no longer listed on the post page** — and the `show_tags`
  group setting is retired end-to-end (constants/spec/form/accessor/
  template/defaults) rather than left as a control that does nothing.
  Rationale: since tags became body hashtags, the chip row repeated links
  the prose already renders. Tag ARCHIVES, feeds and the content-less
  `"tags"` API path are untouched. Consequence worth knowing: a post whose
  tags were set through the API path (no hashtags in its body) now shows
  no tags anywhere on its page.

### Single-source tags (2026-07-29, after Max confirmed no released version)
- The dual write path is gone: a caller-supplied `"tags"` list is now
  **ignored**, so the body is the only source. `Hashtags.normalize/1` went
  with it. Invariant restored: every tag a post carries appears in its prose
  — which is what makes dropping the chip row safe.
- Surfaced while doing it: `create_post/2` never derived tags at all
  (`create_version` wrote no `data`), so a post created in one shot with
  content — import, API, fixtures — rendered its `#hashtags` as archive
  links while missing from those archives until something re-saved it. The
  editor's create-then-save flow hid it. Fixed at the create transaction.

### `<Showcase>` band (2026-07-29, boss's alternative image look)
- Image bled to one edge, Markdown text on the other, sharing an `overlap`
  grid track; `side`, `overlap` (0–40), `tone` (dark/light/none),
  `file_uuid`/`src`, full-bleed by default with align/stretch passthrough.
- `tone` decides the band's colours. Default is `page` (base-100 /
  base-content), so the band is invisible against the page and the image
  dissolves into it; `dark`/`light` paint a deliberate band. The first cut
  defaulted to a hardcoded near-black, which Max reported as "black
  background where there isn't an image" — the reference design works only
  because that whole page is black.
- Scrim strength scales with `overlap` (more text over image ⇒ more tint);
  narrow screens stack, overlap goes total, and the scrim becomes a vertical
  wash. Pure CSS, no JS. Render cache → v7.
- Known house-wide limit pinned by a test: a `>` inside any component
  attribute value ends the opening tag early (every component scans with
  `[^>]*`). It degrades to an empty attribute, never raw markup.
- Author controls, both asked for after seeing it live: `height`
  (short/medium/tall/pixels, omit for natural aspect — a full-bleed band's
  natural height was ~600px) and the width lane. `align="none"` is now an
  explicit value in the SHARED `stretch_style/1`, so any component whose
  default is full-bleed can opt back into the text column.

### Quorum sweep 2026-07-30 (6 AIs over the whole wave)
Areas split three ways; two AIs each. **Fixed in `<commit>`:**
- Comment posted while moderation is ON said "Comment posted." while the
  thread (published-only) showed nothing — now says it's awaiting review.
- The fetch enhancement could double-post: a LOST SUCCESS response is
  indistinguishable from a pre-store failure, and it fell back to a native
  resubmit. Now reloads instead — never resubmits.
- A note comment whose note no longer exists (author reworded it, or the group
  switched back to footnotes) was stored but rendered nowhere: excluded from
  the main list for having a note_id, never read by any panel. Unknown ids now
  fold back into the main thread. Note this fixes the REWORDED-note case that
  POST-side id validation (both AIs' suggestion) could not.
- `for_post_page/2` was the one unrescued call in the seam, on every public
  post render — a raise there 500s a page that used to degrade to "no comments".
- In-panel reply forms now carry `note_id` for ANCHORING, so a no-JS validation
  error returns to the open panel instead of a comment inside a closed one.
- `linkify/2` only links what `extract/1` stores: the 21st tag past the cap was
  a link to an archive that can't find the post. Same class fixed for
  "`code`#tag" / "[link](/x)#tag", where the mask invented a word boundary the
  extractor never saw.
- Raw HTML attributes are masked: `<span style="color: #fff">` minted a phantom
  `fff` tag AND rewrote the declaration into a markdown link, breaking the CSS.
- A `<Showcase>` body is markdown, so its hashtags now extract and link (the
  generic component mask had swallowed the whole block); raw-body components
  (`<Video>` et al) stay masked, where a markdown link would show literally.
- Note superscript used daisyUI 4's `oklch(var(--p))`; now `var(--color-primary)`.
- `clear_audio` never called `schedule_autosave/1`, so clicking X and waiting
  left the field looking empty while the audio stayed attached. Now delegates to
  the shared clear pipeline (autosave + broadcast + lock reclaim + guards).
- The audio media picker accepted any file type — a PNG gave a dead `<audio>`
  and an `<enclosure type="audio/mpeg">` pointing at an image. Now refused.
- The Move-to dialog pre-selects the current parent, so submitting it untouched
  appended the row at the end of its own group. Now a no-op.
- A cross-parent drag is discarded by design but flashed success while the row
  snapped back; now says to use Move-to.

**Deferred (design work, not defects to patch):**
- **Tag maintenance is not transactional.** Parallel AI translation jobs each
  compute the cross-language union and replace `version.data`, so the last
  writer can drop the other's tags; `clear_translation` deletes a body without
  recomputing, leaving a tag whose text no longer exists anywhere. Codex's fix:
  one `refresh_version_tags/1` called after every content mutation, under a
  version-row lock. Wants doing before the AI pipeline is used in anger.
- **Per-language vs version-wide tags** — a tag only in the Estonian body makes
  the English archive list the post. Genuine product question for Max.
- **CSS in the cached body.** Notes/showcase stylesheets are appended to each
  post's cached HTML: kilobytes per post, and `<style>` in `<body>` breaks under
  a strict CSP. Three AIs independently raised it. Fix shape: return
  `%{html:, assets: [:showcase, :notes]}` and let the template emit each once.
- **Fetch path re-fetches the whole page** to swap two sections (re-runs group
  fetch, post resolution, note scan, full render). Return the two fragments in
  the JSON instead.
- **Panel a11y** — `role="dialog"` with no `aria-modal`, focus move, focus trap
  or Escape. Keep `:target` as the no-JS baseline, enhance progressively.
- **Comment POST proves post membership via the listing cache** (capped 5000),
  so a post past the cap is readable but not commentable. Cheap DB check instead.
- **Depth-aware Reply UI** — hide Reply at max depth instead of failing on submit.
- `move_category` reads `max(position)` outside the update transaction; two
  concurrent moves into one parent can tie.
- Cache key omits language-routing config, so toggling prefix policy can serve
  cached bodies with stale `/en/...` tag links.

**False positives worth recording** (all disproved by running code, not argued):
Gemini claimed `Regex.split(include_captures: true)` also emits capture groups
(it does not — only the full match), that `render_markdown_html/1` was
undefined, and that notes/hashtags duplicate text; Vibe claimed
`reorder_categories/3` returns a bare integer and crashes the LV (it is wrapped
in `repo().transaction/1`, so it returns `{:ok, count}` — and a passing test
asserts exactly that).

### Editor pass + quorum round 2 (2026-07-30)
Core bumped 1.7.214 -> 1.7.220. **The editor suggestions API we spec'd is NOT
in any release** — 1.7.220's MarkdownEditor has no suggestions hook and still
syncs content on `phx-keyup`. Verified against Hex and both core remotes.

Fixed (work-loss first):
- Body typing never refreshed the collaborative lock, so a prose-only session
  let its own lock lapse; afterwards keystrokes were dropped and Save wrote the
  stale pre-lapse buffer.
- The lapsed banner said "start typing to resume" but `readonly?` disabled the
  very fields that would trigger the reclaim — a catch-22. Now an explicit
  "Resume editing" button.
- Autosave blocked on a blank title returned in silence behind an "Unsaved
  changes" badge; the badge now states the reason, recomputed on every edit
  (a save-only reset left it stuck when the fix also made the form clean).
- EVERY buffer-replacing navigation now flushes first (version switch, language
  switch, create-version, translation enqueue) — the version path was fixed and
  the language path missed on the first pass, which is why the pin now covers
  the whole set. Translation also enqueued from stale source text.
- The slug-conflict modal reopened on every keystroke.
- A successful save clears a prior `:error`, since update_meta now deliberately
  keeps errors across keystrokes.
- Six dead handle_event clauses: two were features missing only a control
  (`regenerate_slug` button, `allow_version_access` checkbox), four deleted.
  `allow_version_access` had NO write path either, and its public gate only
  served currently-published versions — but publishing v2 archives v1, so
  every historical URL 404'd and the dropdown could never hold more than the
  active version. "Browse older versions" now means previously published.
- `regenerate_slug` marked dirty without arming autosave (same hole
  `clear_audio` had); `:editor_save_requested` was a latent fake Save.

Deferred (design work):
- **Owner disconnect during lock handoff loses the synchronized buffer.** A
  promoted spectator reloads from the DB, discarding the newer content it had
  already received live. Wants revisioned collaboration (broadcast a revision,
  only reload when the DB copy is at least as new) — three AIs pointed at the
  same shape.
- **One transition function** for every buffer-changing action instead of
  flush calls sprinkled per site; likewise one `apply_local_edit` wrapper so the
  next half-wired control can't skip lock/autosave/broadcast again. Both
  recurrences this session (clear_audio, regenerate_slug) were that class.
- Content can be one 400ms debounce behind the textarea, so even a perfect
  flush may miss the last keystrokes — needs a flush-on-demand from the editor
  component.
- Same-user multi-tab: both tabs own the lock and neither applies the other's
  changes.
- `allow_version_access` is stored per version but reads as post-wide policy.

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
