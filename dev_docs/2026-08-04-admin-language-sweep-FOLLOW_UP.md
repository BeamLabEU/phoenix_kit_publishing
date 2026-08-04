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
