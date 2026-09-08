# Language routing: segments, dialects and the two-stage resolve

How a language code becomes a URL segment, how a base code resolves to an
enabled dialect, and why the editor asks the question twice.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Conventions → Language rules.

## Language segment ≠ language identity

Every public URL builder resolves its path segment through
`LanguageHelpers.public_url_segment/1`, but keeps the ORIGINAL code for the
per-language slug lookup and the `use_language_prefix?/1` decision.

When several enabled dialects share a base, the base's OWNER (primary-preferred,
then first-declared) keeps the historical base segment (`/en/…`) and a NON-owner
sibling gets its full lowercase code (`/en-gb/…`) — the only shape that can
address it at all. Enabling a sibling therefore never changes an existing URL.

Lowercase dialect segments are normalized back to the stored BCP-47 case
(`en-gb` → `en-GB`) in `RouterDispatch.enabled_dialect_case_insensitive?/2`,
`Web.Controller.Language.detect_language_or_group/2`,
`Posts.resolve_language_to_dialect/1` and `Listing.find_matching_language/2` — a
new match site must be case-insensitive too or it will miss every sibling URL.

## Only the PRIMARY language may go prefixless

Under the `default_language_no_prefix` setting (core's Languages module; the old
`publishing_default_language_no_prefix` key is migrated by core), only the
primary language may serve prefixless URLs.

Both `LanguageHelpers.use_language_prefix?/1` and
`Language.prefixed_default_language_request?/2` compare the resolved FULL code,
not the base — a base comparison also claims the primary's siblings, and
`/en-GB/…` would 301 to the prefixless URL that serves `en-US`.

## Language normalization on read

`Posts.read_post/4` and the slug finders retry through the legacy base language
on `:not_found` and fix stale content in place via `StaleFixer`. Don't pre-check
for staleness on the hot path — the retry-on-miss pattern keeps healthy reads at
one query.

## Base → enabled-dialect resolution

`Posts.resolve_language_to_dialect/1` (private, used by every `read_post*` entry
point) maps a base code (`"en"`) to whichever enabled dialect actually exists.
When several dialects share the base, it prefers
`LanguageHelpers.get_primary_language/0`, otherwise the first match in
`enabled_language_codes/0` declaration order; it falls back to
`DialectMapper.base_to_dialect/1` only when no enabled dialect matches the base.

The Listing builds `?lang=<primary_base>` for the editor's default click-through,
so this resolver is on the hot path for every "click a post title" navigation.

## The editor's two-stage flow

The Editor's UUID-mode and path-mode `handle_params` clauses must run
`Web.Controller.Language.resolve_language_for_post/2` (via the local
`new_translation_request?/2` helper) against `post.available_languages` before
deciding new-vs-existing translation. A naive
`language not in post.available_languages` check on the raw URL param routes
`?lang=en` against `["en-GB", "ru"]` into `handle_new_translation_params/6` —
which empties the form.

Two-stage flow on a click into the editor:

```
URL ?lang=<code>
     │
     ▼
new_translation_request?/2
     │   uses Web.Controller.Language.resolve_language_for_post/2
     │   against post.available_languages (Enum.find first match)
     ▼
┌──── resolved in available? ────┐
│ yes                         no │
▼                                ▼
load existing translation     handle_new_translation_params/6
     │                        (empty form)
     ▼
Publishing.read_post_by_uuid(language, …)
     │
     ▼
Posts.resolve_language_to_dialect/1
     │   against enabled_language_codes/0
     │   (primary tie-break, then declaration order;
     │    DialectMapper fallback if no enabled dialect)
     ▼
read content for the resolved dialect
```

The two stages answer the same "base → dialect" question with subtly different
tie-break rules and against different lists. A future unification
(`Languages.resolve_in/3` with a `:tie_break` opt) would close that divergence —
flag it for the next refactor that touches either layer.

## Translation deletion

Deleting a translation is a hard delete, and the primary language's row can't be
deleted at all. Both `TranslationManager.clear_translation/5` and
`delete_language/5` `repo.delete` the content row — an earlier
`status: "archived"` marking was reader-dead, since nothing filtered archived
rows, so a "deleted" translation kept serving publicly and `create_version_from`
resurrected it. Both refuse the primary row with
`:cannot_delete_primary_language`. A legacy base-code row (`"en"` while primary
is `"en-US"`) counts as primary; an enabled sibling (`"en-GB"`) does not.
Versions remain the only undo.
