# PR #32 follow-up — quorum review + checklist sweep (2026-07-17)

The PR's 14 commits were written on a server without access to the quality-sweep
playbook, the AI quorum, or a runnable test environment. This pass ran both
after the fact: a 5-AI quorum + 4 playbook triage agents over the diff (see
`QUORUM_REVIEW.md` in this folder), then the C-step checklist against the
delta, then fixes for every confirmed finding.

## Fixed (Batch 1 — 2026-07-17)

- ~~Translated group name only reached the listing h1/title~~ — post pages
  (`PostRendering.fetch_group/1` + `resolve_group_name/3` — breadcrumb, "Back
  to …" footer, versioned + date-only paths), the listing `og:title` (now
  `assigns.page_title`), and the all-groups overview cards all resolve via
  `translated_group_name/2`. `web/controller/post_rendering.ex`,
  `web/controller.ex:251`, `web/html.ex` (all_groups).
- ~~Post pages fetched the group twice per request~~ — the group map fetched by
  post-rendering now rides the assigns into
  `assign_group_display_config/2` (renamed from `assign_scroll_config/2`,
  which had outgrown its name), whose defaults now derive from `Constants`
  instead of per-layer literals. `web/controller.ex`.
- ~~`validate_group_settings/1` kept atom keys, which `update_group/3`
  silently ignored~~ — governed settings normalize to their canonical string
  key; enum casts no longer `to_string/1` arbitrary terms (a map/list returns
  `{:error, …}` instead of raising). Credo nesting finding resolved in the
  same refactor. `group_settings.ex`.
- ~~`merge_name_i18n/2` raised `Protocol.UndefinedError` on nested/non-binary
  override values~~ — non-binary values are dropped; overrides are capped at
  `Constants.max_group_name_length()`. `groups.ex`.
- ~~Featured cards carried no `data-post-date`; grid cards used
  `published_at` over the effective date~~ — one `effective_post_date/1`
  helper (mirrors `Listing.listing_sort_key/1`) on every card variant.
  `web/html.ex`.
- ~~Featured hero/card vs grid card near-duplication~~ — single
  `listing_post_card/1` component (`:featured_hero | :featured_card | :grid`),
  hoisting the verbatim-duplicated excerpt + date/read-more blocks.
  `web/html.ex`.
- ~~Editor hidden `featured=false` input stayed enabled while the checkbox
  disabled~~ — disabled in lockstep (latent clobber: the status select stays
  enabled while viewing an older version; `update_meta` has no
  `viewing_older_version` guard). Merge semantics pinned by test.
  `web/editor.ex`.
- ~~Group saves double-broadcast `{:group_updated, …}`~~ — the edit LV's
  duplicate broadcast removed; `Groups.update_group/3` already broadcasts
  after the DB write. `web/edit.ex`.
- ~~`reading_time_label/1` not pluralizable~~ — `ngettext`. `web/html.ex`.
- ~~Timeline-rail months + both rails' aria-labels hardcoded English~~ —
  localized via `data-months`/`data-label` on the config elements; JS falls
  back to English. `web/html.ex`.
- ~~`all_groups/1` unwrapped strings~~ — "Publishing" / "Explore our published
  content" gettext-wrapped. `web/html.ex`.
- ~~Spec-parity test compared against a hardcoded key list~~ — now asserts
  against `Groups.config_setting_keys/0` (the real write path, exposed
  `@doc false`; `merge_group_config/2` is attr-driven off the same list).
  `groups.ex`, `group_settings_test.exs`.
- ~~`default_config/0` parity test omitted `show_post_count`~~ — added, plus a
  keys-coverage assertion. `group_settings_test.exs`.
- ~~`translated_group_name/2` missing `@spec`~~ — added. `groups.ex`.
- ~~57 strings per locale never extracted (server env)~~ — catalogs extracted
  + merged (`--no-fuzzy`); en identity-filled, et/fr/it/ru fully translated;
  all five pass `msgfmt --check-format` (en/et/it needed the missing charset
  header line). `priv/gettext/*`.
- ~~Untested delta paths~~ — new `display_settings_render_test.exs` pins every
  setting's public-render toggle end-to-end (count, timeline rail + localized
  config, scrollbar, breadcrumbs ×2, featured band + `data-post-date`,
  featured-off grid fallback, sort order, reading time, width classes, date
  position, progress bar, headings rail, translated-name reach incl.
  `og:title` and the post back-link); `groups_test.exs` gains settings +
  `name_i18n` persistence (incl. crash-guard, truncation, invalid-enum,
  atom-key round-trip) + `translated_group_name/2` resolution;
  `edit_live_test.exs` gains `switch_language`, `name_i18n` save, settings
  save; `editor_live_test.exs` pins the featured-flag merge semantics.

## Skipped (with rationale)

See `QUORUM_REVIEW.md` "Rejected / skipped findings" — headline items:
breadcrumbs/post-count default-off is deliberate (PR body corrected instead);
`featured_enabled=true` default is visually neutral (AGENTS.md wording fixed);
inline `<script>`/`<style>` on public dead views kept by design with the
strict-CSP + window-scroll host contract documented in AGENTS.md; lenient
`update_group/3` vs strict `validate_group_settings/1` is the intended
two-layer design; the 5,000-post listing-cache bound predates the PR.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_publishing/groups.ex` | attr-driven `merge_group_config/2` + `config_setting_keys/0`, hardened `merge_name_i18n/2`, `@spec` |
| `lib/phoenix_kit_publishing/group_settings.ex` | string-key normalization, crash-safe enum cast, nesting refactor |
| `lib/phoenix_kit_publishing/web/controller/post_rendering.ex` | `fetch_group/1` + language-resolved `resolve_group_name/3`, group in assigns |
| `lib/phoenix_kit_publishing/web/controller.ex` | og:title via page_title, `assign_group_display_config/2` (Constants defaults, no refetch) |
| `lib/phoenix_kit_publishing/web/html.ex` | `listing_post_card/1` dedup, `effective_post_date/1`, rail l10n, ngettext, all_groups gettext + translated names |
| `lib/phoenix_kit_publishing/web/editor.ex` | hidden featured input disabled in lockstep |
| `lib/phoenix_kit_publishing/web/edit.ex` | duplicate broadcast removed |
| `AGENTS.md` | host contract (CSP, scroll owner), default nuances, name-reach map, write-path semantics |
| `priv/gettext/*` | full extraction + 5-locale catalog fill |
| `test/**` | 33 new tests (see Fixed) |

## Verification

- Standalone (`mix test`, published core via Hex pin): **1206 tests, 0
  failures** (baseline before this pass: 1173/0 — the PR itself had never
  been suite-run; its "workspace path-dep lock mismatch" blocker did not
  reproduce locally).
- Integrated (`PHOENIX_KIT_PATH=../phoenix_kit mix test`): **1206 / 0**.
- `mix precommit` via `PHOENIX_KIT_PATH`: clean (the two credo `--strict`
  findings the first run surfaced — `validate_params/1` nesting,
  `assign_scroll_config/2` complexity — are resolved by the refactors).
- 3× stability runs: 0 failures each.
- All five gettext catalogs: 0 untranslated, `msgfmt --check-format` clean.

## Open

None.

## CLAUDE_REVIEW (2026-10-15)

Fixed: sibling-dialect leak in `name_i18n` resolution; dependent-toggle reset in the
Edit Group form; split `merge_name_i18n` comment; listing sort uuid tie-break.
Open: none (nitpicks left as-is are explained in `CLAUDE_REVIEW.md`).
