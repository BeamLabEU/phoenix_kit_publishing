# Follow-up

## Fixed (pre-existing)

- ~~Scheduled posts released against UTC instead of the site clock (BUG HIGH)~~ — `d1bb6a0`, reworked `debc542`; `constants.ex` `scheduled_ahead?/3`, `listing.ex` hoists now+tz
- ~~`dispatch_e2e_test.exs` missing `@moduletag :integration` (BUG HIGH)~~ — `d1bb6a0`; `dispatch_e2e_test.exs:30`
- ~~RSS `pubDate` stamped `+0000` from the site wall clock (BUG MEDIUM)~~ — `d1bb6a0`/`debc542`; `feed.ex` `Constants.from_site_wall/3`
- ~~CategoriesPicker re-queried the tree per render (IMPROVEMENT MEDIUM)~~ — `d1bb6a0`; `categories_picker.ex:54-55` reuses the cached tree
- ~~`Hashtags.tag_counts/1` returned the downcased key (BUG LOW)~~ — `d1bb6a0`; `hashtags.ex` `most_used_spelling/1`
- ~~Dead `%{posts: posts}` clause / unreachable `:invalid_parent` (BUG LOW)~~ — `d1bb6a0`
- ~~Five error atoms bypassed the `Errors` dispatcher (IMPROVEMENT MEDIUM)~~ — `d1bb6a0`; `errors.ex` type + `message/1` clauses
- ~~Precommit red: 7 dialyzer + 22 credo (BUG MEDIUM)~~ — `d1bb6a0`

## Awaiting a decision (surfaced 2026-09-27)

Not deferred unilaterally: each is a preference the reviewer left open, listed for Max to fix, skip or punt.

- Feed enclosure carries a signed, expiring Storage URL (`feed.ex:144`) — podcast clients cache the URL; needs a long-lived/unsigned storage variant in core — cross-repo
- Search `ILIKE '%…%'` over `contents.content` without an index (`db_storage.ex:354`) — trigram/tsvector index via a core migration; perf only, until a large docs group
- Picker `matching/3` filters on `name` while chips show `translated_name` (`categories_picker.ex:120` vs `:181`) — match both spellings; small UX bug

## Skipped (with rationale)

- `show_tags` orphan key in group `data` JSONB — deliberate, documented in the roadmap; nothing reads it
- `ListingCache.regenerate/2` runs `backfill_version_categories/1` per rebuild — stated design: one SELECT over an empty table

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

The three items awaiting a decision above.
