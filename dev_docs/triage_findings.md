# Phase 2 Triage Findings (2026-04-26)

Three Explore agents scanned `lib/` and `test/` per the playbook. Findings condensed below; full agent outputs in their respective tool task transcripts.

## Agent #1 — security + error handling + async UX

| # | Severity | File:line | Finding |
|---|----------|-----------|---------|
| 1 | BUG-HIGH | renderer.ex:201-205 | Earmark `escape: false` — XSS risk on user-supplied markdown content |
| 2 | BUG-MEDIUM | listing.ex:38, editor.ex:150 | `group_slug` interpolated into paths without format guard at LV layer |
| 3 | (FP) | routes.ex:43-73 | "Authorization holes" — admin auth lives in parent live_session hook, that's the standard PhoenixKit module pattern |
| 4 | BUG-MEDIUM | web/edit.ex:104-107 | Broad `rescue e ->` in handle_event("save", …) catches everything |
| 5 | BUG-MEDIUM | listing_cache.ex:98-101, 123-130, 342-347 | Multiple `rescue error ->` in `:persistent_term` ops swallow legitimate failures |
| 6 | IMPROVEMENT-MEDIUM | activity_log.ex:26 + db_storage.ex create_post | Helper-built changesets need explicit `Map.put(cs, :action, …)` |
| 7 | BUG-MEDIUM | listing.ex:1153,1164; index.ex:580,590,599; settings.ex:437,450 | Missing `phx-disable-with` on destructive `phx-click` buttons (trash/restore/delete/cache) |
| 8 | IMPROVEMENT-MEDIUM | editor.ex:2096-2137 | AI translation buttons lack `phx-disable-with` + loading spinner |
| 9 | IMPROVEMENT-MEDIUM | settings.ex:344,450,503 | Cache mgmt buttons lack `phx-disable-with` |

## Agent #2 — translations + activity logging + test coverage

| # | Severity | File:line | Finding |
|---|----------|-----------|---------|
| 1 | BUG-MEDIUM | post_show.ex:138,178 | Status values rendered without `gettext`; need `status_label/1` helper with literal clauses |
| 2 | IMPROVEMENT-MEDIUM | listing.ex:875 | Flash "Status updated to %{status}" passes raw status; needs translation |
| 3 | (FP) | html.ex:361, preview.ex:295 | `String.capitalize(@group_slug)` is fine — slug is programmatic |
| 4 | IMPROVEMENT-MEDIUM | editor/helpers.ex:30,52, translation.ex:436, controller/language.ex:288 | Fallback `String.upcase(lang_code)` should route through gettext labels |
| 5 | (compliant) | — | No `@labels` module-attribute pattern present |
| **6** | **BUG-CRITICAL** | **posts.ex:159,217,246,270** | **POST CRUD entirely unlogged (create/update/restore/trash)** |
| **7** | **BUG-CRITICAL** | **groups.ex:185,209** | **GROUP CRUD entirely unlogged (update/trash)** |
| 8 | BUG-HIGH | versions.ex:115,314,327 | VERSION CRUD partially unlogged (create_new_version, create_version_from, delete_version) |
| 9 | BUG-HIGH | posts/groups/versions | Error branches never logged — need `db_pending: true` on `:error` paths |
| 10 | BUG-MEDIUM | posts.ex:159,246,270; groups.ex:185,209; versions.ex:327 | `actor_uuid` not threaded through most CRUD opts |
| 11 | (good ref) | posts.ex:217-226 | `update_post/4` correctly threads `Shared.audit_metadata/2` — replicate this pattern |
| 12 | DEFERRED | — | PII safety check deferred until C3 Errors module lands |
| 13 | BUG-MEDIUM | 6 LVs missing | No smoke tests for editor, edit, new, post_show, preview, settings |
| 14 | BUG-HIGH | index.ex, listing.ex, editor.ex handle_info clauses | No PubSub `handle_info` tests anywhere |
| 15 | IMPROVEMENT-HIGH | integration/posts_test.exs, groups_test.exs | CRUD error-path gaps (trash nonexistent, invalid params, race) |
| 16 | BUG-MEDIUM | 13 lib modules | No dedicated tests: activity_log, constants, db_storage, language_helpers, listing_cache, page_builder, presence, presence_helpers, routes, slug_helpers, stale_fixer, translation_manager, versions |
| 17 | (nit) | — | Test count is 453 not 451 (cosmetic) |
| 18 | IMPROVEMENT-MEDIUM | — | No concurrent-edit integration test |
| **19** | **BUG-CRITICAL** | **editor.ex 20+ handle_info clauses** | **All collaborative-editing state machine paths runtime-only** |
| 20 | (tooling gap) | — | `Changeset.cast/2` field lists not type-checked |

## Agent #3 — PubSub + cleanliness + public API

| # | Severity | File:line | Finding |
|---|----------|-----------|---------|
| 1 | BUG-HIGH | listing.ex:420 (last clause) | Missing `handle_info` catch-all → unknown PubSub messages crash LV |
| 2 | BUG-HIGH | editor.ex:1420 (last clause) | Same — missing `handle_info` catch-all |
| 3 | BUG-MEDIUM | pubsub.ex:61,114,128 | `broadcast_post_created/updated` send full record map → leak risk if logged |
| 4 | BUG-MEDIUM | groups.ex:318-319 (delete_and_broadcast_group) | Order is invalidate→broadcast; subscribers can race a stale read |
| 5 | IMPROVEMENT-HIGH | db_storage.ex (53 public fns) | Zero `@spec` annotations on entire data access layer |
| 6 | IMPROVEMENT-HIGH | shared.ex (19 public fns) | Same — zero `@spec` |
| 7 | IMPROVEMENT-MEDIUM | groups.ex:310-311 | `add_group` returns inconsistent `{:error, :already_exists}` shapes |
| 8 | NITPICK | posts.ex:32 | `@max_timestamp_attempts 60` — magic numbers elsewhere too |
| 9 | IMPROVEMENT-MEDIUM | posts.ex:217-232 | `update_post/4` couples DB update + broadcast + cache invalidate |
| 10 | BUG-MEDIUM | db_storage.ex:73-79 | `upsert_group/1` check-then-act on slug → race on concurrent insert |
| 11 | IMPROVEMENT-MEDIUM | pubsub.ex:29-527 (40+ public fns) | Missing `@spec` on PubSub module |

## Verification notes

- Agent #1 finding #3 (admin authz) — false positive; PhoenixKit modules rely on parent's `live_session :phoenix_kit_admin` `:on_mount` hook.
- Agent #2 finding #3 (`String.capitalize(@group_slug)`) — false positive; slug is programmatic.
- Agent #2 finding #5 — confirmed compliant.

## Cross-cutting themes for the sweep

1. **Activity logging is the biggest gap** — 4 critical findings across CRUD modules.
2. **PubSub safety** — 2 missing catch-alls (BUG-HIGH), full-record broadcast payloads, and broadcast/invalidate ordering.
3. **`phx-disable-with` ubiquity** — every destructive button missing it.
4. **`@spec` debt** — db_storage + shared + pubsub all lack typespecs (~110 public functions total).
5. **Test coverage gaps** — 6 admin LVs, 13 lib modules, all PubSub `handle_info` clauses untested. The 453-test suite mostly covers context modules; the web layer is thinly covered.
6. **Earmark XSS** — single highest-severity individual finding; needs html_sanitize_ex or similar (BUG-HIGH).
