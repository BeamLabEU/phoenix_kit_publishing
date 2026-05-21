# Changelog

## 0.1.12 - 2026-05-21

PR #19 — unify the translation-response parser with core (paired with `phoenix_kit 1.7.117`).

### Changed
- `TranslatePostWorker.parse_translated_response/1` now delegates to `PhoenixKit.Modules.AI.Translation.parse_response/2` (the canonical `---FIELD---` parser shared with `phoenix_kit_projects`, shipped in core PR #557) instead of a hand-rolled chained-regex matcher. It tries `["title", "slug", "content"]` first, retries with `["title", "content"]` on missing fields, and falls back to the publishing-specific `parse_markdown_response/1` salvage when no markers are present. The AI call sites, `extract_content/1`, and `sanitize_slug/1` are untouched.
- Bumped the `phoenix_kit` dependency floor to `~> 1.7.117`, which is where `Modules.AI.Translation.parse_response/2` became available; the lock also picks up `etcher 0.4.6`, `fresco 0.5.4`, and `req 0.5.18`.

### Fixed
- Translation responses with `---FIELD---` markers in any order, or with lower/mixed-case marker names, now parse correctly instead of falling through to the bare-markdown salvage path. Covered by new regression tests for marker order-independence, case-insensitive markers, and the TITLE-only fallback.

## 0.1.11 - 2026-05-19

PR #18 — delegate the `default_language_no_prefix` toggle to the site-wide core setting (paired with `phoenix_kit 1.7.115`).

### Changed
- `LanguageHelpers.default_language_no_prefix?/0` now delegates to `PhoenixKit.Modules.Languages.default_language_no_prefix?/0` instead of reading the legacy `publishing_default_language_no_prefix` setting key directly. All consumers (the six `Web.HTML` URL builders, the canonical-redirect controller, and the `Publishing.default_language_no_prefix?/0` / `use_language_prefix?/1` facade) keep the same signature and behavior.
- `/admin/settings/publishing` — the "Default Language Without Prefix" toggle is replaced with a read-only status row and a "Manage" link to `/admin/settings/languages`, which now owns the setting. Removes the dual-write risk where the publishing-side write could desync from the core-side read mid-deploy.
- Bumped `phoenix_kit` to `1.7.115`, which ships `Modules.Languages.default_language_no_prefix?/0` and the `Languages.migrate_legacy/0` backfill (run by `ModuleRegistry` at boot) that copies the legacy `publishing_default_language_no_prefix` value into the new core key, so existing sites keep their explicit choice without admin action.

### Removed
- `@default_language_no_prefix_key` constant and the `toggle_default_language_no_prefix` LiveView event on `Web.Settings` — the setting is no longer publishing-owned.

## 0.1.10 - 2026-05-19

Maintenance release — LiveView callback annotations and dependency bumps.

### Changed
- Added `@impl true` annotations to the `Web.Settings` LiveView callbacks (`mount/3`, `handle_params/3`, `terminate/2`, `handle_event/3`, `handle_info/2`, `render/1`) so the compiler verifies them against the `Phoenix.LiveView` behaviour.
- Bumped dependencies: `ecto` `3.13.6` → `3.14.0`, `ecto_sql` `3.13.5` → `3.14.0`, `fresco` `0.5.0` → `0.5.2`.

## 0.1.9 - 2026-05-19

PR #16 — Phase 2 quality sweep (URL-slug correctness, DoS guards, race fixes, archive semantics, host boundaries) + post-merge review fixes + the `phoenix_kit 1.7.114` upgrade.

### Fixed
- **`Ecto.MultipleResultsError` on URL-slug post lookups.** Posts that accumulated several versions sharing identical content fields crashed `repo().one()`. URL-slug resolution is now scoped to the post's active version (public path) with a deterministic tie-break.
- **Two DoS vectors closed.** (1) The PHK page-builder XML parser used `String.to_atom/1` on admin-supplied tag names — arbitrary tags could exhaust the finite BEAM atom table and crash the VM. It now uses `String.to_existing_atom/1`, routing unknown tags to `:unknown`. (2) `ListingCache` minted a never-GC'd `:persistent_term` entry for every unknown URL segment treated as a group slug; it now verifies the group exists before writing (each write also triggers a global GC pass — a flood of bad requests was a DoS on top of the leak).
- **Language-switch redirect loop on a trailing `?`.** `build_public_path/2` encoded an empty query map to `"foo?"`, which never equals the canonical `"foo"`, so the 301 looped to itself. Empty params now produce no `?`.
- **Public URLs broke under a non-root workspace prefix.** `RouterDispatch` gained `maybe_rewrite/2`, which strips/re-prepends the host's `url_prefix` so dispatch works when PhoenixKit is mounted under e.g. `/phoenix_kit`.
- **Publish/unpublish races.** Both `do_publish_version/4` and `do_unpublish_post/3` now take a `SELECT … FOR UPDATE` lock on the post row (shared `lock_post!/2` helper) so concurrent publishes/unpublishes can't interleave into a stale `active_version_uuid`. Timestamp-mode `create_post` retries the whole transaction on a `(group_uuid, post_date, post_time)` unique-constraint violation instead of failing.
- **`find_by_previous_url_slug/3` surfaced unpublished posts** — a public 301 redirect could resolve onto a never-published post that then 404s. Now scoped to the active version only.
- **`clear_translation` editor event was unguarded** — a spectator/locked-out viewer could hard-delete a translation row by sending the event directly over the socket. Now gated like every other destructive editor event.

### Added
- **`find_by_url_slug_any_version/3`** (`Posts` / `DBStorage`) — internal lookup that surfaces unpublished drafts, for the stale-language self-healing flow and slug-uniqueness checks. The public `find_by_url_slug/3` stays published-only.
- **`unpublish_post` `:target_status` option** — the "Archived" UI action now persists `status: "archived"` on the version row instead of silently reverting to `"draft"`.
- `terminate/2` on the `Index`, `PostShow`, and `Settings` LiveViews for subscribe/unsubscribe symmetry.
- i18n sweep — previously-hardcoded UI strings on the public listing/post pages and editor now flow through `gettext`/`ngettext`.

### Changed
- **URL-slug lookup split** into a public, published-only path and an internal any-version path; collisions on the public path self-heal by auto-suffixing the loser's `url_slug`.
- **base→dialect resolution consolidated** — three near-identical helpers in `Posts`, `Web.Controller.Language`, and `StaleFixer` collapse into `LanguageHelpers.resolve_dialect_for_base/3` with explicit `:prefer` / `:exclude` options.
- The admin "Edit Post" link now carries the current public-side language via `?lang=` so the editor opens in the language the reader was viewing.
- Narrowed `rescue` clauses in `Publishing.dashboard_tabs`, `load_publishing_groups_for_tabs`, and `Web.Preview` to catch only expected DB/render exceptions — genuine programmer errors bubble up again instead of being masked.
- `clear_translation/4` writes an `ActivityLog` audit entry, matching `delete_language`.
- Bumped `phoenix_kit` to `~> 1.7.114`, which adds the generic `:module_assigns` attr on `LayoutWrapper.app_layout/1`; `Web.HTML` forwards `phoenix_kit_publishing_translations` and `og` to the host layout through it.
- `create_post_with_timestamp_retry` takes a single context map instead of nine positional arguments.

### Docs
- `dev_docs/pull_requests/2026/16-phase-2-quality-sweep/` — `CLAUDE_REVIEW.md` (post-merge review) and `FOLLOW_UP.md` (findings triage + `mix precommit` restoration after the upgrade).

## 0.1.8 - 2026-05-09

PR #15 — host-integration hooks for the language switcher + post-merge boundary normalisation.

### Added
- **`:phoenix_kit_publishing_translations` conn assign** — the public API contract for host-app switchers. Set on listing and post responses (regardless of the in-page-switcher toggle) as a list of maps with exactly five fields: `%{code, name, flag, url, current}`. Lets host root layouts and custom switchers render publishing's per-translation URLs directly — important for groups with per-language URL slugs where a generic locale-rewrite produces wrong hrefs.
- **`publishing_show_language_switcher` setting** (default `true`) — gates the in-page switcher on listing + post pages. Hosts that already render a switcher in their header flip it to `false` in `/admin/settings/publishing` to suppress duplicate UI. Per-translation URLs stay exposed regardless.
- Settings UI gains an "In-Page Language Switcher" toggle mirroring the existing `publishing_default_language_no_prefix` shape.

### Changed
- `Web.Controller.assign_publishing_translations/2` normalises the public assign at the boundary, stripping internal-only fields (`display_code`, and on post routes `enabled`/`known`) so external consumers get a uniform 5-field shape on both listing and post routes. Internal `:translations` assign is unchanged.
- `Web.HTML` listing and post templates gate the in-page switcher on `assigns[:show_language_switcher] != false` — defaults to rendering when the assign is absent, preserving historical behaviour for hosts that haven't threaded the assign through.
- Bumped transitive deps in `mix.lock`: db_connection 2.10.0 → 2.10.1, decimal 2.3.0 → 3.1.0, ex_doc 0.40.1 → 0.40.2, leaf 0.2.12 → 0.2.13, makeup_erlang 1.0.3 → 1.1.0, mint 1.7.1 → 1.8.0.

### Docs
- AGENTS.md gains a "Language switcher integration" section documenting the three integration points (the toggle, the conn assign, and core's matching `<.language_switcher_dropdown>` `:per_translation_urls` attr) + a row in the Settings Keys table.
- `dev_docs/pull_requests/2026/15-language-switcher-host-integration/CLAUDE_REVIEW.md` — post-merge review.

## 0.1.7 - 2026-05-05

PR #13 — fix issue #11 (editor opens blank for `?lang=<base>` when only a non-default dialect is enabled) + PR-12 close-out + precommit nits.

### Fixed
- **Editor opened blank when `?lang=<base>` mapped to a non-default dialect (Issue #11).** Two-layer bug: `Posts.resolve_language_to_dialect/1` mapped `"en"` to the hard-coded `DialectMapper` default (`"en-US"`) instead of an enabled dialect like `"en-GB"`, and `Editor.handle_uuid_post_params/3` then ran a raw `language not in post.available_languages` check which routed `"en"` against `["en-GB", "ru"]` into `handle_new_translation_params/6` (empties the form). Fix at both layers — neither alone is sufficient.
- `post_rendering_helpers_test.exs:74` — stale `build_breadcrumbs/3` call site missed by the `7f547b5` (PR #12 cleanup) arity bump to `/4`. Now passes the `group_name` arg explicitly and asserts on the resulting label.

### Changed
- `Posts.resolve_language_to_dialect/1` — prefers an enabled dialect for the given base before falling back to `DialectMapper.base_to_dialect/1`. When several dialects share the base, prefers `LanguageHelpers.get_primary_language/0`, otherwise the first enabled dialect in declaration order. New private helper `enabled_dialect_for_base/2`.
- `Editor.handle_uuid_post_params/3` and `Editor.handle_path_post_params/3` — route through new `new_translation_request?/2` helper that resolves the requested language against `post.available_languages` via `Web.Controller.Language.resolve_language_for_post/2` before deciding new-vs-existing translation.
- `test_helper.exs` — swapped `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, ...)` for `PhoenixKit.Migration.ensure_current(TestRepo, log: false)` (core 1.7.105+ / phoenix_kit#515). The version-`0` pattern silently stopped re-applying once `0` was recorded in `schema_migrations`; `ensure_current/2` re-applies via fresh wall-clock versions on every boot.
- `StaleFixerTest` switched from `async: true` → `async: false`. Every test in the file mutates the shared `content_language` setting (ETS-cached singleton); two parallel runs in the same VM clobbered each other and produced a 1-in-15 flake on `:96 url slug lookup repairs legacy base-language slugs`.
- Bumped to `phoenix_kit ~> 1.7.105` (required by `Migration.ensure_current/2`) and `phoenix_kit_ai ~> 0.2.0`. The latter tightened return types of `AI.list_endpoints/1` and `AI.list_prompts/1`; `Editor.Translation.list_ai_endpoints/0` and `list_ai_prompts/0` dropped now-dead `_ -> []` fallbacks.

### Docs
- AGENTS.md gains a "Base→enabled-dialect resolution" Critical Conventions bullet documenting the resolver behavior, the editor-side contract, and the issue #11 reference.
- `dev_docs/pull_requests/2026/12-smart-fallback-fix/FOLLOW_UP.md` records resolution of the four `CLAUDE_REVIEW.md` findings from PR #12 (3 fixed in `7f547b5`, 1 here) and closes the folder.
- `dev_docs/pull_requests/2026/13-issue-11-resolver/CLAUDE_REVIEW.md` — post-merge review.

## 0.1.6 - 2026-05-02

PR #12 — fix smart-fallback URL hijack + drop hand-rolled migrations + Phase 2 cleanup.

### Fixed
- **Smart-fallback URL hijacking** — when `url_prefix` is `""`/`"/"`, publishing's catch-all sits at the host's absolute root. Unknown first segments now 404 instead of silently redirecting to the first group in the DB (which hijacked host-app paths like `/about`, `/contact`).
- `conn.params` rewrite after `Language.detect_*` reinterpretation — downstream code (including the fallback) now sees corrected `group`/`path` instead of the raw (wrong) bindings from the localized route.

### Removed
- `PhoenixKit.Modules.Publishing.Migrations.PublishingTables` — 311-line consolidated migration was dead code; every consumer pulls in `phoenix_kit` core whose V59 creates the same tables. Use `mix phoenix_kit.install` (has been the correct path since extraction).
- `constraints: %{...}` maps on public routes — Phoenix.Router has no per-segment regex constraint mechanism; these were always no-ops. Route declaration order + controller-layer disambiguation are the actual mechanisms.
- `created_by_email`/`updated_by_email` from `Shared.audit_metadata/2` — the publishing schema has no email columns; these keys were silently stripped by mass-assignment guard (dead plumbing from core's pre-extraction blogging module).

### Changed
- Test suite uses `Ecto.Migrator.run(TestRepo, [{0, PhoenixKit.Migration}], :up, ...)` instead of 178 lines of inline DDL — test/prod schema drift is now impossible by construction.
- `Listing.default_group_listing/1` removed — no longer a meaningful concept after the fallback-policy fix.
- `build_breadcrumbs/3` → `/4` — accepts `group_name` directly, eliminating a redundant group lookup per public page render. `render_published_post` and `build_versioned_post_response` now include `group_name` in their assigns maps; the controller consumes it instead of calling `Publishing.group_name/1` separately.
- `String.capitalize(@group_slug)` in `html.ex` and `preview.ex` replaced with `@group_name` assign — slugs like `"date12"` no longer render as `"Date12"` in the "Back to" link.

### Docs
- AGENTS.md and README.md updated: removed `migrations/` from lib-tree, documented smart-fallback semantics, noted that `constraints:` on public routes is a no-op.

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
