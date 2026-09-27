# PR #55: Editor on Leaf done right, public-side fixes, core components, and the quality sweep

- Author: @mdon
- Status: merged as `d6f98470f82a695caad2e91cde4c4c214ff618b3`
- PR: https://github.com/BeamLabEU/phoenix_kit_publishing/pull/55
- Review date: 2026-09-27

This change brings the editor onto Leaf's content replacement and flush protocol,
updates public language canonicalization and fallback, serializes listing-cache
writes, adds visitor deduplication and media-folder expression indexes, and adopts
core UI components. It also changes several lookup API names and adds typespecs.

See [GPT_REVIEW.md](GPT_REVIEW.md) for findings, applied fixes, and validation.
