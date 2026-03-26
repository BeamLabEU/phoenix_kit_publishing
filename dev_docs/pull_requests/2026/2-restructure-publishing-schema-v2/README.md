# PR #2: Restructure Publishing Schema V2

**Author**: @mdon (Max Don)
**Co-Author**: Claude Opus 4.6
**Status**: Merged
**Commit**: `50b37a8..cad3463` (5 commits)
**Date**: 2026-03-26

## Goal

Simplify the publishing data model by making posts a minimal routing shell (slug/date identity) and moving all metadata, status, and publishing state to the version level. Remove per-post primary language in favor of a site-wide default.

## What Was Changed

### Schema Changes

**Posts** (columns dropped: `status`, `published_at`, `primary_language`, `data`, `scheduled_at`; columns added: `active_version_uuid`, `trashed_at`):
- Publishing = setting `active_version_uuid` to point to a published version
- Soft delete = setting `trashed_at` timestamp (replaces `status: "trashed"`)

**Versions** (columns added: `published_at`; `data` JSONB expanded):
- Now holds: status, published_at, featured_image_uuid, tags, seo, description, allow_version_access
- Status is version-level — all languages share it

**Groups** (columns added: `title_i18n`, `description_i18n`):
- Reserved JSONB for future i18n support

**Contents** (behavioral change only):
- `status` column kept but unused by UI (reserved for future per-language overrides)
- Content rows now hold only title + body + url_slug

### Files Modified

| Area | Key Files | Change |
|------|-----------|--------|
| Schemas | `publishing_post.ex`, `publishing_version.ex`, `publishing_group.ex` | Field additions/removals |
| Storage | `db_storage.ex`, `mapper.ex` | All queries updated for new fields |
| Business logic | `posts.ex`, `versions.ex` | New publish/unpublish flow via `active_version_uuid` |
| Translation | `translation_manager.ex` | Removed primary language CRUD, status validation |
| Consistency | `stale_fixer.ex` | Rewired for `active_version_uuid` reconciliation |
| Editor UI | `editor.ex`, `helpers.ex`, `persistence.ex`, `forms.ex` | Language switcher moved to content area, version settings sidebar |
| Listing UI | `listing.ex`, `index.ex` | Removed primary language banners |
| Public | `slug_resolution.ex`, `translations.ex`, `post_rendering.ex` | Language resolution respects enabled base codes |
| PubSub | `pubsub.ex` | UUID-only broadcast identifiers |
| Workers | `translate_post_worker.ex` | Uses site default language |
| Deleted | `migrate_primary_language_worker.ex` | Entire file removed |
| Migration | `publishing_tables.ex` | Updated to V2 state |

### API Changes

| Function | Change |
|----------|--------|
| `Publishing.change_post_status/4` | Removed — use `publish_version/3` or `unpublish_post/3` |
| `Publishing.unpublish_post/3` | New — clears active version |
| `Publishing.get_post_primary_language/3` | Removed |
| `Publishing.update_posts_primary_language/1` | Removed |
| `Publishing.count_primary_language_status/2` | Removed |
| `TranslationManager.set_translation_status/5` | Now a no-op (returns `:ok`) |

## Implementation Details

- **Publishing flow**: Save content/metadata to version → call `publish_version/3` which sets version status to "published", sets `post.active_version_uuid`, and archives the previous live version
- **Public listing**: `list_posts_for_listing` now uses `active_version_uuid` to find the live version, filtering out posts without one
- **Language resolution**: `resolve_language_to_dialect` and `resolve_language_for_db` now check enabled languages first before converting base codes to dialects
- **PubSub**: All broadcast identifiers use UUID consistently (fixes timestamp-mode posts where slug is nil)

## Testing

- [x] 412 tests passing, 0 failures
- [x] Integration tests updated for new schema
- [x] Test helpers updated with new factory patterns

## Migration Notes

V88 migration in phoenix_kit core handles:
1. Adding `active_version_uuid`, `trashed_at` to posts
2. Adding `published_at` to versions
3. Adding `title_i18n`, `description_i18n` to groups
4. Data migration: backfill `active_version_uuid` from published versions, `trashed_at` from trashed status
5. Drop legacy columns: `status`, `published_at`, `primary_language`, `data`, `scheduled_at` from posts

## Related

- Migration: `lib/phoenix_kit_publishing/migrations/publishing_tables.ex` (reference/standalone)
- Review: [CLAUDE_REVIEW.md](./CLAUDE_REVIEW.md)
- Previous PR: [#1](/dev_docs/pull_requests/2026/1-extract-publishing/)
