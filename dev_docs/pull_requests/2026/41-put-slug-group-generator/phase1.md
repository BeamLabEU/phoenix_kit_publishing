# PR #41 Phase 1 Review — phoenix_kit_publishing
**Title:** Un-dead the group slug generator by adopting core's put_slug/3
**Author:** Max Don (mdon)
**Date:** 2026-08-14
**Verdict:** APPROVE WITH NOTES

---

## Summary

The changeset pipe in `PublishingGroup` had `validate_required([:name, :slug, :mode])` running six steps before `maybe_generate_slug()`. Any create without an explicit slug failed `"can't be blank"` before generation could run — the generator was dead code on the exact path it was written for. Every group creation required a hand-typed slug.

The fix is correct and minimal: remove `maybe_generate_slug/1` (26 lines), replace with `Slug.put_slug(:name, max_length: ...)` placed _before_ the `validate_required`. Core's `put_slug/3` preserves the same declared semantics (explicit slug wins, rename keeps existing slug) and adds collision probing (`-2`, `-3`, …) against the unique index instead of surfacing a raw constraint error. Cyrillic transliteration, which the old local `Slug.slugify(name, transliterate: true)` attempted but `maybe_generate_slug/1` never reached, now actually works.

Scope is appropriately narrow — `SlugHelpers` (reserved route words, slug style setting, SEO cap for posts) is product policy and intentionally untouched.

---

## Findings

### Blockers

None.

### Non-blockers

**1. No version bump or CHANGELOG entry**

This is a user-visible behavioral change: groups now auto-generate slugs on creation. Previously every create required an explicit slug or it failed. The PR description explicitly notes "No `CHANGELOG.md`, no `@version`." A patch bump (`0.x.y → 0.x.(y+1)`) and a CHANGELOG line documenting the fix are expected before merge. Not blocking review approval, but must be done before release.

**2. Dependency floor under-specified**

The mix.exs pin stays `~> 2.0`, but `put_slug/3` was introduced in phoenix_kit via PR #711 (now merged). Once phoenix_kit cuts a tagged release containing `put_slug/3`, the concrete floor should be tightened (e.g., `~> 2.1` or `>= 2.0.5, < 3.0.0`) so a consumer pinned to an older `2.x` patch doesn't get a compile-time `undefined function` error. For now, with core not yet released, this is fine — but it's a merge-day task.

**3. Merge sequencing dependency**

PR body correctly flags: do not merge before core ships `put_slug/3`. phoenix_kit#711 is merged; awaiting a tagged release. This is a process gate, not a code defect.

### Nitpicks

- The comment block added above `put_slug/3` in `publishing_group.ex` (lines 130–137) is longer than needed now that the test file documents the history. A one-liner referencing the dead-code fix would suffice. Minor style call.

---

## Stats

| Item | Detail |
|---|---|
| Files changed | 2 |
| Additions | 74 |
| Deletions | 26 |
| Tests | 5 new tests in `group_slug_test.exs`; 3 confirmed to fail against old code |
| Migrations | None (no schema change, changeset logic only) |
| Version bump | **Missing** — needed before release |
| CHANGELOG | **Missing** — needed before release |
| Dependency changes | Pin unchanged at `~> 2.0`; floor must be tightened post-core-release |

---

## Test Coverage Assessment

Coverage is solid for a focused fix:

| Test | What it pins |
|---|---|
| `creation without explicit slug — is now valid` | The core dead-code regression |
| `Cyrillic name romanizes` | Transliteration that the old code silently dropped |
| `explicit slug wins` | Preserved semantics |
| `rename does not move existing slug` | Preserved semantics |
| `collision suffixes -2` | New capability from core's probe |

The collision test actually inserts via `Repo.insert/1` — proper integration coverage, not just changeset-level.

---

## Recommendation

Code is clean, focused, and correct. Approve once author adds:
1. A `CHANGELOG.md` entry describing the fix.
2. A patch version bump in `mix.exs`.
3. (Post core-release) Tighten the `phoenix_kit` floor in deps.
