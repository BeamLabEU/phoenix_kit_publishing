# FOLLOW_UP — PRs #27 / #28 / #29 (post-release review)

Triaged 2026-08-01. Every finding was fixed inside the review itself; this
file records that and the re-verification.

## Fixed (in the review itself)

- ~~**`og_resolve/2` returned nil for three declared variables.**~~
  `post_url`, `post_group_name` and `post_group_slug` read metadata keys the
  mapper never builds. Fixed to read `:group`, resolve the name through
  `Groups.group_name/1`, and build the URL from the `conn` in context. Four
  tests in `integration/og_override_test.exs`.
- ~~**`fetch_variant/2` failed `credo --strict`.**~~ Aliased
  `PhoenixKit.Modules.Storage`.
- ~~**`mix dialyzer` failed outright.**~~ Added `.dialyzer_ignore.exs` for the
  two optional-`PhoenixKitOg` `unknown_function` warnings (the pattern core
  already uses for optional publishing), removed a dead `|| %{url: nil}`
  fallback and an unreachable catch-all clause.
- ~~**Stale slug-cap assertion.**~~ Tightened from `<= 200` to `<= 60` after
  `@seo_slug_length` dropped.

## Re-verified (2026-08-01)

`og_resolve/2`'s three clauses still read the keys the mapper builds; the
`.dialyzer_ignore.exs` wiring is still in `mix.exs`. PRs #28 and #29 were
clean on review and remain so.

## Verification

`mix test` 1525 tests / 0 failures; `mix compile --warnings-as-errors` clean;
`mix credo --strict` at baseline.

## Open

None.
