# Follow-up Items for PR #9

Triaged against `main` on 2026-04-26. Both reviewers approved the PR
itself; the items below are the "Suggested follow-up tickets" section
of `CLAUDE_REVIEW.md` plus the smaller code-quality observations
flagged but not blocking.

## Fixed (Batch 1 — 2026-04-26)

- ~~**`Web.Settings.mount/3` did ~7 DB reads in mount**~~ —
  `web/settings.ex:20-66`. Pre-existing iron-law violation that PR #9
  broadened by one (the new `:default_language_no_prefix` read).
  Mount now keeps only the connected-only PubSub subscribe + the two
  static path/title assigns; every Settings/cache read moved to
  `handle_params/3`. LV mount runs twice (HTTP + WebSocket) — the
  ~14 round trips per page load become ~7.
- ~~**`StaleFixer.ensure_unique_slug/3` had a TOCTOU on the slug probe**~~ —
  `stale_fixer.ex:198-227, 322-380`. The probe stays as a happy-path
  optimisation (most fixer runs land on a free slug) but the actual
  conflict resolution moved to `apply_stale_fix/3`. When the eventual
  `update_post/2` returns `{:error, %Ecto.Changeset{}}` with a `:slug`
  unique constraint error, `retry_on_slug_conflict/4` appends the
  deterministic `post_uuid[0..8]` suffix and retries once. Any other
  constraint failure propagates so the fixer logs and moves on.
  Added a docstring on `ensure_unique_slug/3` spelling out that the
  DB index is the safety net, not the probe.
- ~~**`fix_all_stale_values/0` eagerly loaded every group + post**~~ —
  `stale_fixer.ex:357-385` + `db_storage.ex:228-247`. New
  `DBStorage.stream_posts/1` returns an Ecto stream (`max_rows: 200`)
  for batch-walking a group's posts. `fix_all_stale_values/0` wraps
  the per-group `Stream.each(&fix_stale_post/1)` in a
  `Repo.checkout/1` (Postgres streams require a checked-out
  connection). Group-list pass stays eager because the count is
  bounded by the number of CMS sections (typically <100) and
  `fix_stale_group/1` mutates rows the post pass also reads.
- ~~**Broad `rescue _` in 3 LanguageHelpers / Language helpers**~~ —
  `language_helpers.ex:171-184` (`reserved_language_code?/1`),
  `:188-198` (`single_language_mode?/0`),
  `web/controller/language.ex:128-134` (`valid_language?/1`).
  Each one narrowed from `rescue _ ->` to
  `rescue UndefinedFunctionError -> …; ArgumentError -> …` — the two
  exception classes that fire when the optional `Languages` module
  isn't loaded / configured. Genuine runtime bugs (DB errors,
  programmer errors) now propagate instead of being silently coerced
  to a falsey default.
- ~~**`language_enabled_for_public?/2` collided in name with
  `LanguageHelpers.language_enabled?/2`**~~ —
  `web/controller/translations.ex:127, 164, 232-251`. Renamed to
  `exact_enabled_for_public?/2` and updated the docstring to spell
  out the contrast with the looser variant. Behaviour-neutral; only
  the symbol changed.

## Verified pre-existing (not introduced by PR #9)

- `Web.Settings` mount-time DB queries — pre-existing pattern across
  the module; PR #9 added one more (`:default_language_no_prefix`).
  Both reviewers explicitly noted it shouldn't block the PR. Migrated
  in this batch (above).
- `StaleFixer.ensure_unique_slug/3` TOCTOU — pre-existing, not
  introduced by PR #9 (the function predates the PR). Migrated in
  this batch (above).
- Three `rescue _` clauses — same.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_publishing/web/settings.ex` | Move 7 DB-backed assigns from `mount/3` → `handle_params/3` |
| `lib/phoenix_kit_publishing/stale_fixer.ex` | Retry-on-slug-conflict in `apply_stale_fix/3`; `slug_with_post_suffix/2` extracted; stream-based `fix_all_stale_values/0` inside `Repo.checkout/1` |
| `lib/phoenix_kit_publishing/db_storage.ex` | New `stream_posts/1` (Ecto stream with `:group` preload, `max_rows: 200`) |
| `lib/phoenix_kit_publishing/language_helpers.ex` | Narrow 2× `rescue _` → `UndefinedFunctionError`/`ArgumentError` with comments |
| `lib/phoenix_kit_publishing/web/controller/language.ex` | Narrow `rescue _` → `UndefinedFunctionError`/`ArgumentError` with comment |
| `lib/phoenix_kit_publishing/web/controller/translations.ex` | Rename `language_enabled_for_public?/2` → `exact_enabled_for_public?/2`; expand docstring |

## Verification

- `mix compile --warnings-as-errors` ✓
- `mix format` ✓
- `mix test` — 451 tests, 0 failures (matches baseline)
- `mix dialyzer` — 0 errors

## Open

None.
