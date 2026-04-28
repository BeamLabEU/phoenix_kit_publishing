# Changelog

## 0.1.5 - 2026-04-28

PR #10 — quality sweep + 4 coverage-push batches (33.34% → 63.79% line coverage).

### Added
- `PhoenixKit.Modules.Publishing.Errors` — central atom-to-gettext mapping (36 atoms + 4 tagged-tuple shapes) plus `truncate_for_log/2` to cap unbounded log payloads (AI responses, HTTP errors).
- `PhoenixKit.Modules.Publishing.ActivityLog.log_failed_mutation/5` — writes a `db_pending: true` audit row when a user-driven mutation fails, so the audit trail still captures intent on DB constraint failures.
- Activity logging on every Posts / Groups / Versions / TranslationManager mutation (success and failure paths).
- `phx-disable-with` on every async / destructive admin button.

### Changed
- **PubSub payload contract** — `broadcast_post_created/2`, `broadcast_post_updated/2`, `broadcast_post_status_changed/2`, and `broadcast_version_created/2` now emit a minimal `%{uuid:, slug:}` payload instead of the full post map. Receivers should refetch the post via `Publishing.read_post/4` (or any of the read helpers) rather than destructuring the broadcast. Internal consumers were already doing this; **host apps that subscribe to `PubSub.posts_topic/1` must update their pattern matches.**
- `DBStorage.upsert_group/1` rewritten as atomic `INSERT ... ON CONFLICT DO UPDATE` — closes a TOCTOU race where two concurrent callers with the same slug could both observe `nil` and then crash on the unique index.
- `Web.Settings.mount/3` moved DB reads into `handle_params/3` (Phoenix iron law: `mount/3` runs twice per page load).
- `StaleFixer.apply_stale_fix/3` retries once on `(group_uuid, slug)` unique-index conflict using a deterministic `post_uuid[0..8]` suffix.
- `StaleFixer.fix_all_stale_values/0` now streams posts under `Repo.checkout/1` so large catalogues don't hold every post in memory.
- Posts save path: `maybe_sync_datetime_and_audit/3` consolidates timestamp-mode date sync + audit field updates into a single `update_post/2` (halves round-trips per save).
- Three `rescue _` clauses narrowed to `UndefinedFunctionError | ArgumentError`: `LanguageHelpers.reserved_language_code?/1`, `LanguageHelpers.single_language_mode?/0`, `Web.Controller.Language.valid_language?/1`.
- `Web.Controller.Translations.language_enabled_for_public?/2` renamed to `exact_enabled_for_public?/2` to distinguish from `LanguageHelpers.language_enabled?/2` (the looser variant).
- `Workers.TranslatePostWorker.translate_content/4` → `/3` and `skip_already_translated/5` → `/4` — dropped unused `group_slug` parameter (internal callers only).

### Fixed
- `Errors.truncate_for_log/2` UTF-8 boundary handling — multibyte input could previously return an invalid binary if `max` landed mid-codepoint; clip now walks back to the previous codepoint boundary.

### Docs
- Earmark `escape: false` trust model documented inline in `renderer.ex` (admin-authored Markdown only; rewire `html_sanitize_ex` if untrusted input ever reaches `render_markdown/1`).

## 0.1.4 - 2026-04-24

PR #9 — closes issues #6, #7, #8 plus related content-normalization and admin URL consistency work.

