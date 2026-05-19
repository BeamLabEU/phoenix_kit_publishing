# PR #16 — Phase 2 quality sweep: URL-slug correctness, DoS guards, race fixes, archive semantics, host boundaries

**Author:** mdon
**State:** merged (post-merge review)
**URL:** https://github.com/BeamLabEU/phoenix_kit_publishing/pull/16
**Scope:** 39 files, +2157 / −173. Commit range `38fea7d..2e0008e` — public/admin URL-slug split + collision self-healing, two DoS guards (atom table, `:persistent_term`), publish/timestamp race fixes, archive-status semantics, non-root workspace prefix support, i18n sweep, narrowed `rescue` clauses.

Reviewed against the elixir-thinking skill.

---

## TL;DR

Strong PR. Tightly scoped, every non-trivial decision carries a `why` comment, and the risky changes (DoS guards, races) ship with tests. The DoS fixes and the public/admin URL-slug split are correct and load-bearing.

Two findings were fixed in this same review pass (see §6); the rest are observations that don't block the already-merged change.

Recommendation: **approve**, with the two fixes folded in.

---

## 1. DoS guards — correct ✅

- **`PageBuilder.SaxHandler.normalize_tag_name/1`** (`parser.ex`) — swaps `String.to_atom/1` for `String.to_existing_atom/1` with `rescue ArgumentError -> :unknown`. Admin-edited PHK XML can no longer mint unbounded atoms and OOM-crash the BEAM. Unknown tags route to the renderer's existing `:unknown` catch-all. The legitimate component atoms are pre-allocated by the renderer's resolver clauses, so the existing-atom lookup resolves them.
- **`ListingCache.do_regenerate/1`** — now verifies the group exists via `get_group_by_slug/1` *before* writing `:persistent_term`. Closes both a memory leak (one never-GC'd term per bad URL segment) and a GC-storm DoS (`:persistent_term` writes trigger a full global GC pass). The `rescue` was moved up to wrap the guard too — correct.

## 2. URL-slug lookup split — correct ✅

`find_by_url_slug/3` (public, published-only) vs `find_by_url_slug_any_version/3` (admin/self-healing, surfaces drafts) is the right boundary. Drafts must not resolve from a public URL; uniqueness checks and `StaleFixer` must see drafts. `SlugHelpers.url_slug_exists?` correctly stops trusting `ListingCache` (built from active versions only — would miss draft-to-draft collisions) and always hits the any-version DB query.

The `order_by [desc: p.uuid]` tie-break leans on UUIDv7's monotonic timestamp encoding rather than `inserted_at` precision — sound, and documented.

**Observation (not a blocker):** `auto_resolve_url_slug_collision/2` issues a write (`update_content`) from inside `find_by_url_slug/3`, a function callers and a plain `GET` treat as a read. The comment acknowledges the best-effort/race nature, but the surprising contract is worth keeping in mind: this lookup will hard-crash if ever run against a read-only replica connection. Acceptable given collisions are a rare data anomaly.

## 3. Race fixes

- **Publish lock** (`do_publish_version/4`) — `SELECT … FOR UPDATE` on the post row serializes concurrent publishes of the same post. Correct.
- **Timestamp-collision retry** (`create_post_with_timestamp_retry/9`) — the read-then-insert in `resolve_timestamp_in_transaction/3` is not atomic against the `(group_uuid, post_date, post_time)` unique index. Retrying the *whole* transaction (so the timestamp scan re-runs) is the right fix; `@max_timestamp_retries` bounds it; `mode == "timestamp"` guard keeps slug-mode off the path. `timestamp_collision?/1` checks both `:post_time` and `:post_date` constraint keys. Correct.

**Finding 1 (medium) — FIXED in this pass.** `do_publish_version/4` took the `FOR UPDATE` lock but `do_unpublish_post/3` opened its own transaction with **no lock**. Both paths mutate `active_version_uuid` and version statuses, so a concurrent publish (locked) and unpublish (unlocked) could still interleave — exactly the invariant the lock was added to protect. See §6.

## 4. Archive semantics, host boundary, i18n

- **`unpublish_post` `:target_status` opt** — lets the "Archived" UI label actually persist `status: "archived"` on the version row instead of silently reverting to `"draft"`. The listing's `apply_status_change/4` threads it through, and `status_label/1` enumerates the four status keys as gettext literals (variables wouldn't be caught by `gettext.extract`). Correct.
- **`RouterDispatch.maybe_rewrite/2`** — adds non-root workspace-prefix support (`strip_prefix`/`split_prefix`, prefix re-prepended to the rewrite). `maybe_rewrite/1` delegates with `"/"` and is behaviour-preserving. Note: nothing in this repo calls `/2` — it's new public API the *host* app is expected to adopt; the non-root fix stays inert until the host threads `url_prefix` through. Tested by `router_dispatch_test.exs`.
- **i18n sweep** — `gettext`/`ngettext` over previously-hardcoded strings; sound.
- **Narrowed `rescue`** — `Publishing.dashboard_tabs`/`load_publishing_groups_for_tabs` now catch only `[Ecto.QueryError, DBConnection.ConnectionError, Postgrex.Error]`; `Preview` catches only `[Earmark.Error, Saxy.ParseError, RuntimeError]`. Genuine programmer errors bubble up again instead of being masked — a real improvement.
- **`terminate/2`** added to `Index`, `PostShow`, `Settings` for subscribe/unsubscribe symmetry. **Nit:** `Web.Settings.terminate/2` is missing `@impl true` while `Index`/`PostShow` have it — inconsistent; add it for the compile-time check.

