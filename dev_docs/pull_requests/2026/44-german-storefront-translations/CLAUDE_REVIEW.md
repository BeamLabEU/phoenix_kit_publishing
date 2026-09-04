# PR #44 — Add German storefront translations

**Author:** timujinne · **Branch:** `feature/i18n-de` · **Reviewed:** 2026-09-04

Completes `priv/gettext/de/LC_MESSAGES/default.po` for the storefront and the
publishing admin. One file, no code, no schema.

## Verified, claim by claim

| Claim | Result |
|---|---|
| Full parity with the source template | ✓ 690 msgids in `default.po`, 690 in `priv/gettext/default.pot` |
| Nothing left provisional | ✓ 0 `#, fuzzy` entries |
| No silently untranslated strings | ✓ the only empty `msgstr ""` is the catalogue header itself |
| Correct language metadata | ✓ `Language: de`, `Plural-Forms: nplurals=2; plural=(n != 1);` |
| The catalogue actually compiles and serves | ✓ a host app pinned to this branch builds and renders German publishing pages on a live three-domain install (`.com`/`.de`/`.fr`) |

Spot-checked translations read as real German rather than machine filler,
including the technical strings that are easy to get wrong — for example
`"In Memory" means the cache is loaded into :persistent_term for
sub-microsecond reads.` → `"In Memory" bedeutet, dass der Cache für
Lesezugriffe im Sub-Mikrosekundenbereich in :persistent_term geladen wird.`
Format-only msgids such as `%B %d, %Y` are deliberately left identical, which
is correct for a date pattern.

## Findings

None at BUG or IMPROVEMENT severity.

**NITPICK** — the branch's single commit is titled `i18n: add German storefront
translations`, which does not use the `Add`/`Update`/`Fix`/`Remove`/`Merge`
prefix this repository asks for. It was not amended in place because the commit
SHA is pinned in a downstream lockfile and rewriting it would strand that
resolution mid-flight; worth normalising on squash-merge instead.

## Not done here

`@version` and `CHANGELOG.md` are deliberately left untouched for the
maintainer.