### Added
- `publishing_default_language_no_prefix` setting (Issue #7) — opt-in URL convention where the default language is served prefixless (`/blog` instead of `/en/blog`); prefixed URLs 301-redirect to the canonical. `Language.request_matches_canonical_url?/2` prevents redirect loops.
- `LanguageHelpers.get_primary_language_base/0`, `url_language_code/1`, `use_language_prefix?/1` — normalize dialect codes (`"en-GB"`) to URL base codes (`"en"`) for public routing. (Issue #6)
- `StaleFixer.normalize_content_language/1` — self-healing for legacy base-only content rows (`"en"`) when a dialect (`"en-GB"`) becomes the default. Paired with `TranslationManager` legacy-base promotion and `Posts.read_post` lazy retry-on-miss.
- Activity-log events for self-healing mutations: `publishing.content.language_normalized`, `.merged`, `.promoted`.
- `PhoenixKit.Modules.Publishing.ActivityLog` wrapper — guarded with `Code.ensure_loaded?/1` + `try/rescue` so audit failures never crash the primary mutation.
- Controller test-endpoint infrastructure (`Test.Endpoint`, `Test.Router`, `Test.Layouts`, `PhoenixKitPublishing.ConnCase`).

### Changed
- Public URL builders (`group_listing_path/3`, `build_post_url/4`, `build_public_path_with_time/4`) normalize dialect codes via `url_language_code/1`.
- Admin preview URLs (`Web.Index`, `Web.Listing`, `Web.New`) now route through `PublishingHTML` builders instead of hand-rolling prefix logic. (Follow-up to #6)
- Public language switcher deduplicates base + dialect entries and highlights the active language exactly.

### Fixed
- Forward `phoenix_kit_current_scope` from `Web.HTML.all_groups/1` and `Web.HTML.index/1` into `LayoutWrapper.app_layout` so the parent app header sees authenticated users on public Publishing pages. (Issue #8)
- Translation bug in cache-toggle flashes.
- Dialyzer warning on a statically-true `is_binary/1` guard introduced in PR #3.

### Docs
- `AGENTS.md` and `README.md` updated with the new setting, scope-forwarding convention for public templates, controller-test infrastructure pointer, and activity-log event table.

## 0.1.3 - 2026-04-11

### Fixed
- Add routing anti-pattern warning to AGENTS.md
2026-04-02

### Changed
- Migrate select elements to daisyUI 5 label wrapper pattern
- Remove deprecated `select-bordered` class for daisyUI 5 compatibility
- Rename routes module to `PhoenixKitPublishing.Routes`

### Fixed
- Add `language_titles` to `to_post_map` so `list_posts` includes translated titles

### Maintenance
- Upgrade dependencies

## 0.1.1 - 2026-03-26

### Fixed
- Remove `Code.ensure_loaded?` guards on `LanguageHelpers` in `db_storage.ex` and `mapper.ex` — call directly via alias instead of silently falling back to `"en"`
- Add deprecation warning to `set_translation_status/5` no-op (was returning `:ok` silently)
- Remove duplicate `site_default_language/0` private functions from `db_storage.ex` and `mapper.ex` — use `LanguageHelpers.get_primary_language()` directly
- Fix unused `all_posts` variable warnings in `listing.ex` (leftover from primary language removal)
- Remove unused `Helpers` alias in `collaborative.ex`
- Remove unused `@content_statuses` and `LanguageHelpers` alias in `translation_manager.ex`
- Fix alias ordering (credo) in `editor.ex`, `translation.ex`, `translate_post_worker.ex`, `renderer.ex`
- Reduce nesting depth in `do_publish_version`, `translate_single_language`, `skip_already_translated`, `render_versioned_post`, `build_post_url`, `toggle_version_access`, `translate_content`, `translate_now`
- Alias nested module in `test_helper.exs`

## 0.1.0 - 2026-03-25

### Added
- Extract Publishing module from PhoenixKit into standalone `phoenix_kit_publishing` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add 4 Ecto schemas: PublishingGroup, PublishingPost, PublishingVersion, PublishingContent
- Add dual URL modes: timestamp-based (blog/news) and slug-based (docs/FAQ)
- Add multi-language support with per-language content per version
- Add version management (create, publish, archive, clone)
- Add collaborative editing with Phoenix.Presence (owner/spectator locking)
- Add two-layer caching: ListingCache (`:persistent_term`) and Renderer (ETS, 6hr TTL)
- Add Markdown + PHK component rendering (Image, Hero, CTA, Video, Headline, Subheadline, EntityForm)
- Add PageBuilder XML parser (Saxy) for inline PHK components
- Add admin LiveViews: Index, Listing, Editor, Preview, PostShow, Settings
- Add public Controller with language detection, slug resolution, pagination, and smart fallbacks
- Add Oban workers for AI translation and primary language migration
- Add PubSub broadcasting for real-time admin updates
- Add route module with `admin_routes/0`, `admin_locale_routes/0`, and `public_routes/0`
- Add `css_sources/0` for Tailwind CSS scanning support
- Add migration module (run by parent app) with `IF NOT EXISTS` guards for all 4 tables
- Add unit and integration test suites
