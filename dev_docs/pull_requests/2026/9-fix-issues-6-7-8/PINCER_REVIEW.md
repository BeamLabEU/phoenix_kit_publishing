# PR #9 — Fix Issues #6, #7, #8 plus content normalization and admin URL refactor
**Author:** Max Don (mdon)
**Reviewer:** Pincer
**Phase:** 1 — surface review
**Date:** 2026-04-24
**Verdict:** ✅ APPROVE

---

## Summary

Eight-commit PR closing issues #6, #7, #8 with associated content normalization and admin URL consistency work. Well-decomposed — each commit is atomic and clearly described. All checks pass (451 tests, 0 failures, 13+ new tests, format/credo/dialyzer clean).

## Issue Breakdown

### Issue #6 — Public URL language normalization
Content stores dialects (`"en-GB"`) but public routes match base codes (`"en"`). Adds `get_primary_language_base/0` and `url_language_code/1` (`DialectMapper.extract_base/1`) and wires them into all URL builders. Admin preview templates were hand-rolling prefix logic instead of going through the builders — fixed in commit #4.

### Issue #7 — Default-language no-prefix URL convention
New opt-in setting `publishing_default_language_no_prefix`. When enabled, the default language URL drops its prefix (`/blog` instead of `/en/blog`) and prefixed URLs 301-redirect to the canonical. `request_matches_canonical_url?/2` prevents redirect loops — correct defensive design. The collateral content-normalization work (`StaleFixer`) is load-bearing: legacy `"en"`-coded rows must be found under the new `"en-GB"` default when serving the prefixless URL.

### Issue #8 — Scope forwarding to public layouts
`Web.HTML.all_groups/1` and `Web.HTML.index/1` were missing `phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}` in their `LayoutWrapper.app_layout` calls. Parent app header rendered as logged-out even for authenticated sessions. `show/1` already had it; a two-line fix for the other two. Regression test (`show_layout_test.exs`) verifies the scope reaches the layout and fails without the fix.

## Files Changed (35)

Core changes: `language_helpers.ex` (+91), `posts.ex` (+114/-10), `stale_fixer.ex` (+236/-4), `translation_manager.ex` (+66/-12), `web/html.ex` (+51/-35), `web/settings.ex` (+80/-10), `web/controller/language.ex` (+36/-5)

New files: `activity_log.ex`, `stale_fixer_test.exs`, `language_helpers_test.exs`, `language_test.exs`, `show_layout_test.exs`, `translations_test.exs`, `html_test.exs`, `conn_case.ex`, `test_endpoint.ex`, `test_layouts.ex`, `test_router.ex`

## Green flags

- **Outstanding PR description** — commit-by-commit breakdown with rationale. The load-bearing explanation for content normalization (commits #3 and #4) saves future reviewers hours.
- **Test coverage** — 451 tests, 0 failures. New tests cover URL normalization, language helpers, controller integration, and the scope forwarding regression. The regression test *correctly fails* without the fix.
- **Test infrastructure** — `Test.Endpoint` + `Router` + `Layouts` + `ConnCase` is a clean pattern for a module with no runtime endpoint. Useful for future controller tests too.
- **`url_language_code` abstraction** — routing `"en-GB"` → `"en"` through `DialectMapper.extract_base/1` is the right hook point.
- **Redirect loop prevention** — `request_matches_canonical_url?/2` checks before 301-redirecting, correct.
- **Activity logging for self-healing** — `Publishing.ActivityLog.log/1` follows the catalogue pattern (guarded, try/rescue, `mode: "auto"`, no `actor_uuid`). Consistent.
- **Dialyzer clean** — 1 pre-existing warning eliminated in commit #7.
- **AGENTS.md additions** — well-written, documents the scope-forwarding convention, URL building rules, and retry-on-miss pattern for future developers.

## Yellow flags

- Manual verification (Issue #8: parent app with auth scope sees authenticated header) is unchecked. The automated regression test covers the forwarding path, but an end-to-end smoke test in a real parent app would be ideal. Low risk — the regression test is strong.
- `StaleFixer` grew substantially (+236 lines). Deep review of the promotion/merge logic would be warranted in Phase 2 to confirm edge cases in translation-manager "add dialect" flow.

## Red flags

None.

## Recommendation

**APPROVE.** This is a high-quality PR — clearly scoped, well-tested, self-documenting. The `StaleFixer` complexity is the only thing worth a deeper look in Phase 2, but it's surrounded by integration tests and clearly reasoned in the PR description. Safe to merge.
