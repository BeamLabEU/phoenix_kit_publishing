# PR #5: Add routing anti-pattern pointer to AGENTS.md

**Author**: Dmitri Don (via mdon/main)
**Reviewer**: Claude
**Status**: Merged
**Commit**: `b8d5ad1` (merge of `0ed6197`)
**Date**: 2026-04-12 (reviewed 2026-10-15)

## Goal

One bullet in `AGENTS.md` telling agents never to hand-register plugin LiveView
routes in a host `router.ex`.

## Verdict

Sound. No code touched, no findings.

## What was checked

- **The rule is still true.** Publishing's `route_module/0` / `admin_routes/0`
  injection into `live_session :phoenix_kit_admin` is how the module works today.
- **The pointer survived.** The bullet was later rewritten and expanded in the
  "Conventions" section ("Never hand-register plugin LiveView routes in a host
  router"), including the live_session crash it prevents.
- **The referenced guide** (`guides/custom-admin-pages.md` in core) is not
  shipped inside the Hex package (`deps/phoenix_kit` has no `guides/`), so it
  could not be opened locally; the claim rests on core's repo.

## Findings

None.
