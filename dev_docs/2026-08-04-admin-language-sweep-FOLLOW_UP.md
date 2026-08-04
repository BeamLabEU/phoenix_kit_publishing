# Admin-side language + general sweep — after-action report (2026-08-04)

Reviewers: three internal review agents (editor slice, admin-LV slice,
translation/versioning slice) + external panel (codex, grok, zai ×2; kimi
hit its quota mid-round). ~45 verified findings after refutation; the
fixed set shipped in the accompanying commit. Every fix was verified by
the full suite (published pin AND local core, nothing excluded).

## Fixed in this sweep

Concurrency/integrity: StaleFixer publish-revert race (CAS pointer clear +
conditional orphan demotion + fresh re-reads); saves take the post lock
with an in-transaction version re-read (kills the save-vs-publish status
TOCTOU and AI fan-out lost updates on version.data); clear/delete
translation run locked with fresh last-row re-checks; version delete
re-checks last-version under the lock.

Language correctness: version-scoped collaborative form keys (cross-version
buffer injection); socket-scoped new-post keys (two admins' drafts shared a
lock); adding the second enabled sibling dialect works (the blank form no
longer self-destructs into the sibling); language pills open the version
actually holding the language (draft-only pills used to open a blank LIVE
form whose save published instantly); primary-language rows are
undeletable (clear/delete guard + error atom); delete_language hard-deletes
(archive semantics were reader-dead); AI source reads fail closed on a
language mismatch; deletion broadcasts and clear/create-version navigation
carry version + language pins; sibling-language editors reload on shared
version-field saves (mirrored editor_saved broadcast).

Admin UX/robustness: custom-type input no longer wipes the create-group
form (partial phx-change payload merge); group-slug collisions flash
instead of CaseClauseError (spec widened to match reality); name_i18n
merges per-key (disabled languages' names survive saves); erasing a custom
url_slug restores the default as promised; publish-failure flash names the
real reason and unblocks switching; remote version deletion does a full
editor transition (form + client content + URL); stuck translation locks
self-release when Oban is empty; PostShow live-updates (dead handler
shape) + group-membership check; malformed uuid/params no longer crash
LVs; index dashboard subscription dedup; presence sync marker cleared on
new-presence setup; unpublish-via-status-select explains itself.

## C12 re-validation round (same day, pre-PR)

Three fresh triage agents (playbook C12: security/error-handling,
translations/activity/tests, pubsub/cleanliness) re-swept the tree after
the rebase onto upstream 0.4.6. Fixed from their findings:

- **Group-settings save now locks the group row** (`lock_group_row!` +
  in-transaction re-merge) — two concurrent group-edit saves used to
  read the same `data` snapshot and the second silently reverted the
  first's setting keys (same class as the post-save lock).
- **Presence metas no longer replicate the full `%User{}` struct**
  (hashed_password included — `redact` only affects Inspect) —
  trimmed to `%{uuid, email}`, the only fields consumers read.
- **Failure-side activity logging** for categories (create/update/
  delete/reorder/file), translation add/clear/delete, version create,
  and public comment create — every user-driven mutation now leaves a
  `db_pending` audit row when it fails, matching the groups/posts/
  versions convention. Shared `ActivityLog.reason_string/1` keeps
  changesets (user free text) out of metadata.
- **Tautology tests made real**: the index-LV trash/restore/delete
  tests now pin DB state + the activity row's actor (non-default
  actor uuid); the editor save test reads the post back — doing so
  immediately exposed that the save had been failing all along
  (fake_scope's made-up uuid violates `fk_publishing_posts_updated_by`;
  the test now inserts a real user row). Listing trash/restore pin
  actor threading; `:cannot_delete_primary_language` string pinned.
- **Missed i18n**: `page_title` in listing ("Publishing") and editor
  ("Publishing Editor") gettext-wrapped; "Publishing Editor" filled in
  all five catalogues (the ten msgids agent 2 flagged were already
  extracted + filled earlier the same day; its scan predated that
  commit).
