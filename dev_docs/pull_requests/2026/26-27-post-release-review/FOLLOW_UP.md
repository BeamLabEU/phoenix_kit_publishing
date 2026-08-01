# FOLLOW_UP — PRs #26 / #27 (post-release review)

Triaged 2026-08-01.

## Fixed (in the review itself)

Mistral found a real bug — a single-backtick code span running over a line
break wasn't recognised as code, so a component shown as an example rendered
live — and proposed `` `[^`]*` ``. The Claude re-review kept the finding,
corrected the severity (admin markdown renders with `unsafe: true` by design,
so this is rendering correctness rather than a new XSS vector) and replaced
the fix: `` `[^`]*` `` matches across a blank line, which swallowed a real
component sitting between two stray backticks in different paragraphs.

Shipped as `` `(?:[^`\n]|\n(?!\n))*` `` — soft line breaks yes, paragraph
boundary no. Re-verified against current code at `renderer.ex:315`. Both
cases are pinned in `renderer_test.exs`.

## Fixed (2026-08-01)

The review's "Other Observations" were carried forward from PR #25 and are
resolved there — see
[../25-adversarial-full-module-audit/FOLLOW_UP.md](../25-adversarial-full-module-audit/FOLLOW_UP.md).
In short: multi-tab overwrite fixed as data loss (4c6c6cc), preview spinner
and translation double-enqueue already shipped, video paths verified
consistent, `"published"` centralisation surfaced to Max.

## Verification

`mix test` 1525 tests / 0 failures.

## Open

None.