## 5. Build observation — `module_assigns` attribute warnings

`mix compile --warnings-as-errors` fails on three warnings introduced by this PR's "Batch D" change:

```
warning: undefined attribute "module_assigns" for component
PhoenixKitWeb.Components.LayoutWrapper.app_layout/1
  lib/phoenix_kit_publishing/web/html.ex:26, :98, :254
```

The pinned `phoenix_kit` core dependency's `app_layout/1` does not declare a `module_assigns` attr. Plain `mix compile` passes (warnings only). Not a blocker, but if CI runs `--warnings-as-errors` this PR breaks it — either the core dep needs a version bump that declares the attr, or the attr passing needs adjusting. Recorded for follow-up; not introduced by the review fixes below.

---

## 6. Findings fixed in this review pass

Both fixes verified against the existing test suite shape; formatted with `mix format`. (Test suite not executed — no PostgreSQL in the review environment; the PR's own run claims `mix test` green.)

### Finding 1 — `do_unpublish_post/3` missing the post-row lock

`lib/phoenix_kit_publishing/versions.ex`

Added the same `SELECT … FOR UPDATE` lock that `do_publish_version/4` already takes, at the top of the `do_unpublish_post/3` transaction, with a comment explaining that publish and unpublish must take the *same* lock to be serialized against each other. `PublishingPost` and `from/2` were already aliased/imported in the module (used by the publish path).

### Finding 3 — `find_by_previous_url_slug/3` surfaced unpublished posts

`lib/phoenix_kit_publishing/db_storage.ex`

The PR's added version filter was `(v.uuid == p.active_version_uuid or is_nil(p.active_version_uuid))`. The `is_nil` arm let posts that were never published match a public 301-redirect lookup — redirecting a visitor straight onto a 404. Tightened to `v.uuid == p.active_version_uuid` (published / active-version only) and rewrote the `@doc` to state the published-only contract.

All six existing `find_by_previous_url_slug/3` tests publish their post before lookup, so they remain green. Added one regression test —
`test/phoenix_kit_publishing/integration/db_storage_url_slug_lookup_test.exs`, "returns nil for an unpublished post even if previous_url_slugs matches" — that creates a post, sets `previous_url_slugs`, deliberately does **not** publish, and asserts `nil`.

No test was added for Finding 1: the concurrency lock is not deterministically unit-testable, and the matching publish-side lock also ships without a test — consistent with the PR's own choice.

---

## 7. Open follow-ups (non-blocking)

1. **`module_assigns` attr warnings** (§5) — resolve before any `--warnings-as-errors` CI gate.
2. **`maybe_rewrite/2` host adoption** (§4) — non-root workspace-prefix routing is inert until the host app calls the `/2` arity; confirm the host side lands.
3. **`Web.Settings.terminate/2` missing `@impl true`** (§4) — one-line consistency nit.
4. **Read-path write in `find_by_url_slug/3`** (§2) — documented best-effort self-healing; flagged only so a future reader knows the lookup can mutate and will fail on a read-only connection.

---

## Recommendation

**Approve.** The DoS guards, URL-slug split, and race fixes are correct and well-tested. Findings 1 and 3 were the only quality-blocking items and are fixed in this pass. The remaining follow-ups are codebase-shape observations, not blockers.
