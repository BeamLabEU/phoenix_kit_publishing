# Follow-up from the GPT recheck

2026-10-23, based on `04a2017`.

- Resolved the medium-severity correctness finding: Preserve literal post-link tokens through the closing tag of the outer pre/code/link region.
- Added regression coverage and retained the existing sanitizer, confirmation
  and performance contracts. See [GPT_REVIEW.md](GPT_REVIEW.md) for reproduction,
  scope and validation.
- Claude's existing review is preserved. No release changes are included.
