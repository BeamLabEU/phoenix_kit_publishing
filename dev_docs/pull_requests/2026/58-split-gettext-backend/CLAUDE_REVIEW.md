# PR #58: Split the Gettext backend by locale and domain

**Author**: Max Don
**Reviewer**: Claude
**Status**: Merged
**Commit**: `5b0c2c8`
**Date**: 2026-10-15

## Goal

`PhoenixKitPublishing.Gettext` compiled every catalogue (~23k lines of `.po`)
into one module, serially, in 11-14 s, blocking the compile of any dependent
app. `split_module_by: [:locale, :domain]` makes Gettext build one module per
locale and domain in parallel. Closes #57.

## Verdict

Sound. A six-line change to `lib/phoenix_kit_publishing/gettext.ex`; lookups and
the public API are unchanged.

## What was checked

- **Option support.** `split_module_by` is a documented option of the pinned
  `gettext ~> 1.0` (lock: 1.0.2); `mix.exs` already requires `~> 1.0`.
- **Behaviour parity.** Read `Gettext.Compiler`: each split module holds the
  per-locale/domain clauses; the parent module keeps the `lgettext/lngettext`
  dispatch, the catch-all that routes to `handle_missing_translation/…`, and the
  `@external_resource` entries, so `.po` edits still trigger a recompile.
- **Layout.** Forced recompile in `:test` produced exactly six
  `PhoenixKitPublishing.Gettext.T_<locale>_default` modules (one domain ships).
- **Lookups.** `Publishing` resolves in de/en/et/fr/it/ru and falls back to the
  msgid for an unshipped locale (`pt`).
- **No consumers of internals.** Nothing in `lib/` or `test/` references the
  backend's generated functions directly.

## Findings

### NITPICK — nothing pinned the split layout

If the option were dropped, every lookup would still pass and the compile-time
regression (#57) would return silently.
**Fixed:** `gettext_catalogue_test.exs` now asserts one split module per shipped
locale, translated lookups through the split backend in all six locales, and the
msgid fallback for an unshipped one.

### NITPICK — `:domain` splitting is currently a no-op

Only `default.po` exists per locale, so `[:locale, :domain]` and `[:locale]` give
the same six modules. Harmless and forward-looking (a second domain would
parallelise further); recorded so nobody reads it as a bug.
