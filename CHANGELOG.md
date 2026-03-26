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
