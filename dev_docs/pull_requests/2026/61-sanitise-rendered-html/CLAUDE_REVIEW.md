# PR #61: Sanitise the rendered HTML of posts with an allow-list

**Author**: Tymofii Shapovalov
**Reviewer**: Claude
**Status**: Merged
**Commit**: `849298f`
**Date**: 2026-10-23

## Goal

Markdown still renders with `unsafe: true` (admins author inline HTML), but post
bodies now also arrive from the machine API and from AI translation, so the HTML
that comes out of comrak goes through an allow-list cleaner (`Renderer.Sanitizer`
on `MDEx.safe_html/2`, i.e. ammonia) before it is cached or served. Closes #60.

## Verdict

Sound as a sanitiser: no bypass found. One gate failure (below), now fixed. The design choices that make it hold are the right ones:
the cleaner runs per Markdown segment and again over the assembled page, the
renderer's own stylesheets are appended AFTER it as static text instead of being
lifted out and put back, and `resolve_post_links/2` re-cleans whatever it inserts.
Apart from the dialyzer failure, only nitpicks, all on record below.

## What was checked

- **Every path to the page.** `rg` for `MDEx.`, `raw(` and `Phoenix.HTML.raw` over
  `lib/`: the only Markdown entry is `render_markdown_html/1`, and every
  `raw(@html_content)` in `web/html.ex` / `web/preview.ex` receives
  `render_markdown/2` output. Excerpts strip components first and then strip tags.
- **Hostile input through both profiles** (about 40 inputs run against
  `Sanitizer.author/1` and `page/1`): `javascript:` with leading spaces, with a
  tab inside the scheme, and entity-encoded; `data:` on `a` and `img`;
  `on*` / `phx-*`; `srcdoc`; `form action` and `button formaction` with
  `javascript:`; `svg` / `math` with `xlink:href`; the `noscript` and
  `form`/`math`/`mglyph`/`style` mutation vectors; `style` values with
  `u&#114;l(`, `-webkit-image-set(`, `behavior`; a `>` and a `<` inside an
  attribute value placed before a hostile `style` (the `filter_tags` regex relies
  on the cleaner escaping both, and it does). All removed or neutralised.
- **Component bodies.** Raw `<iframe>` / `<form>` / `<audio>` / `<section>` inside
  `Headline`, `Subheadline`, `CTA`, `Video`, `Showcase`, `Quote`, `Hero` and an
  unknown component do not survive the page profile (the looser one): component
  text is cleaned by the author profile first, and the page pass only widens what
  the renderer's own markup needs.
- **Process dictionary.** `with_generated_styles/1` restores the caller's
  collection (also on a raise) and the renderer starts no `Task`, so the keyframes
  collected by a scrolling gallery cannot be read from, or lost to, another
  process.
- **Cache.** `@cache_version` is `v9`, so nothing rendered before the sanitiser
  can be served from cache.
- **Tests.** `renderer_sanitize_test.exs` (548 lines) covers the dangerous list,
  unchanged editor output, the stylesheet tail and the linear-time claim.

## Findings

### IMPROVEMENT - MEDIUM — `mix precommit` failed at dialyzer on `main` (fixed)

`MDEx.safe_html/2` (mdex 0.14.2) is specced `escape: [atom()]`, but the option is a
keyword list: its docs and implementation read `escape: [content: false]`, which
`Sanitizer.clean/2` passes. Dialyzer therefore judged the call unable to succeed and
reported `clean/2`, `author/1` and `page/1` as having no return, plus 3 `no_return`
and 5 `unused_fun` warnings in `renderer.ex` that follow from it (30 errors, 14
skipped). Tests and credo were green, so the failure only showed in the gate.
**Fixed:** the call goes through a private `safe_html/2` that uses `apply/3` with a
non-literal argument list, with a comment saying why; no ignore entry was added, so
real `no_return` / `unused_fun` findings in `renderer.ex` still surface. Worth
reporting upstream (the spec should accept the keyword form).

### NITPICK — ammonia does not URL-check `cite` and `srcset`

The cleaner only applies `url_schemes` to `href` / `src` (and `object data`,
`video poster`). `<blockquote cite="javascript:…">` and
`<img srcset="javascript:… 1x">` pass in both profiles; `form action` and
`formaction` are not affected (the first is dropped by the cleaner, the second is
not in the allow-list). Neither `cite` nor `srcset` navigates or executes, so this
is not exploitable; recorded so nobody adds `srcset` to a rule that assumes it is
checked. **No change.**

### NITPICK — protocol-relative links and `target` without `rel`

`url_relative: :passthrough` keeps `//host/path`, and `link_rel: nil` keeps
`target="_blank"` with no `rel`. Both are intended for admin-authored content
(the machine API's text rule treats `//host` as dangerous and asks for a
confirmation), and current browsers imply `noopener` for `target="_blank"`.
**No change.**

### NITPICK — `id` is allowed and not namespaced

Page scripts look up `pk-progress-bar`, `pk-headings-config` and
`pk-timeline-config` with `getElementById`; an author element with the same id
earlier in the document is picked first. The headings and timeline config are read
with `getAttribute` into a label or a try/guarded JSON parse, the progress bar
gets a `style.width`, so the effect is cosmetic. **No change.**

### NITPICK — the note-ref stylesheet is written twice

`@note_ref_css` and `@notes_section_css` share three identical rules. They have to
stay byte-identical to the strings in `@constant_style_blocks`, which is why they
are two literals; building the second from the first by attribute interpolation
would remove the copy. Left as is: the risk of the refactor (a changed byte makes
the sheet vanish on pages with post links) outweighs the saving.
