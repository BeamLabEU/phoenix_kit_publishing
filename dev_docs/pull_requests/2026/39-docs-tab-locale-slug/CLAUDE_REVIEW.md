# PR #39 — Contribute a Docs tab to the projects hub, move slug generation onto core

**Reviewed:** 2026-08-10 · **Author:** mdon · **Verdict:** merged, no changes
required. Released in **0.5.0**.

+233 / −6 across 4 files. Reviewed as part of the phoenix_kit 2.0 sweep.

## Docs tab

Same duck-typed, one-way projects-hub contract as `phoenix_kit_locations#10`
and `phoenix_kit_entities#26` in this sweep: `phoenix_kit_project_extensions/0`
is discovered by the projects package's `Extensions.Registry`, and this package
takes no dependency on projects.

Worth flagging for anyone copying the pattern — and the PR's own comment does
flag it: this contribution lives in `publishing.ex` rather than a
`PhoenixKitPublishing` top-level module, because this package's namespace is
`PhoenixKit.Modules.Publishing`. The registry scans **modules, not file paths**,
so discovery is unaffected. `project_extension_contract_test.exs` pins the
contributed shape.

The config links **one** publishing group per project by **slug**, which is
consistent — groups are slug-keyed throughout this package, so storing a uuid
here would have been the odd choice.

## Slug change — correct

`PublishingGroup`'s hand-rolled pipeline stripped every non-ASCII character, so
a Cyrillic group name produced an empty slug. Replaced with core's
`Slug.slugify/2` **passing `transliterate: true`**, which is the part that
matters: core's option defaults to `false`, and omitting it reproduces the exact
bug being fixed. Unlike `phoenix_kit_entities#26`, this PR makes no claim about
locale-awareness, so there was nothing to correct.

## Verification

| Check | Result |
|---|---|
| `mix precommit` | **passes** against core 2.0.0 |
| `mix test` | see below |

Sibling pins raised in step: `phoenix_kit_ai` → `~> 0.18`, `phoenix_kit_comments`
(test-only) → `~> 0.3`.
