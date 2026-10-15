# PR #36: Public-side Latest band + band styles, admin status fix, group AI translation, and a batch of UX improvements

**Author**: Max Don
**Reviewer**: Claude
**Status**: Merged
**Commit**: `599f0c5` (merge)
**Date**: 2026-07-21 (reviewed 2026-10-15, against `main` at `9e099a4`)

## Verdict

Sound overall. No CRITICAL/HIGH finding. Group AI translation is wired correctly:
actor attribution flows through `ActivityLog.actor_uuid/1`, the merge shares the
group row's `FOR UPDATE` lock with `Groups.write_group_update_locked`, the group
UUID is validated at enqueue, and PubSub is per-`{type, uuid}`. The admin status
fix only touches post-level status/date. Band styles come from an enum whitelist
(no inline `style=`), and all 23 new msgids are in the `.pot` and six `.po` files.

## Findings

### BUG - MEDIUM — re-ticking a band toggle reset its style (shared with PR #32)

The Featured style / Latest style selects live inside `:if={checked?(…)}`; this PR
added the two style selects to a pattern that already lost `featured_layout`,
`newest_layout` and the timeline granularity. See PR #32's review for the cause and
fix. **Fixed** in `Web.Edit` `validate`; the test covers the two selects this PR added.

### NITPICK — breadcrumb stale after a plain Save that renames the group

This PR added the stay-on-page Save; `page_crumbs` is only assigned in `mount/3`.
**Fixed:** a shared `group_crumbs/2`, re-assigned on save. Test in `edit_live_test.exs`.

### NITPICK — in-form preview and persisted value disagreed for a whitespace-only translation

`GroupAITranslateBinding.apply_translation/4` guarded on `name != ""` without
trimming; `GroupAITranslatable` trims and refuses blanks, so the form could show
`"  "` while the write was refused and the next Save deleted the key.
**Fixed:** the binding trims and ignores a blank name.

### IMPROVEMENT - MEDIUM (test gap) — `GroupAITranslateBinding` had no tests

**Fixed:** `group_ai_translate_binding_test.exs` covers `existing_translation_langs/2`
(blank override, no map) and `apply_translation/4` (merge, seeding, trim, length cap,
blank/absent name).

### NITPICK — not changed

- `put_translation/4` returns `{:error, :no_translated_name}`, which is not in
  `Errors.@type error_atom` nor given a `message/1` clause. The only consumer
  (`phoenix_kit_ai`'s worker) wraps it as `{:persist_error, _}` and never shows it,
  and adding the atom means a new msgid in six catalogues for a string no user sees.
  Revisit if a UI starts surfacing adapter errors.
- Band styles are never rendered with a real featured image in
  `display_settings_render_test.exs` (cover / cover_panel / top tests use image-less
  posts), so the `<img>` + scrim + link stacking and the `image_links` gating of
  `pointer-events-none` have no coverage. Worth a follow-up test.
