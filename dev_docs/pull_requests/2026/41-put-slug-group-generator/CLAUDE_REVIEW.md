# PR #41 Review — Un-dead the group slug generator by adopting core's `put_slug/3`

**Author:** Max Don (@mdon)
**Reviewer:** Claude (Anthropic)
**Status:** Merged — post-merge review, fixes applied on `main`
**Commit:** `8166b62`
**Date:** 2026-08-14

> Prior review in this directory: [`phase1.md`](phase1.md) (APPROVE WITH NOTES). This
> file does not restate it. Where the two overlap — the missing version bump and the
> under-specified dependency floor — phase1.md called them "merge-day tasks"; they were
> never done, and the floor turned out to be a release blocker rather than a nicety.

---

## Verdict

The change itself is correct: `Slug.put_slug/3` before `validate_required/2` is the
right shape, and the semantics it preserves are the ones the local generator declared.

Two things it got wrong, both of the same kind — **the PR reasons about
`PublishingGroup.changeset/2` in isolation, and nothing in the application reaches
that path.** The headline claim ("a second group named alike now gets `-2` instead of
a raw constraint error") is not true through the admin UI, and the real generator —
the one in `Groups.add_group/2` that does run — had the exact collision bug the PR
set out to remove.

Plus one release blocker the PR knowingly deferred and merged without.

---

## Findings

### BUG — CRITICAL: the `:phoenix_kit` floor admitted cores without `put_slug/3`

`mix.exs` shipped `pk_dep(:phoenix_kit, "~> 2.0")` while `PublishingGroup.changeset/2`
now calls `PhoenixKit.Utils.Slug.put_slug/3`, which core added in **2.4.0**. Core's own
2.4.0 release note says it outright:

> Adopters must pin **`{:phoenix_kit, "~> 2.4"}`**: `~> 2.0` resolves to a core without
> this function, and the failure lands in the consumer's app.

A host resolving `phoenix_kit 2.0`–`2.3` alongside `phoenix_kit_publishing 0.5.x`
compiles clean and then raises `UndefinedFunctionError` on **every group create and
every group update** — the changeset is on both paths. This repo's own suite never
catches it because the lock resolves 2.5.0.

**Fixed** — floor raised to `~> 2.4` in `mix.exs`.

This collided with `test/core_pin_conformance_test.exs` (added by PR #40), which
asserted the requirement must admit core `2.0.0`. That test guards a real hazard — the
*three-segment* form `~> 2.4.x`, which expands to `< 2.5.0` and locks consumers out of
every later minor — but it encoded that invariant as "the floor is 2.0", which is a
different and now-false claim. `~> 2.4` is two-segment and admits every future 2.x, so
it does not trip the hazard. The test was updated to check what it actually means: two
segments, floor tracking the oldest core that has every API this module calls, all
later 2.x admitted, 1.x and 3.x rejected. Leaving the floor at 2.0 buys the consumer
nothing — it trades an honest `mix deps.get` failure for a runtime crash.

### BUG — HIGH: a trashed group still owns its slug, and the create path could not see it

`idx_publishing_groups_slug` is a plain `UNIQUE` btree on `slug` with **no status
predicate** (core V135). A trashed group therefore still occupies its slug.

`Groups.add_group/2` built its uniqueness probe from `list_groups()`, which is
`DBStorage.list_groups("active")` — trashed rows excluded. So:

```elixir
{:ok, _}       = Groups.add_group("News")   # slug "news"
{:ok, "news"}  = Groups.trash_group("news")
Groups.add_group("News")
#=> {:error, :already_exists}                # confirmed against the live DB
```

The admin types a group name, sees `already exists`, and finds no such group anywhere
in the active list. `check_slug_availability/3` reported the slug free, `ensure_unique_slug/2`
had nothing to suffix past, the insert hit the constraint, and
`create_and_broadcast_group/2` flattened the changeset to `{:error, :already_exists}`.

This is precisely the failure `put_slug/3`'s collision probe was adopted to prevent —
and `put_slug/3` cannot prevent it, because `add_group/2` derives and uniquifies the
slug itself and always hands the changeset an explicit one, so `put_slug/3` no-ops
(`fetch_change` → `{:ok, slug}` → return unchanged) on every production create.

**Fixed** — new `DBStorage.all_group_slugs/0` selects every slug regardless of status;
`add_group/2` probes that instead. `"News"` after trashing `news` now yields `news-2`,
and an explicitly-typed `slug: "news"` is refused at the context with
`{:error, :already_exists}` rather than crashing into the constraint.

Side benefit: the probe is now one `select g.slug` instead of `list_groups/0`, which
ran `StaleFixer.fix_stale_group/1` — a potential write — over every group on the create
path.

### BUG — MEDIUM: the suffix loop nested instead of counting

`ensure_unique_slug/3` recursed on the **suffixed** slug, so a third group named alike
got `same-name-2-3`, a fourth `same-name-2-3-4`. It also appended the suffix with no
regard for `max_group_slug_length`, overflowing the cap `validate_length(:slug, max:)`
enforces.

**Fixed** — replaced with core's `Slug.ensure_unique/3`, which counts from the base and
trims it to make room for the suffix. Third alike group is now `same-name-3`.

While there, the derived-slug branch of `derive_requested_slug/2` never ran
`Publishing.valid_slug?/1` — only the explicitly-typed branch did, so nothing checked
what the generator itself produced. The guard is now folded into the availability
predicate, so a disallowed derived slug is suffixed past rather than rejecting an
otherwise legitimate group name.

### IMPROVEMENT — MEDIUM: two slug rules for one column (documented, not changed)

The two generators produce different strings for the same name:

| | `Groups.add_group/2` (runs) | `put_slug/3` in the changeset (doesn't) |
|---|---|---|
| Rule | `SlugHelpers.slugify/2` — honours the `slug_style` setting (`:transliterate` / `:unicode` / `:ascii`) | core `LocaleSlug`, always romanized to ASCII |
| Cap | 60 (`@seo_slug_length`), trimmed at a hyphen boundary | 255 (`max_group_slug_length`) |

Measured on a 12-word name: 51 characters from the context, 155 from the changeset.
Under `slug_style: "unicode"` the divergence is categorical — the context writes
`привет-мир`, the changeset would write `privet-mir`.

**Deliberately not fixed.** The two caps are different layers, not a drift: 255 is what
the column and `validate_length/3` accept, 60 is SEO policy the context applies. Making
the changeset agree would either put product policy in the schema or leave the schema
disagreeing with its own `validate_length`. Since the changeset generator is
unreachable in the application, the practical exposure is direct
`DBStorage.create_group/1` callers and tests. Recorded so the limitation is on record
rather than rediscovered.

Related, and also left alone: `Publishing.valid_slug?/1` (groups) checks shape +
reserved language code, while `SlugHelpers.valid_slug?/1` (post URL slugs) additionally
rejects `@reserved_route_words`. A group named "Admin" is therefore slugged `admin` —
the segment `SlugHelpers.validate_slug/1` rejects for posts with the comment "a post
slugged 'admin' is unreachable behind the host's own routes". The same reasoning applies
to groups, but widening the group rule would start rejecting names hosts may already
use, and that is a maintainer's call, not a review's. The fix above routes derived slugs
through `Publishing.valid_slug?/1`, so if the rule is ever widened, generated slugs
inherit it for free.

### NITPICK: the PR's tests pin a path production does not take

All five new tests in `group_slug_test.exs` drive `PublishingGroup.changeset/2`
directly. They are correct about that function and worth keeping, but the "collisions"
test in particular reads as coverage of a behaviour the admin UI has — it isn't.

**Fixed** — added a `Groups.add_group/2` describe block covering the trashed-slug
collision (both derived and explicit), and the base-counting suffix.

### Resolved since the PR: the unreleased-core caveat

The commit message notes "the suite passes only with `PHOENIX_KIT_PATH=../phoenix_kit`".
Core 2.5.0 is in the lock now and the suite is green against Hex. The two unrelated
`@tag :needs_unreleased_core` tests (sibling-dialect locale acceptance, media-selector
`lock_file_type`) also pass, so the blanket exclusion in `test_helper.exs` was silently
skipping working tests. Tags and exclusion removed, per the instruction the helper
carried: "Delete each from the tests and this line as the pin catches up." Test count
1570 → 1575.

---

## Files changed by this review

| File | Change |
|------|--------|
| `mix.exs` | `:phoenix_kit` floor `~> 2.0` → `~> 2.4` (`put_slug/3` landed in 2.4.0) |
| `lib/phoenix_kit_publishing/db_storage.ex` | New `all_group_slugs/0` — status-blind slug probe matching the index |
| `lib/phoenix_kit_publishing/groups.ex` | `add_group/2` probes all slugs; `ensure_unique_slug/2` uses core's `ensure_unique/3` and honours `valid_slug?/1` |
| `test/core_pin_conformance_test.exs` | Invariant restated as two-segment + tracking floor; `@must_admit`/`@must_reject` moved to a 2.4 floor |
| `test/phoenix_kit_publishing/group_slug_test.exs` | Added `Groups.add_group/2` coverage for the real create path |
| `test/test_helper.exs`, 2 test files | Retired the stale `:needs_unreleased_core` exclusion |

## Verification

- `mix test` — 1575 tests, 0 failures, nothing excluded (was 1570 with 2 excluded)
- `mix precommit` — compile `--warnings-as-errors`, `deps.unlock --check-unused`,
  `hex.audit`, `format --check-formatted`, `credo --strict`, `dialyzer`
- Trashed-slug collision and the `-2`/`-3` suffix behaviour were reproduced against the
  live test database before and after the fix, not reasoned about from the source.
