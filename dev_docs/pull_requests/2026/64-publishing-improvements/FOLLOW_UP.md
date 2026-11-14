# PR #64 follow-up

Claude review with the external panel on 2026-11-14; see [the review](CLAUDE_REVIEW.md).

- **Fixed:** every finding (import shape checks, prefix order, draft redirect, unroutable slugs, concurrent backdates, the categories dry-run preview, the 21st filter pick, excerpt fences), each with a test.
- **Open, for the maintainer:** core's sitemap and `public_url_prefix`; repair's info finding on V3's column.

## Maintainer review, 2026-11-14

See [the maintainer review](CLAUDE_MAINTAINER_REVIEW.md).

- **Fixed:** the conversion publishing scheduled posts (`:scheduled_posts`), giving two
  posts one URL, skipping `validate_slug/1`, and logging without the group; a save from an
  editor opened before the conversion; the kit-prefixed URL not redirecting unless the
  language was non-canonical; `import_post/3` leaving a post on a missing title, a NUL
  byte or invalid UTF-8; the earlier-minute search crossing midnight; the custom-field
  rows rebuilt by a save; `update_post` cutting or dropping `custom_fields`
  (`invalid_custom_fields`); an over-long category value refusing the whole batch; a
  stored invalid display value blocking later edits; a blank description as the excerpt;
  unclickable chips in the cover band; the per-call warning for a bad `public_url_prefix`.
  Each has a test.
- **Docs:** the machine API guide (`custom_fields`), the group settings guide
  (`public_listing`), AGENTS.md (36 display settings, the conversion's refusal), the
  migration comments that stopped at V2.
- **Not changed:** see "Not changed, on record" in the review.
