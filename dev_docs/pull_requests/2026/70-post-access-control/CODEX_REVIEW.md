# Review of PR #70

Reviewed the post access controls against the public controller, cached listings, file delivery, group defaults, and editor writes.

| Severity | Finding | Resolution |
| --- | --- | --- |
| BUG - HIGH | Post creation committed the draft before copying the group's defaults. A failed copy could leave an unrestricted draft available for later publication. | Create the post, version, content and rules in one transaction. The rollback test checks that the draft is absent. |
| BUG - HIGH | Concurrent first password saves could create multiple accepted passwords. Concurrent rotations could issue the same revision. Settings updates had the same read-modify-write race. | Lock the owning post or group during each write and refresh caches after commit. |
| BUG - HIGH | The unlock form could issue a grant for an unpublished post. File authorization also accepted existing grants after unpublishing and treated references from scheduled posts or trashed groups as public. | Check the active group, published version and release time at both boundaries. Regression tests cover unpublishing before and after unlock. |
| BUG - HIGH | The file index checked its invalidation marker before writing to the same slot. A late writer could overwrite an intervening invalidation. | Store the generation separately and validate it on reads. A test installs a stale result after invalidation. |
| BUG - HIGH | Caching an absent V4 table let a node treat newly protected posts as public after migration. | Recheck absence on each read and cache a positive result. The migration transition test exercises successive reads. |
| BUG - MEDIUM | Fifty encrypted grants can exceed the cookie size limit. An expiry tie could also evict the newly issued grant. | Reserve room for the newest grant and cap the cookie at 32. Exercise 55 consecutive grants through Plug's cookie encoder and decoder. |
| IMPROVEMENT - MEDIUM | A role-based listing looked up roles repeatedly across posts. The access panel also fetched the same role list twice. | Resolve the viewer's role UUIDs once per listing and reuse the panel's loaded roles. |
| IMPROVEMENT - MEDIUM | Honoring ambient PGDATABASE redirected the test schema and reset alias away from the repository's dedicated test database. | Preserve the existing partitioned test database convention. |

The storage guard requires a host core that invokes it. Direct object URLs in a public bucket remain public. The README describes both deployment conditions.

## Verification

The database-backed suite reported 3,141 tests, zero failures and one exclusion. The focused access suite reported 105 tests, zero failures and the same exclusion. The excluded end-to-end case requires a core with Storage.AccessGuard. The pinned core exercised the publishing guard directly. The repository's mix precommit gate passed.
