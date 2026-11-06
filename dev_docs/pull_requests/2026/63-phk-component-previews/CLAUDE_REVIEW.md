# PR #63: Draw PHK components as previews in the editor

**Author**: Sasha Don (with Claude)
**Reviewer**: Claude
**Status**: Merged
**Commit**: `692ddeb`
**Date**: 2026-11-05

## Goal

Pass Leaf `media_url` (a signed medium URL for an `<Image>` or `<Showcase>`
`file_uuid`) and `tag_previews` (Headline, Showcase, CTA, Embed, Audio), so a
component reads in the editor as what it is rather than as a box of attributes.
The Leaf floor moves from 0.5.1 to 0.10.0 to get them.

## Verdict

The feature works. Run through a mounted editor and the real Leaf, every kind is
drawn, a `file_uuid` becomes a picture on its block and inside a `<Gallery>`, and
the signed URL stays out of the source Leaf writes back.

The diff is 36 lines, but the Leaf floor is the larger part of the change: it
jumps five minors and brings in 0.10.0's escaping, which changes what a stored
body can contain. The PR says nothing about that, and most findings below follow
from it. It also left the suite red.

One finding is open and needs a Leaf release: finding 5.

Each fix was reverted in turn (13 mutations) to confirm a test fails without it. One
test failed that check: the odd-run case passed with the fix removed, because a raw
`<image>` comes back from the cleaner as `<img>`, so it was rewritten around `<CTA>`.

## Findings

### 1. BUG - MEDIUM: the PR left the suite red (fixed)

`mix.exs` moved the floor to 0.10.0, but `test/leaf_pin_conformance_test.exs`
still asserted that 0.5.1 matches. That is the one failure on `main`.
`mix precommit` does not run `mix test`, so the gate could not catch it.

The test now pins the new floor and carries the reason for it.

### 2. BUG - MEDIUM: the floor admits a Leaf this editor should not run on (fixed)

0.10.1 fixes two bugs this editor walks into, and the requirement still allowed
0.10.0:

- Markdown inserted into a hybrid line that had not opened yet was escaped, so
  `[[A]] x` arrived as `\[\[A]] x`. The component toolbar and media inserts use
  `insert_markdown`.
- Text typed after a closed `[[…]]` link went into the link's span and was lost
  on save (`A [[B]] C` saved as `A [[B]]`). This editor turns wiki links on.

The floor is now 0.10.1. Core's `~> 0.10.0` admits it and the lock already has it.

### 3. BUG - MEDIUM: text Leaf wrote as literal rendered as a live component (fixed)

Leaf 0.10 writes a `<` typed as text as `\<`. Markdown reads that as a literal
`<`, and the editor shows one, but the renderer's component scanners are plain
regexes that ignore the backslash:

```
\<Image src="/a.png" alt="x"/>   ->  <p>\</p> and a live <img>
\<CTA action="/x">Go\</CTA>      ->  <p>\</p> and a live button labelled "Go\"
```

So the page disagreed with the editor and showed a stray backslash, and a `<Video>`
written as text became a live iframe. `Shared.strip_components/1` had the same
blind spot and left the backslash in excerpts.

`mask_scanned_code/1` now masks an escaped `<` as well as code, which covers the
note and component scanners in one place. It matches an odd run of backslashes
only: in `\\<Image` the backslash is what is escaped, and the tag is real.
`strip_components/1` gained a lookbehind. `add_component/3` now unmasks its
attributes, because `alt="a \<b"` would otherwise have carried the sentinel onto
the page. `@cache_version` is v10, as a renderer change requires.

### 4. BUG - MEDIUM: RSS descriptions showed the backslashes (fixed)

`Feed.item_description/1` sent `post[:content]` as it was, and that is Markdown: the
body's first paragraph. A typed `price *is* 5` now reached readers as
`price \*is\* 5`. The raw `**bold**` was already wrong before this PR. The cards and
`og:description` were never affected, because both go through
`extract_excerpt/1`. The feed now does too.

### 5. BUG - MEDIUM: a CTA's preview hides where it goes (open, needs Leaf)