- Dashboard LV subscribes to the global groups topic BEFORE the first
  read (no lost group events in the mount window); dead
  `build_summary/2` + `:dashboard_summary` assign and dead
  `editor_presence_topic/1` removed; silent `handle_info` catch-alls
  now `Logger.debug`; category schemas got `@type t` and the
  `parent_uuid` FK constraint (no 500 on a raced parent delete);
  autosave debounce named (`@autosave_debounce_ms`); `@spec`s added to
  the three spec-less version reads.

Gates after the round: full suite 1563 tests green on the published pin
AND local core (`--include needs_unreleased_core`, plus a seed-0 run);
`mix precommit` clean (credo no issues, dialyzer 0 new).

## Open

None blocking. The items below are surfaced for Max's call — none are data
corruption, all were verified real:

1. **Listing translation-progress UI is dead code** (uuid-vs-slug lookup
   mismatch AND the progress/completed broadcasts have no callers). Wire
   it (editor broadcasts progress to the group topic) or delete the
   rendering? (~1h either way)
2. **Version-level fields still race a WARNED tab**: the sibling-reload
   fix covers clean tabs; a tab with pending work is warned but its next
   save still writes stale shared fields wholesale. Full fix = submit only
   changed version-level fields (load-snapshot dirty-tracking in
   persistence).
3. **In-flight debounced client edits after a language/version switch**
   can land in the new row (one-debounce window). Needs a client-side
   epoch (hidden form input + Leaf container id) — small JS+LV change.
4. **Domain-layer validation gaps** (programmatic API only): update_post
   applies url_slug with no format/reserved/uniqueness check;
   add_language_to_post accepts any string as a language code.
5. **Admin listing never heals legacy posts** (its fixer trigger is dead
   code — condition can never be true) and **per-post refresh drops the
   live overrides** (pills flip until reload). Both cosmetic-ish, same file.
6. **Group renamed elsewhere leaves an open listing stale** (old-slug
   queries + dead subscriptions).
7. **Category admin**: slug-clear flashes the wrong error; name_i18n has
   no UI (public renders translations no admin can edit).
8. **Group/category name resolution can cross sibling dialects** for the
   primary language (en-US page shows an en-GB-only override instead of
   the primary name column).
9. **Settings LV**: mutations unaudited (no activity rows), toggles flash
   success ignoring the write result, cache actions accept any slug.
10. **Query amplification**: admin index runs list_posts per group per
    refresh; settings page fully maps posts just to count them.
11. **language_enabled?/2 classifies a disabled sibling dialect as
    enabled** (base-matching) — feeds the editor's language pickers.
12. Minor: auto_clear slug commits outside the save transaction; a failed
    new-translation save leaves an empty (publicly hidden) stub row; the
    dead create-version-on-edit path would error if its flag were ever
    enabled; the editor still renders the Clear button for the primary
    language (server guard refuses; hiding it is cosmetic).

Added by the C12 re-validation round (all LOW/INFO, verified real):

13. **Broad `rescue` on read paths is systemic** — the documented
    graceful-degradation convention (survive the release-gated
    missing-table window), but most sites catch *every* exception, so a
    code bug degrades to `[]`/`nil`/`"draft"` with only a warning. The
    narrowed pattern already exists in-repo
    (`e in [Ecto.QueryError, DBConnection.ConnectionError, Postgrex.Error]`).
    Sweep the read paths onto it?
14. **`remove_group` has-posts guard is check-then-act** (count, then
    delete, no transaction) — a post created in the window is
    cascade-deleted despite `force: false`. Admin UI always passes
    `force: true`, so programmatic-API only.
15. **Concurrent add of the same language isn't idempotent** — the loser
    gets a unique-constraint changeset error instead of
    `{:ok, existing}`. Constraint prevents corruption; UX-only.
16. **`module enable/disable` + settings-LV toggles log success only /
    nothing** — enable/disable's actor is genuinely unavailable from the
    core module manager, and core convention audits only module
    enable/disable, not settings writes. Leave as-is, or thread actors
    through core?
17. Cleanups: `Errors.message/1` has no clause for
    `{:error, {:has_posts, n}}` (the one non-uniform group-API error
    shape, currently unreachable from UI); `Shared.audit_metadata(_,
    :create)` has zero internal callers (public facade only);
    `web/listing.ex`'s per-post loop re-evaluates
    `Constants.published?/1` up to 6× per row instead of hoisting it
    like `group_slug`/`public_url`.
