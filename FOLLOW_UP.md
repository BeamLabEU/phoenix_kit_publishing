# Follow-up — adversarial full-module audit

After-action report for the audit-driven work on `phoenix_kit_publishing`. All work is
local commits on top of `5e4582a`; nothing pushed. Suite (integration tier running):
**1134 tests, 0 failures**; `mix format`, `mix credo --strict`, `mix dialyzer` clean.

> The integration tier (`:integration`, ~520 tests) only runs when the Postgres test DB
> exists — it does here, so every fix below was exercised against the DB tier.

## Fixed (with regression tests unless noted)

**High:** H1 supervise the render cache · H2 write `previous_url_slugs` (301s) ·
H3 router host-route-hijack + method gate · H4/H5 two infinite-redirect loops ·
H6 spectator write guards · H8 version dropdown (mapper field) · H9 reload version-pinning.

**Medium:** M1 timestamp-collision retry (constraint-name match) · M2 trashed-slot
availability · M3 transactional post update · M4 atomic publish + StaleFixer demotion
heal · M5 remove dead per-post SEO/OG scaffolding · M6 cross-group UUID access ·
M7 cross-node cache invalidation (clustering) · M8 supervised lock-table + crash-proof
guard · M9 trash-not-delete + featured-image emptiness + ActivityLog · M10/M11/M12 code-
region integrity / multi-line `<Image>` / consistent escaping · M13 incumbent-wins
collisions + previous-slug containment + explain-and-link conflict modal · M14 remote-pid-
safe presence (clustering) · M15 stale translation lock · M16 admin-insight cache flip.

**Low + nits:** L1 switch_version crash · L2 preview save-failure · L3 unpublish pre-lock
read · L4 transactional blank-version · L5 stamp timestamp posts in the site time zone ·
L6 group-rename cache invalidation · L7 erase whole cache on disable · L8 double-backtick
code spans · L9 preserve unresolved `{{placeholder}}` · L10 token-scoped lock release ·
L11 narrowed update rescue · L12 fold timestamps into the posts term (cut churn) · title
`phx-debounce` · canonical/302 query-string preservation · reserved route words on
post/group slugs.

**H7 (boss-approved):** removed `<Hero>`/`<Page>` — they resolved to core modules deleted
with the Pages module (core 0fc3de09).

**Docs:** unique-index TODO in this `AGENTS.md`; signed file-URL hardening note in core
`AGENTS.md`.

## Open

- **M13 inline cross-post slug edit** — the conflict modal names + links the other post;
  editing *its* slug from inside the modal (cross-post mutation: its version, its previous-
  slug recording, its cache, concurrent-edit handling) is a tracked follow-up.
- **M13 #1 / core signed-URLs** — documented as TODOs (publishing + core `AGENTS.md`),
  both needing a migration / core changes.

The four previously-surfaced Lows (L5, L7, L10, L12) are now **fixed** above — each as a
focused commit with its own regression test. The two items here need a migration / core
work, so they stay tracked rather than parked.
