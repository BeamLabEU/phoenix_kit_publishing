# Follow-up

The reviewer applied its own fixes in `b6bd9c3`; this triage re-checks each one against current code.

## Fixed (pre-existing)

- ~~Creating a version could discard Leaf's latest keystrokes (BUG HIGH)~~ — `b6bd9c3`; `web/editor.ex:1291-1293` routes the event through `after_flush/2`, `web/editor.ex:2713-2726` (`create_version_after_flush/1`) saves via `flush_before_switch/1` before copying and re-checks `readonly?`; regression at `editor_switch_content_test.exs:192`
- ~~Visitor-table capacity suppressed every new view; an absent table also answered false (BUG MEDIUM)~~ — `b6bd9c3`; `views/visitor_table.ex:41-42` is now `size >= @max_rows or insert_new(...)`, so a full table and an absent one (`:undefined` sorts above any integer) both count the view; `visitor_table_test.exs:21`
- ~~Cold builds omitted the publishing routes from the test router (BUG MEDIUM)~~ — `b6bd9c3`; `test/support/dispatch_router.ex:30` requires `PhoenixKitPublishing.RouterDispatch` before `phoenix_kit_routes()` expands
- ~~Obsolete operational guidance (IMPROVEMENT MEDIUM)~~ — `b6bd9c3`; `AGENTS.md:258-261` names Create Version among the `after_flush/2` actions with the 1.5 s indicator and 6 s cancellation; the four resolved TODOs are gone; `views.ex:18` describes the last `x-forwarded-for` hop, matching `views.ex:143-163`

## Skipped (with rationale)

- "Browser JavaScript was not exercised by a real browser" — a statement of the review's scope, not a finding; no action asked
- "No core change is needed" for the cold-compile race — the reviewer's own conclusion; production hosts consume the compiled dependency

## Files touched

| File | Change |
|------|--------|
| — | none in this triage |

## Verification

Triage only (2026-10-05): every finding re-verified by reading current code at HEAD `4d41a85`. No suite or `mix precommit` run in this pass.

## Open

None.