Core's CTA reads `action`, the only destination attribute it has, and
`phk-publishing-format.md` documents that form. Leaf's `:button` kind reads
`href`, `url`, `link` or `to`, and files `action` under label synonyms. So
`<CTA action="/signup">Sign up</CTA>` draws a button with no destination line at
all. The generic box this PR replaced did show `/signup`.

The destination is still in the block's hover title and its source, so nothing is
lost, but the preview drops the one thing a writer usually checks.

Publishing cannot fix this: the attribute belongs to core's component and the
drawing to Leaf. Dropping `"CTA" => :button` would trade the button for the old
box, which is a worse preview for the common case. The fix is one line in Leaf,
adding `attr_value(attrs, "action")` to the `link` lookup in
`kind_preview(:button, …)`.

### 6. IMPROVEMENT - MEDIUM: the preview promised pictures the page would not show (fixed)

`component_media_url/2` gated on `Ecto.UUID.cast(String.trim(uuid))`, and the
renderer on `Shared.uuid_format?/1`. So `file_uuid=" <uuid> "` drew a picture that
the public page does not, and any 16-character string passed, because `cast/1` reads
it as a raw UUID. It now uses the renderer's gate. It downcases what it signs,
which `cast/1` had been doing quietly: the file route checks the token against the
stored uuid.

### 7. IMPROVEMENT - MEDIUM: no tests (fixed)

Nothing pinned either seam, and both fail silently: Leaf drops an unknown kind and
turns a raising `media_url` into no picture. `component_media_url/2` and
`component_tag_previews/0` moved to `Web.Editor.Helpers` so they can be tested
directly, and `editor_component_previews_test.exs` runs them through a mounted
editor.

### 8. IMPROVEMENT - MEDIUM: AGENTS.md drifted (fixed)

The Leaf paragraph still gave 0.5.1. The "Depends on" line was older still (core
`< 3.0.0`, AI `~> 0.18`, comments `~> 0.3`), left from `c706d20`, and was corrected
in passing. A new landmine records that a stored body can hold backslash escapes.

### 9. NITPICK: the raw-HTML guard read `\<b ` as HTML (fixed)

`__raw_html_content__?/1` forced such a post into markdown mode, showing the writer
the backslashes. It is text, which every surface round-trips.

### 10. NITPICK: the `mix.exs` comment gave the wrong reasons (fixed)

It justified the floor with `collapse: false`, which publishing never sets, and left
out `tag_previews` and `media_url`, the actual hard requirement.

### 11. NITPICK: Leaf's strings are mostly untranslated here (not fixed)

The new previews add English to a de/et/fr/it/ru admin ("Picture", "Embedded page",
"No address yet"). This is not new: only 11 of Leaf's 124 msgids are in this module's
catalogues. A `leaf` domain would close it, and Leaf looks there first, but
translating 113 strings into five languages is its own piece of work.

## Checked, sound

- **Hashtags survive the escaper.** `escapeLineStart` escapes `#` only before
  whitespace or the end of a line, so `#elixir` is untouched and tags still derive.
- **Post links are safe.** Wiki links are a raw context for the serializers.
- **Cards and `og:description`** render the Markdown, so escapes resolve.
- **`Metadata.extract_title_from_content/1`** has no callers.
- **`signed_url/2` is cheap enough for Leaf's "keep it cheap".** On the non-private
  path it is one MD5 and no query.
- **`Leaf.Sanitizer` keeps the previews.** Chips are restored after it runs.
- **Signed URLs stay out of saved bodies.** A chip serializes from `data-leaf-raw`.
- **`keep_live_content/2` is safe with the editor echoing `@content`.** It updates a
  server assign and pushes nothing to the client.
- **A `medium` variant still pending** redirects to the original, so it draws.
- **The Leaf ceiling.** Publishing's `< 1.0.0` is wider than core's `~> 0.10.0`
  on purpose, and core's requirement decides for a host.

## Limits of this review

- **Private libraries.** `signed_url/2` without `private: true` mints a permanent
  token, which the file route refuses for a private library, so such a file previews
  broken. The public renderer signs the same way, so the two agree. Read, not run.
- **The browser half was read, not driven.** The serializers were read in `leaf.js`,
  and the server half was exercised through a mounted LiveView. Nothing was clicked
  in a browser.
