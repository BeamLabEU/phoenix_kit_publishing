# PR #2 Review: Restructure Publishing Schema V2

**PR:** BeamLabEU/phoenix_kit_publishing#2
**Author:** Max Don (@mdon)
**Status:** Merged
**Stats:** +1,451 / -2,247 lines across 45 files (5 commits)
**Co-authored with:** Claude Opus 4.6

---

## Summary

Major architectural overhaul of the publishing module's data model. Posts are demoted from holding content/status/metadata to being pure "routing shells" (slug + date/time + pointer to the live version). Versions become the single source of truth for published state and metadata. The per-post `primary_language` concept is removed entirely in favor of a site-wide default.

---

## Architecture Changes

### Before (V1)
- **Post** held: `status`, `published_at`, `primary_language`, `data` JSONB (tags, seo, featured_image), `scheduled_at`
- **Content** rows held per-language `status` (each language published independently)
- Primary language was stored per-post and required migration workers when the global setting changed

### After (V2)
- **Post** is a routing shell: `slug`, `mode`, `post_date`, `post_time`, `active_version_uuid` (FK to live version), `trashed_at` (soft delete)
- **Version** is source of truth: `status`, `published_at`, `data` JSONB (featured_image_uuid, tags, seo, description, allow_version_access)
- **Content** rows hold only: title, body, url_slug (status/data columns reserved for future per-language overrides)
- Publishing = setting `post.active_version_uuid`; Trashing = setting `post.trashed_at`
- All languages share version-level status (no per-language publish)
- Site default language used everywhere instead of per-post primary_language

---

## What Was Done Well

### 1. Clean Separation of Concerns
The post-as-routing-shell model is a significant simplification. URLs are determined by the post (slug or date/time), while everything about "what's published" lives on the version. This eliminates a class of bugs where post-level and version-level status could get out of sync.

### 2. Thorough Removal of Primary Language
The removal of `primary_language` from posts is complete and consistent. All 45 files were updated, the migration worker was deleted, the UI banners were removed, and every reference to `post[:primary_language]` was replaced with `LanguageHelpers.get_primary_language()`. No half-measures.

### 3. Public Listing Fix
The `list_posts_for_listing` function now correctly uses the **active (published) version** instead of the latest version. This fixed a real bug where draft content or unpublished posts could leak through to the public site.

### 4. PubSub Simplification
Switching broadcast identifiers from `slug || uuid` to just `uuid` removes an ambiguity that was causing silent failures for timestamp-mode posts (where slug is nil).

### 5. Soft Delete via Timestamp
Replacing `status: "trashed"` with `trashed_at` is a good pattern - it preserves the deletion timestamp, allows proper `restore_post/2`, and separates the "trashed" concern from the publishing lifecycle.

### 6. Test Coverage
412 passing tests, 0 failures. The integration test changes are thorough and match the new schema design.

---

## Issues and Concerns

### Critical

#### 1. ~~`Code.ensure_loaded?` for Internal Module~~ FIXED
`db_storage.ex` and `mapper.ex` both used `Code.ensure_loaded?(LanguageHelpers)` to guard against the module not being available, silently falling back to `"en"`. Replaced with direct `LanguageHelpers.get_primary_language()` calls via alias.

#### 2. `active_version_uuid` FK Without Preload Strategy
The new `belongs_to :active_version` association on `PublishingPost` is never preloaded in any of the queries that fetch posts. Instead, `get_active_version/1` does a separate `repo().get(PublishingVersion, uuid)` call. For batch operations (listing pages), this means N+1 queries. The batch loader already fetches all versions per post, so this is mitigated in `list_posts_for_listing`, but `resolve_version/2` for single-post reads will do an extra query when it could preload.

#### 3. ~~`set_translation_status` Is a No-op That Returns `:ok`~~ FIXED
`set_translation_status` was a silent no-op. Added `Logger.warning` deprecation notice so callers are alerted. The function is still delegated from `Publishing` facade and tested — kept for backward compatibility but now logs on every call.

### Moderate

#### 4. ~~Duplicate `site_default_language/0` Functions~~ FIXED
Both `db_storage.ex` and `mapper.ex` had identical private `site_default_language/0` functions. Removed both and replaced with direct `LanguageHelpers.get_primary_language()` calls via alias.

