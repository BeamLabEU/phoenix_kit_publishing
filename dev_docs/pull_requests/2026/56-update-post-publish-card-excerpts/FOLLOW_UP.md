# Release recheck follow-up

2026-10-05: the [GPT release review](GPT_REVIEW.md) covers 0.12.0 through 0.13.1.
Resolved the five findings in source and regression tests:

- Leaf minimum now matches the editor's correlated flush protocol; later 0.x
  minors remain admitted. Host bundle upgrade guidance is in README.
- UUID-based updates check group ownership before writing.
- Version-history cache misses use the active version's access setting and number.
- Version dropdowns exclude unpublished archived drafts and versions beyond live.
- Blank versions retain the post's folder pointer; version creation uses the
  same post lock as saves and folder filing.

Full suite: 1,921 tests, zero failures. `mix precommit` passed. These fixes have
not been released to Hex; the package version remains 0.13.1.
