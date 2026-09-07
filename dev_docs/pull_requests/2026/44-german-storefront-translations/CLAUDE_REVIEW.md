# PR #44 — Add German storefront translations

**Author:** timujinne · **Branch:** `feature/i18n-de` · **Reviewed:** 2026-09-04

Completes `priv/gettext/de/LC_MESSAGES/default.po` for the storefront and the
publishing admin. Translation catalogue only — no code, no schema.

> **Note on this document.** An earlier revision of it was written by the same
> party that prepared the PR, and concluded "None at BUG or IMPROVEMENT
> severity". An independent review then found four IMPROVEMENT-level issues and
> disagreed with two of its factual claims. This revision records the
> independent findings and what was done about them; the earlier conclusion was
> wrong and is retracted.

## Verified — runtime-critical, all clean

Checked programmatically across all 689 messages, not by reading samples.

| Check | Result |
|---|---|
| msgid parity with `default.pot` | 690 = 690; sets identical, 0 extra, 0 missing |
| Duplicate msgids | 0 |
| msgid order and `#:` / `#,` comments | identical to the POT — `mix gettext.merge` is a no-op |
| **Interpolations `%{...}`** (singular↔msgid, plural↔msgid_plural) | **0 mismatches** |
| printf-style patterns (`%s`, `%d`, `%B`, `%Y`) | 0 mismatches |
| Plural forms | 10 in the POT, 10 in de; every one has `msgstr[0]` and `msgstr[1]`, none empty |
| HTML tags inside strings | 0 mismatches (compared as multisets) |
| Empty `msgstr` / `#, fuzzy` | 0 / 0 |
| Escaping and multi-line entries | real Expo 1.1.1 parse succeeds: 689 messages, umlauts intact |
| Technical tokens (`:persistent_term`, `Mod.Fun`, snake_case, URLs) | 0 losses |
| Encoding | valid UTF-8, no BOM, no CRLF, no tabs, trailing newline present |

The interpolation check is the one that matters most here: a placeholder
dropped or renamed in a translation crashes gettext on the live page. There
are none.

## Findings and resolution

### `IMPROVEMENT - MEDIUM` — de was the only locale without a `Content-Type` header — fixed

`en`, `fr`, `it`, `et` and `ru` all declare `text/plain; charset=UTF-8`; `de`
declared only `Language:` and `Plural-Forms:`. Gettext is unaffected (Expo
decodes UTF-8 regardless — confirmed, the umlauts arrive), but external
catalogue tooling — `msgfmt`, Poedit, Weblate, a CI linter — is entitled to
assume ASCII without it and mangle them. Header added.

### `IMPROVEMENT - MEDIUM` — inconsistent month abbreviation punctuation — fixed

`Jan.`, `Feb.`, `Okt.` and `Nov.` carried the period German orthography
requires of a truncated word (Duden, DIN 5008); `Apr`, `Aug`, `Sep` and `Dez`
did not. Normalising downward would have made eight entries wrong instead of
four, so the period was added to the remaining four. `März`, `Mai`, `Juni` and
`Juli` are deliberately untouched: they are written in full, so a period there
would be an error. The French catalogue in this repository already follows
exactly this rule (`janv. févr. avr.` with periods, `mars` and `août` without).

### `IMPROVEMENT - MEDIUM` — ASCII quotes where the source uses typographic ones — fixed

Four entries quoted an interpolated value with `\"` while their msgid uses
`“ ”`: `Move …`, the `%{count} result(s) for …` plural pair, the delete
confirmation and the reorder hint. Every sibling locale uses native quotes —
`fr` and `it` and `ru` use « », and `et` already uses `„ “`, the very pair
German needs. Now `„ “` here too, which also removes the escaping.

### `IMPROVEMENT - MEDIUM` — the `%B %d, %Y` date format — not changed, deliberately

The review observed that `locale_strftime/2` documents the format string as
itself translatable ("e.g. `%d %B %Y` for day-first locales",
`lib/phoenix_kit_publishing/web/html.ex:2925`) and that German is day-first, so
`%B %d, %Y` is not idiomatic.

That is correct as an observation, and it also retracts a claim made in the
earlier revision of this document, which asserted the identical msgstr was
"correct for a date pattern". It is not.

It is nonetheless left alone here: **every** locale in the repository — `en`,
`de`, `fr`, `it`, `et`, `ru` — carries `%B %d, %Y` unchanged. This is a
repository-wide gap, not something this PR introduced, and translating the
format in German alone would make it the sole outlier. Worth addressing across
all locales in its own change.

### `IMPROVEMENT - MINOR` — inconsistent phrasing for "sub-microsecond" — fixed

A second independent review found that two adjacent cache-settings strings in
`lib/phoenix_kit_publishing/web/settings.ex` (the toggle description at line
706 and the info footnote at line 817) both translate "sub-microsecond reads"
but landed on different German wording: "im Sub-Mikrosekundenbereich" in one,
"unter einer Mikrosekunde" in the other. Both are accurate; only the second
was changed, standardising the panel on "im Sub-Mikrosekundenbereich".

## Not done here

`@version` and `CHANGELOG.md` are deliberately left untouched for the
maintainer.

## Note for the maintainer

The branch's first commit is titled `i18n: add German storefront translations`,
which does not use the `Add`/`Update`/`Fix`/`Remove`/`Merge` prefix this
repository asks for. It was not amended in place because that commit SHA is
pinned in a downstream lockfile and rewriting it would strand that resolution
mid-flight — worth normalising on squash-merge instead.
