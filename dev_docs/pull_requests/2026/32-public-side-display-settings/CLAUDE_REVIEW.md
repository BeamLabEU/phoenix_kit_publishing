# PR #32: Public-side publishing: featured posts, scroll rails, per-group display settings, translatable group name

**Author**: Max Don
**Reviewer**: Claude
**Status**: Merged
**Commit**: `9873502` (merge)
**Date**: 2026-07-17 (reviewed 2026-10-15, against `main` at `9e099a4`)

## Verdict

Mostly sound; two real bugs the earlier review missed, both in code this PR
introduced. The five-place parity for the 30 display settings holds (`GroupSettings`
keys, `Groups.config_setting_keys/0`, `db_group_to_map`, the schema accessors, the
form params), defaults agree across the spec/accessors/map, and group settings reach
the page only as whitelisted values (no class/CSS injection).

## Findings

### BUG - MEDIUM — `name_i18n` fallback leaked a sibling dialect's name

`PublishingGroup.resolve_name_translation/2` had a third fallback that matched ANY
stored code sharing the requested base. With `%{"name_i18n" => %{"en-GB" => "Colour
Blog"}}`, `en-US`, `en-AU` and bare `en` all got "Colour Blog". That breaks the
AGENTS.md language rule that a dialect's segment is not its identity and siblings
stay separate; with two overrides the winner depended on map order. Reaches the
listing h1, `og:title`, breadcrumb, RSS title and alternate links.
**Fixed:** only a bare-base request may borrow a dialect's override, and only when
exactly one dialect of that base carries one; otherwise the primary `name`.
Tests in `schema_test.exs` (sibling never borrowed; several dialects = ambiguous).

### BUG - MEDIUM — toggling a dependent block off and on reset its saved settings

The Featured / Latest / Timeline / Views blocks are `:if={checked?(…)}`, so their
inputs leave the DOM when the toggle is unticked. The `validate` handler rebuilt
the form from the incoming params alone, so re-ticking showed each select's first
option and the next Save persisted it (stored `featured_style=cover`,
`show_view_counts=true` became `classic` / `false`). Reproduced with a LiveView test.
**Fixed:** `validate` merges the incoming params over the form's current source
(`name_i18n` per language). Test: `edit_live_test.exs`, "unticking and re-ticking a
dependent toggle keeps its stored settings". (Also found independently in the
PR #36 review.)

### NITPICK — `merge_name_i18n` doc comment split in two

The `write_group_update_locked` comment and function were spliced into the middle
of it. **Fixed:** comment put back together.

### NITPICK — listing sort had no uuid tie-break

`sort_listing/2` was a bare `sort_by` while `chronological_posts` and `split_newest`
already break same-second ties on uuid, so slug-mode posts published in the same
second could reorder across cache rebuilds. **Fixed:** one `listing_sort_pair/1`
shared by all three sites.

### NITPICK — not changed

- `merge_name_i18n` accepts any binary language key with no count cap. Admin-authored
  data only; clutter at worst.
- `Web.Edit.mount/3` finds its group through `Publishing.list_groups/0` (twice, as
  mount runs twice) where `Groups.fetch_group/1` is a one-row lookup. Cheap at the
  group counts this module sees; left alone.
- `merge_bool_key` turns an unrecognised value (`1`, `"yes"`, `nil`) into `false` on
  the lenient `update_group/3` path. Documented as lenient by design.
