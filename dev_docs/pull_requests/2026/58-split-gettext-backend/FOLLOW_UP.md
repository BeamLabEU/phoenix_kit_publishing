# Follow-up Items for PR #58

Triaged against `main` on 2026-10-15.

## Fixed

- **Split layout unpinned** (NITPICK) — `gettext_catalogue_test.exs` gained a
  `split backend` block: one `T_<locale>_default` module per shipped locale,
  translated lookups in all six locales, msgid fallback for an unshipped one.

## Open

None. The no-op `:domain` split is intentional (see CLAUDE_REVIEW.md).
