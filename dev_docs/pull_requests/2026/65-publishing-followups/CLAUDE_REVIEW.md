# Claude Review — PR #65

**Reviewer:** Claude Opus 5.5, with the external panel (codex GPT-6.1, zai GLM-5.3, vibe Mistral Medium 3.5)
**PR:** Follow-ups to #64: image sizes, version labels, a custom-field filter, a sitemap refresh that follows core's switch, readable category errors, a group slug set for the dispatch, admin text fixes (mdon)
**Reviewed:** 2026-11-15

The author's own review of the branch before opening it. The `lib/` diff was pasted to each
seat (codex's sandbox cannot read files in the container), split in three areas:
- the slug set, the image sizes, the post-side sitemap triggers and the custom filter (codex);
- the category errors, the API messages, JSON-LD and the sitemap switches (zai);
- the slug set's invalidation paths, the dispatch change and the light/dark image pair (vibe).

The fixes went back to codex for a second round, and codex also reviewed the later commits:
version labels and the admin text and button fixes. Every finding was reproduced before it was
fixed, and each fix has a test.

## Findings

### BUG - MEDIUM — the custom filter missed keys spelt as the editor does not store them (fixed, dbc033f)
`list_published(custom: %{"Author" => "Ada"})` compared `"Author"` with the stored, normalised
`"author"` and matched nothing (vibe). Keys now go through `PublishingVersion.custom_field_key/1`.

### BUG - LOW — `<Image>` sizes skipped or doubled by text that looks like an attribute (fixed, 95a1a80)
The insert looked for ` width=` anywhere in the tag, so an alt reading `a width=1 shot` stopped
it, and it checked `width` only, so an existing `height` would have been doubled (codex). Quoted
values are blanked before the check, and both attributes are checked.

### BUG - LOW — the custom filter raised on a map value and dropped nil (fixed, 95a1a80, a14fbcc)
`custom: %{"k" => %{}}` raised `Protocol.UndefinedError`; `custom: %{"k" => nil}` matched nothing
(`List.wrap(nil)` is `[]`). A value that cannot be text now matches nothing and nil matches a
post without the field. In the re-review codex found that a key with nothing left after
normalising (`""`) then matched posts without the field, and that `"Version"` and `"version"`
collapsed into one constraint; both fixed.

### BUG - LOW — a non-string author width raised during render (fixed, 95a1a80, dbc033f)
`to_string(%{})` on a crafted `width`; a Storage exit escaped the rescue. Both are handled, and
integer sizes are accepted by `dimensions/1`.

### BUG - LOW — a label with invalid UTF-8 raised (fixed, a69992f)
`normalize_label(<<255>>)` raised in the whitespace regex before the validity check (codex).
Validity is checked first now.

### IMPROVEMENT - LOW — the disabled Public button's hint was not reachable by keyboard (fixed, a69992f)
The tooltip's wrapper had no focus target (codex); it has `tabindex="0"`, and the button keeps
its aria-label with the reason.

## Checked and not changed

- **A long-held transaction keeping the slug set stale** (codex): needs a request holding a
  REPEATABLE READ snapshot across five-minute rebuilds; no request path does that.
- **Markup core's Image never emits** (codex, re-review): `>` inside a quoted alt (HEEx escapes
  it), `<IMG`, `<img-widget>`, an `<img>` inside a script. The pattern was tightened to `<img\s`.
- **Which display error wins when several are invalid** (zai): the API now reports the first of
  colour, icon, SEO title, SEO description; before, the two SEO limits were checked in map order
  (description first). Only the message of a row with two bad SEO texts differs.
- zai's "no rescue in `request/0`" and "`all_group_slugs/0` may not exist" were outside the
  pasted context; both are in the code.

- **A crafted save of an older version's label** (codex): every sidebar field of the editor is
  disabled the same way on an older version; the label adds no new path.

## Verification

- `mix precommit`: exit 0 on the final tree.
- Full `mix test`: 3,000 tests, 4 failures, all timing tests (`HashtagsBoundsTest` ×2,
  `API.TextScanTest`, `API.CommonTest`'s `line_diff`). The same files run alone: 229 tests,
  0 failures.
