# Follow-up Items for PR #2

Post-merge review of CLAUDE_REVIEW.md findings against current code on `main`. The 0.1.1 follow-up commit (`07fcd85`) already resolved findings #1, #3, #4 plus credo cleanup; this batch closes the remaining seven structural items + the partial-index naming nit.

## Resolved before this sweep (carried over from the 0.1.1 commit)

- ~~**#1** `Code.ensure_loaded?` for internal modules~~ — fixed in `07fcd85`; `db_storage.ex` and `mapper.ex` use `LanguageHelpers.get_primary_language/0` directly via alias.
- ~~**#3** `set_translation_status` silent no-op~~ — fixed in `07fcd85` with a `Logger.warning` deprecation notice on every call. Test suite confirms the warning fires.
- ~~**#4** Duplicate `site_default_language/0`~~ — fixed in `07fcd85`; both copies removed.

## Fixed (Batch 1 — 2026-04-26)

- ~~**#2** `active_version_uuid` FK without preload strategy~~ —
  `db_storage.ex:108-127` (`get_post/2`), `:140-158` and `:160-202`
  (`get_post_by_datetime/3` both clauses) now `preload: [group: g,
  active_version: :post]`. `db_storage.ex:347-365` (`get_active_version/1`)
  reads from the preloaded association first, falling back to the FK
  lookup only when callers pass a hand-built post struct without the
  preload. Single-post detail reads now do one round trip instead of
  two.
- ~~**#5** Trashed-status query rebuilt entire base query~~ —
  `db_storage.ex:200-228`. `list_posts/2` now builds the base query
  WITHOUT `is_nil(p.trashed_at)`, then dispatches to a tiny
  `filter_by_status/2` (4 clauses) that adds the appropriate
  `trashed_at`/`active_version_uuid` predicates per status. Future
  base-query refinements (extra joins, preloads) compose into every
  branch instead of being silently dropped by the trashed branch.
- ~~**#6** `update_post_in_db` issues 2-3 DB round trips per save~~ —
  `posts.ex:891-936`. `maybe_sync_post_datetime/2` and
  `maybe_update_audit_fields/2` collapsed into a single
  `maybe_sync_datetime_and_audit/3` that builds a merged attrs map and
  issues one `DBStorage.update_post/2` call. Halves the per-save round
  trips on the post row and keeps `updated_at` consistent across the
  two concerns.
- ~~**#7** `preserve_content_data` silently dropped non-whitelisted keys~~ —
  `posts.ex:737-751, 825-895`. The investigation confirmed the V2
  architecture intentionally moves `description`/`featured_image_uuid`/
  `seo_title`/`excerpt` from content rows to versions, but the V88
  data migration only backfilled them — pre-existing legacy values
  on `content.data` were being wiped on the next save. New flow:
  - `collect_legacy_content_promotions/2` reads the existing content row,
    diffs against `version.data`, and returns a map of legacy V1 keys
    that are present on content but absent from version.
  - `update_version_defaults/4` now takes the promotion map and
    `Map.merge`s it into version.data BEFORE applying user updates, so
    legacy values fall through unchanged when the user didn't touch
    them.
  - `preserve_content_data/3` now whitelists three keys
    (`previous_url_slugs`, `updated_by_uuid`, `custom_css`) — the
    genuinely per-language fields the V2 schema documents.
  - `log_legacy_metadata_promoted/3` writes a
    `publishing.content.metadata_promoted` activity row when anything
    is promoted (idempotent, runs at most once per legacy row).
  AGENTS.md activity table extended to document the new action.
- ~~**#8** Slug-mode posts collapsed onto inserted_at after V2 ordering change~~ —
  `db_storage.ex:868-892`. `order_by_mode/1` now `coalesce`s
  `post_date`/`post_time` against `inserted_at` casts, so slug-mode
  posts (which have nil `post_date`/`post_time`) sort by their own
  inserted_at instead of clustering at the top under PostgreSQL's
  default `NULLS FIRST DESC` ordering. Timestamp-mode behaviour is
  unchanged. Comment in the helper spells out why coalesce is needed.
- ~~**#9** Hardcoded `"Untitled"` literal in three places~~ —
  `web/controller/translations.ex:80-83, 257-275`. All three
  comparisons now use `Constants.default_title()` (added to the alias
  list at the top of the module). One callsite that needed the value
  twice computes it once via a `default_title` local for readability.
- ~~**#10** Unused `_group_slug` parameters in translate worker~~ —
  `workers/translate_post_worker.ex:101, 662, 823, 901`.
  `skip_already_translated/5` → `/4`, `translate_content/4` → `/3`,
  `translate_now/4` → `/3`. The internal call site at `:101` updated
  to match. Test file
  `test/phoenix_kit_publishing/integration/translate_retry_test.exs`
  updated for the new arity (group_slug bindings dropped where they
  were only there to feed the param). `translate_content`/`translate_now`
  are public-but-unused outside this module — checked
  `lib/`/`test/`/`README.md`/`AGENTS.md`; safe to drop the param.
- ~~**#11** Partial index name doesn't indicate it's partial~~ —
  `migrations/publishing_tables.ex:135-141`. Renamed
  `idx_publishing_posts_trashed_at` →
  `idx_publishing_posts_active_where_trashed_null`, with a comment
  explaining the WHERE clause. Standalone migration only — core's V88
  is the production migration and its index name is unchanged (parent
  app already has the index under the old name; this rename only
  affects fresh installs that run the standalone migration).

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_publishing/db_storage.ex` | #2 preload `:active_version` on `get_post/2` + both `get_post_by_datetime/3` clauses; preload-aware `get_active_version/1`. #5 `filter_by_status/2` extraction. #8 coalesce-based `order_by_mode/1`. |
| `lib/phoenix_kit_publishing/posts.ex` | #6 batched `maybe_sync_datetime_and_audit/3`. #7 `collect_legacy_content_promotions/2`, `log_legacy_metadata_promoted/3`, expanded `preserve_content_data/3` whitelist, `update_version_defaults/4` with `legacy_promotions` arg. |
| `lib/phoenix_kit_publishing/web/controller/translations.ex` | #9 alias `Constants`, replace 3× `"Untitled"` literal. |
| `lib/phoenix_kit_publishing/workers/translate_post_worker.ex` | #10 drop `_group_slug` from 3 public functions; update internal call site. |
| `lib/phoenix_kit_publishing/migrations/publishing_tables.ex` | #11 rename partial index to encode the WHERE clause. |
| `test/phoenix_kit_publishing/integration/translate_retry_test.exs` | #10 follow drop of `group_slug` arg in 3 call sites. |
| `AGENTS.md` | #7 add `publishing.content.metadata_promoted` action to the activity-logging table. |

## Verification

- `mix compile --warnings-as-errors` ✓
- `mix format` ✓
- `mix test` — 451 tests, 0 failures (matches baseline; pre-existing sandbox-ownership / activity-table-missing warnings unchanged)
- `mix dialyzer` — 0 errors (pre-sweep state)
- `mix credo --strict` — clean (pre-sweep state)

## Open

None.
