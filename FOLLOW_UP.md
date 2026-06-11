# Follow-up — adversarial full-module audit

After-action report for the fixes made in response to the adversarial review of
`phoenix_kit_publishing`. All work is local commits on top of `5e4582a`; nothing
pushed. Suite (with the integration tier actually running): **1126 tests, 0
failures**, stable across repeated runs; `mix format`, `mix credo --strict`, and
`mix dialyzer` all clean.

> Note on the test tier: the integration suite (`:integration`, ~520 tests) only
> runs when the Postgres test DB exists. It is present and running here, so the
> 1126 count includes it — every fix below was exercised against the DB tier.

## Fixed (with regression tests unless noted)

### High
- **H1** — the `:publishing_posts` render cache was never supervised, so caching
  silently no-op'd and every published view re-rendered. Declared it as a
  supervised, size-bounded child of `Publishing.children/0`.
- **H8** — `allow_version_access` was missing from the cached listing map, so the
  public version dropdown only appeared on a cache miss. Mirrored it in all
  `build_listing_metadata/4` clauses.
- **H4** — disabled-module requests 302-looped to the same URL forever; added a
  `:module_disabled -> :no_fallback` clause (renders 404).
- **H5** — future-dated timestamp posts in ≥2 languages 302-ping-ponged forever;
  applied the future-date gate in the language-fallback chain.
- **H3** — `RouterDispatch` hijacked any host URL whose 2nd segment matched a group
  (`/company/news`, `/api/news`); now requires segment 0 to be an enabled language
  and passes through non-GET/HEAD requests.
- **H2** — the previous-slug 301 system had no writer; `upsert_post_content` now
  records the old `url_slug` in `previous_url_slugs` on a rename (deduped, drops
  the new slug so a revert can't self-redirect).
- **H6** — read-only collaborative spectators could drive several write paths
  (autosave, editor_content_changed, preview, translate_*, create_version);
  added the missing `readonly?` guards.
- **H9** — editor reload paths read the latest version while pinned to an older
  one; `re_read_post` now defaults to the socket's `current_version`.

### Medium
- **M1** — the timestamp-collision retry matched the wrong changeset key (`:post_*`
  instead of the composite's first field `:group_uuid`); now matches the
  constraint name like `StaleFixer.slug_conflict?`.
- **M2** — `find_available_timestamp` probed with a trashed-excluding query while
  the unique index includes trashed rows; added trashed-inclusive
  `DBStorage.timestamp_slot_taken?/3`.
- **M3** — the three coupled writes of a post update were non-transactional, so a
  failure between the content-row wipe and the version-level promotion destroyed
  the legacy V1 keys; wrapped them in one transaction.
- **M6** — UUID lookups ignored the URL group (`/<any-group>/<uuid>` served a
  foreign post; editor minted slugs against the wrong group); both paths now
  require the post to belong to the requested group.
- **M8** — the regeneration-lock ETS table was owned by a transient request
  process and died with it (later lock ops 500'd a read); added a supervised
  `ListingCache.LockTableOwner`.
- **M9 (partial)** — the read-path empty-post hard-delete 500'd on a
  concurrent-delete race; rescued `Ecto.StaleEntryError`. (Design questions below.)
- **M10** — markdown prose normalizers corrupted fenced code (indentation strip,
  `&nbsp;` injection); they now run only on prose between code regions.
- **M11** — multi-line `<Image\n …/>` (spec-canonical) wasn't detected as a
  component; detection now matches `<Image` + any whitespace/`>`.
- **M12** — raw HTML in a fence rendered live on the plain path; code regions are
  now escaped on that path too.
- **M13 (partial)** — `url_slug_exists?` failed open on a DB error; now fails
  closed. (Remaining parts below.)
- **M15** — switching version/language mid-translation left the editor locked;
  `handle_params` now resets the translation lock on each post-scope load.
- **M16** — the admin group-insight counted published-only on a warm cache and
  all-non-trashed on a cold one; always reads `list_posts` now.

### Low
- **L1** — `switch_version` crashed the LV on a non-integer `?v=`; parses
  defensively via `parse_version_param/1`.

## Surfaced for your decision — NOT changed

These are real findings I deliberately did not fix autonomously (out of scope,
invasive, a product decision, or environment-specific). Each needs your call.

- **M4 — publish atomicity.** `update_version_defaults` can commit
  `status="published"` while the paired `Versions.publish_version` (separate
  transaction) rolls back, leaving published-with-no-active-version (admin shows
  published, public 404s). Fixing it means either making publish atomic
  (restructuring the publish flow) or adding a StaleFixer demotion rule — both
  carry real risk of breaking publish. Recommend we pair on the approach.
- **M5 — per-post SEO/OG overrides are write-only.** `params["seo"]` is persisted
  but `get_seo` has no readers and `build_metadata`/`build_og_data` never expose
  it, so stored `og_title/og_description/og_image` overrides never render. This is
  a half-built *feature* (not a regression); wiring the read side is functionality
  to add, so it's your call whether to finish or drop it.
- **M7 / M14 — clustered-deploy only.** No cross-node cache invalidation (the
  `:cache_changed` PubSub handler is a no-op), and `PresenceHelpers` calls
  `Process.alive?/1` on possibly-remote pids (raises on 2+ nodes). N/A for
  single-node hosting; fix if/when we cluster.
- **M9 design parts.** Beyond the race fix: the empty-post deletion is a *hard*
  delete on the *read* path (the code's stated rationale is avoiding a
  restore→trash loop), `content_empty?` ignores `version.data` (a
  featured-image-only version counts as empty), and it writes no ActivityLog /
  cache invalidation. Whether to trash-instead-of-delete and/or move it to a
  batch pass is a design decision.
- **M13 remaining.** No DB unique index backs `url_slug` (adding one is a **core**
  migration); the read-path auto-renamer is newest-wins with no previous-slug
  record; and `validate_url_slug` doesn't reject claiming another post's previous
  slug (now that H2 makes previous slugs real, this can hijack 301 traffic).
- **H7 — `<Hero>`/`<Page>` components don't exist.** The PageBuilder resolves them
  to `Shared.Components.{Page,Hero}`, which core doesn't ship, so every `<Hero>`
  block renders an error div. Decision: ship the components in **core** or cut the
  resolver clauses + spec sections here.
- **Core-side (`phoenix_kit`) signed-file URLs.** Tokens are 16-bit, never expire
  (the "expired token" message is false), `/api/files/:uuid/info` hands out valid
  signed URLs for any uuid, and a nil `secret_key_base` degrades to a predictable
  no-secret hash. Low impact for public post images; out of scope for this module.
- **Remaining Lows (L2–L12) + nits.** e.g. preview swallows a save failure (L2);
  pre-lock read in `do_unpublish_post` (L3); non-transactional blank-version
  creation (L4); timestamp timezone inconsistency between create vs edit (L5);
  group-slug rename doesn't invalidate the old cache entry (L6); double-backtick /
  blockquoted-fence code spans aren't masked from component detection (L8);
  per-save `:persistent_term` churn / GC pressure (L12); `should_create_new_version?`
  hardcoded `false`; dead preview-token feature. Happy to work through these in a
  follow-up pass — flagging rather than parking them.
