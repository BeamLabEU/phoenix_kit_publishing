# Review of PR #61

Reviewer: GPT / Codex. Date: 2026-10-23.
Merged commit: `849298f`; recheck based on `04a2017`.

## BUG - MEDIUM: closing nested code ends a surrounding literal region

The post-link region splitter paired a `<pre>`, `<code>` or `<a>` opener with
the first closer of any of those elements. For example:

```html
<pre><code>sample</code>[[post:UUID|Literal]]</pre>
```

The `</code>` ended the skipped region even though the token still belonged to
`<pre>`. The link resolver rewrote the supposedly literal example. The same
problem affected `<a><code>sample</code>...token...</a>` and could introduce a
second link inside an existing one. This is an inherited correctness issue
retained by #61's new linear-time splitter, not a demonstrated sanitizer bypass.

Fixed the splitter to scan skip tags once and track their names on a stack.
Only closing the outer element completes its protected region. A mismatched
closer cannot close a different tag. Replacements outside the region still run
through the final sanitizer, and generated styles are preserved as before.

Two new regressions failed before the fix: nested code inside both `<pre>` and
`<a>` must preserve its surrounding token; a separate token after the outer
region must still resolve. The existing 260 KB malformed-tag timing cases pass
with the stack traversal, as do the stylesheet-tail and hostile-markup tests.

## Scope and limits

Rechecked the sanitizer allow-lists, inline CSS filtering, author/page profile
boundaries, final page cleaning, generated stylesheet collection and tail
recognition, and the post-link pass. Compared allowed form attributes with the
optional Entities form component, and checked Embed/Audio component output and
its URL handling. No new executable-HTML bypass was established. This was source
review and automated rendering coverage, not a browser security assessment.
The MDEx typespec workaround from Claude's review remains necessary for the
locked dependency and was left intact.

## Validation

- Baseline full suite: 2,713 tests, zero failures, seven excluded.
- Sanitizer suite after the fix: 54 tests, zero failures, including performance
  bounds, component profile behavior and generated stylesheets.
- Combined API/executor/sanitizer regressions: 224 tests, zero failures.
- `mix precommit`: passed; no new Dialyzer suppressions.
- Final full suite: 2,718 tests, zero failures, seven canonical URL tests excluded.
- `git diff --check`: passed.
- Version and CHANGELOG are unchanged.
