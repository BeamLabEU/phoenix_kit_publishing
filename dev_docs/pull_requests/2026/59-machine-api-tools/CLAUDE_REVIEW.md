# PR #59: Add the machine API tools of the publishing module

**Author**: Tymofii Shapovalov
**Reviewer**: Claude
**Status**: Merged
**Commit**: `9e7e617`
**Date**: 2026-10-21

## Goal

Declare 20 admin tools (`PhoenixKit.Module.api_tools/0`) for core's machine API
(`/api/admin/v1`, `/mcp/admin`): reads of groups, posts and categories; edits that
never publish; publish / unpublish / schedule / trash / restore; category and
group upserts; AI translation. Core owns keys, scopes and the confirmation flow;
this module owns the tools and the data rules (`API.Danger`, `API.TextScan`).
About 9,000 lines, 21 `api/` handlers, plus changes in `Posts`, `Versions`,
`Groups`, `Categories`, `TranslationManager`, `DBStorage`, `Hashtags` and
`ActivityLog`.

## Verdict

Sound, with no blocking defect found. The parts that carry the safety argument are
built the right way: every danger check is fail-closed (`Danger.guard/1`, raising
reads only), a confirmed write is rechecked on the FRESH rows under the post lock
(`Common.locked_check/2` through `Posts.update_post/4`'s `:locked_check`), and the
option name `:activity_mode` keeps clear of `Groups.add_group/2`'s `:mode`.

**Scope of this review, stated plainly.** Read line by line: the context-layer
diff (`Posts`, `Versions`, `Groups`, `Categories`, `TranslationManager`,
`DBStorage`, `Hashtags`), `API.TextScan`, `API.Danger`, `API.Gate`,
`API.UpdatePost`, `API.SetTranslation` (write path), `API.SchedulePost`, and
`API.Common` (`write_opts`, `classify`, `slug_taken?`, `locked_check`). Not read
line by line: `Presenter`, `Schemas`, `Refs`, the group / category upserts,
`translate_post`, `publish_post`, `trash_*` / `restore_*`; for those the evidence
is the suite (conformance, static, fingerprint and executor tests) and the
review rounds visible in the commit list.

## What was checked

- **Counts.** `tools.ex` declares 20 tools, matching AGENTS.md.
- **`locked_check` plumbing.** The hook runs after `lock_post_row!` and the fresh
  version read; `{:error, r}` rolls back; a missing row is `:not_found` without
  running the hook. `TranslationManager.add_language_checked/5` mirrors it for
  the row-creating path, and every `with` branch has a matching `else`.
- **`Common.locked_check/2` fail-closed.** Refuses a trashed locked row always;
  an unconfirmed call proceeds only when the live function answers exactly
  `false` (`Danger.live_condition/3` returns a strict boolean); raise and throw
  map to `:locked_check_failed`.
- **Text rule vs. renderer.** The five rules scan the submitted string only, are
  linear (`:binary.matches`, bounded regexes), and fail closed above 2 MiB. After
  #61 the rule is a confirmation gate on top of the renderer's allow-list rather
  than the only defence.
- **Keyset pagination** (`DBStorage.list_posts_page/3`): the row-value comparison
  uses the same three coalesced sort keys plus the uuid as the list order, with
  `desc: p.uuid` as the final key.
- **Hashtags.** `link_urls/3` collects spellings with `@any_hashtag`; every
  spelling `@hashtag` / `@hashtag_mid` can capture is also found by it (same body,
  lead group only constrains where it starts), so `Map.fetch!/2` in `link_tag/5`
  cannot raise.

## Findings

### IMPROVEMENT - MEDIUM — wall-clock budget made `TextScan` test flaky (fixed)

`text_scan_test.exs` asserted that each 262,144-byte worst case scans in under
100 ms on a single measurement. The slowest input (`&#58;` repeated) costs about
70 ms on an idle machine, the module is `async: true`, and the failure showed
the retry inside the assertion message at 73 ms while the first run exceeded
100 ms. **Fixed:** best of three runs and a 500 ms budget (a quadratic scan of
this size takes seconds, which is what the test exists to catch); the message no
longer re-measures.

### NITPICK — hashtag masks stop at 1,000 / 2,000 characters

`!?\[[^\]\n]{0,1000}\]\([^)\n]{0,2000}\)` leaves a longer link unmasked, so a
`#tag` in a link text over 1,000 characters is linkified inside the link (a nested
anchor). Documented in the code comment and a trade for the linear-time fix; the
sanitiser cleans the result. **No change.**

### NITPICK — the page cursor assumes second-precision `inserted_at`

`type(^inserted_at, :utc_datetime)` and the loaded value are truncated to
seconds, which matches every row written through the schema
(`timestamps(type: :utc_datetime)`). A row inserted with raw SQL `now()`
(microseconds in the `timestamptz` column) that ties with the cursor on date and
time could be skipped at a page boundary. Found by reading, not reproduced;
nothing in this module writes such rows. **No change.**

### Baseline failures on `main` found while validating (fixed)

The suite had 5 failures before any change, none caused by #59 or #61:

- **`translations_test.exs` "promotes a legacy base-language row…" (every run).**
  Core 2.63 derives the primary language from `Languages.configured_primary_language_code/0`
  (the default entry of `languages_config`), not from the `content_language`
  setting the test wrote, so the post was created as `en-US` and never had a
  legacy `en` row. **Fixed:** the test makes `en` the default entry while the post
  is created, then `en-US`, which is the real sequence.
- **`editor_switch_content_test.exs` (3 different tests per run, 0 on some runs).**
  `assert_patch/1`, `assert_redirect/1` and `assert_push_event/3` use LiveViewTest's
  100 ms default while the action behind a flush does database work.
  **Fixed:** 1,000 ms on the positive assertions (`refute_*` unchanged).
