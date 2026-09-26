# Follow-up

## Fixed (pre-existing)

- ~~`de` catalogue lacked the `Content-Type` header (IMPROVEMENT MEDIUM)~~ — `a0c22ea`; `de/LC_MESSAGES/default.po:13`
- ~~Month abbreviations inconsistently punctuated (IMPROVEMENT MEDIUM)~~ — `a0c22ea`
- ~~ASCII quotes where the msgid uses typographic ones (IMPROVEMENT MEDIUM)~~ — `a0c22ea`; all five `“` msgids have `„ “` msgstrs
- ~~"sub-microsecond" translated two ways (IMPROVEMENT MINOR)~~ — `a0c22ea`

## Awaiting a decision (surfaced 2026-09-27)

Not deferred unilaterally: each is a preference the reviewer left open, listed for Max to fix, skip or punt.

- `%B %d, %Y` untranslated in every locale, so de/fr/it/et/ru post dates render month-first (`default.po:37-38` per locale; consumers `html.ex:2521-2778`, `locale_strftime/2`) — five msgstr edits (`%d. %B %Y` de, `%d %B %Y` fr/it/et, `%d %B %Y г.` ru); no code change — i18n polish

## Skipped (with rationale)

- Branch commit title lacked a verb prefix — normalised on the squash-merge `a0c22ea`

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-09-27): every finding re-verified against HEAD `713b047`; `mix credo --strict` green, suite 1809/0 at that commit.

## Open

The date-format preference above.
