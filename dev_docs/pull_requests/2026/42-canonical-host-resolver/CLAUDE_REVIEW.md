# PR #42 Review — Canonical host resolver for multi-domain og:url/canonical

**Author:** Tymofii Shapovalov (@timujeen)
**Reviewer:** Claude (Anthropic)
**Status:** Merged — post-merge review, fix applied on `main`
**Commit:** `943d0fd`
**Date:** 2026-08-17

---

## Verdict

The feature shape is right: an optional `config :phoenix_kit, :canonical_host_resolver,
{mod, fun}` MFA lets a multi-domain host point a page's `og:url` at the language's home
domain, with the resolver guarded against absence/`nil`/raising. The gap is in
`strip_language_prefix/2` — it strips the wrong string for exactly the case this
codebase already has a name for: a **non-owner sibling dialect**.

One bug, fixed with a regression test added.

---

## Findings

### BUG — HIGH: `strip_language_prefix/2` stripped the base code, not the actual URL segment

`canonical_absolute_url/3` (`web/controller.ex`) is supposed to strip the page's own
locale prefix once it lands on that language's home host — that's the whole point of
"it is that domain's default." The new `strip_language_prefix/2` computed the prefix to
strip via:

```elixir
base = LanguageHelpers.url_language_code(language)  # == DialectMapper.extract_base/1
```

That's always the *base* code (`"en"` for both `"en-US"` and `"en-GB"`). But
`AGENTS.md`'s own "Language segment ≠ language identity" section (and
`sibling_dialect_urls_test.exs`) documents that the actual public URL segment is
resolved through `LanguageHelpers.public_url_segment/1`: the base's *owner* dialect
(primary-preferred) keeps the historical base segment (`/en/…`), but a **non-owner
sibling gets its full lowercase code** (`/en-gb/…`) — the only shape that can address
it at all.

So for two enabled dialects sharing a base — `en-US` (owner/primary) and `en-GB`
(sibling) — a request to `/en-gb/<group>/<slug>` on the sibling's own resolved home host
kept the `en-gb` prefix in `og:url`, because `String.split(url, "/", parts: 3)` was
matched against `"en"`, which never appears in a sibling URL. The owner-dialect case
(`/en/…`, base == actual segment) happened to work, which is why it shipped green — the
merged test suite only exercises a single-language site (`languages_enabled: false`,
no prefix at all) and never a multi-dialect one.

**Confirmed** with a new regression test
(`sibling dialect: the actual URL segment must be stripped`, added to
`canonical_host_resolver_test.exs`) that enables `en-US`/`en-GB`, adds an `en-GB`
translation, and requests `/en-gb/<group>/colour-story` with a per-dialect resolver
stub. Before the fix:

```
og:url content="https://uk.example.com/en-gb/dialect-.../colour-story"
```

**Fixed** — `strip_language_prefix/2` now resolves the segment to strip via
`LanguageHelpers.public_url_segment/1` (the same function every other public URL
builder in this module already uses for exactly this reason) instead of
`url_language_code/1`:

```elixir
segment = LanguageHelpers.public_url_segment(language)

case String.split(url, "/", parts: 3) do
  ["", ^segment] -> "/"
  ["", ^segment, rest] -> "/" <> rest
  _ -> url
end
```

After the fix the same request yields
`og:url content="https://uk.example.com/dialect-.../colour-story"` — the sibling's own
prefix stripped on its own home host, matching the owner-dialect behavior and the
feature's stated intent.

---

## What else was checked (no issues found)

- **Resolver guard**: absent config, `{mod, fun}` returning `nil`, and a raising
  resolver all correctly fall back to the legacy request-host `base_url(conn)` path —
  verified by the three pre-existing tests, all still passing.
- **`og:url` vs `<link rel="canonical">` divergence**: publishing only renders `og:url`
  in-page; the host's root layout builds `<link rel="canonical">` from the same
  forwarded `:og.url` assign, so the fix covers both surfaces the commit message
  names — no separate canonical-only code path was missed.
- **`enabled` flag on the translations assign**: `language_switcher_exposure_test.exs`
  was updated in the same commit to assert the key's presence; re-ran clean.
- **Logger.warning on resolver crash**: present, uses `Exception.message/1`, does not
  leak anything beyond the crashing module/function.

---

## Validation

- `mix test test/phoenix_kit_publishing/web/controller/canonical_host_resolver_test.exs`
  — 5/5 (was 4/4 before the added regression test; new test failed pre-fix, passes
  post-fix)
- `mix test test/phoenix_kit_publishing/web/controller/ test/phoenix_kit_publishing/language_helpers_test.exs`
  — 310/310
- `mix test` (full suite) — 1580/1580
- `mix precommit` (format + credo --strict + dialyzer) — clean