#### 5. `trashed` Status Query Rebuilds Entire Query
In `db_storage.ex:203-210`, when `status == "trashed"` is requested, the entire query is rebuilt from scratch instead of modifying the existing one. This means the base `is_nil(p.trashed_at)` filter is discarded and replaced, but if any future code adds more conditions to the base query, they'll be silently lost.

```elixir
"trashed" ->
  # Override the trashed_at filter for listing trashed posts
  from(p in PublishingPost,
    join: g in assoc(p, :group),
    where: g.slug == ^group_slug and not is_nil(p.trashed_at),
    preload: [group: g]
  )
```

#### 6. Two Separate `update_post` Calls in `update_post_in_db`
The save path now calls `DBStorage.update_post` potentially 3 times per save: once for `maybe_sync_post_datetime`, once for `maybe_update_audit_fields`, and potentially once from the version update. Each is a separate DB round-trip. These could be batched into a single update.

#### 7. `preserve_content_data` Drops Data
`posts.ex:487-489` throws away everything except `previous_url_slugs` from content data. If any content rows have accumulated other data keys (from previous versions of the code or manual DB edits), they'll be silently lost on the next save.

```elixir
defp preserve_content_data(existing_data, _params, _post) do
  Map.take(existing_data, ["previous_url_slugs"])
end
```

#### 8. Ordering Changed Without Migration Path
`order_by_mode/1` changed from `desc: p.published_at, desc: p.inserted_at` to `desc: p.post_date, desc: p.post_time, desc: p.inserted_at`. For slug-mode posts that don't have `post_date`/`post_time`, this will sort them all as `nil, nil` and fall back to `inserted_at`. The old behavior sorted by `published_at`. This is a behavioral change for slug-mode groups.

### Minor

#### 9. `has_content?` Check Uses Hardcoded "Untitled"
`translations.ex:82` checks `title != "Untitled"` as a string literal, but the constant exists as `Constants.default_title()`. Should use the constant for consistency.

#### 10. Unused `_group_slug` Parameters
`translate_post_worker.ex:823` and `:935` renamed `group_slug` to `_group_slug` but kept it in the function signature. If the parameter is no longer needed, consider whether the public API contract should change.

#### 11. Index on `trashed_at WHERE trashed_at IS NULL`
`publishing_tables.ex:133-135` creates a partial index on `trashed_at` filtered to `WHERE trashed_at IS NULL`. This is correct for filtering active posts, but the index name `idx_publishing_posts_trashed_at` doesn't indicate it's partial, which could confuse future developers.

---

## Deleted Code (Significant)

| File/Module | Lines Removed | Purpose |
|---|---|---|
| `migrate_primary_language_worker.ex` | 145 lines | Entire Oban worker for primary language migration |
| `listing_cache.ex` | 92 lines | Primary language migration helpers |
| `translation_manager.ex` | 183 lines | Primary language CRUD, status validation |
| `stale_fixer.ex` | 216 lines | Language fixing, status reconciliation, primary content fixing |
| `editor.ex` | 354 lines | Primary language UI, per-language status controls |
| `listing.ex` | 249 lines | Primary language banners, per-primary language controls |
| `index.ex` | 85 lines | Primary language migration UI |
| `posts.ex` | 119 lines | `change_post_status`, status propagation logic |

---

## Migration Considerations

- **V88 migration** in phoenix_kit core handles the schema changes (adding `active_version_uuid`, `trashed_at`, `published_at` on versions; dropping `status`, `published_at`, `primary_language`, `data`, `scheduled_at` from posts)
- The standalone migration in `publishing_tables.ex` is the "ideal state" reference, not used for actual migration
- Data migration should handle: existing published posts need `active_version_uuid` pointed to their published version; `trashed` status posts need `trashed_at` backfilled
- **No rollback path** mentioned for the data migration - if V88 needs to be reverted, the dropped columns are gone

---

## Verdict

This is a well-executed architectural simplification that removes ~800 net lines while making the data model significantly clearer. The core insight (posts as routing shells, versions as source of truth) is sound and eliminates real bugs around status inconsistency between posts, versions, and content.

The main risks are around the migration path (destructive column drops with no rollback) and some implementation shortcuts (duplicate helper functions, multiple DB calls per save, silent no-ops). The `Code.ensure_loaded?` pattern should be addressed before it spreads further.

**Recommendation:** The design is solid. Address the `Code.ensure_loaded?` guards and the duplicate `site_default_language` functions as follow-up. Monitor for N+1 query issues on post detail pages where `resolve_version` now does a separate lookup.
