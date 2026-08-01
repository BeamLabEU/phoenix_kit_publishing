> **Legacy format.** The V2 schema is database-backed (see README.md for the current DB schema). This document describes the `.phk` flat-file format used in earlier versions.

# .phk Publishing Format (Legacy)

PhoenixKit's publishing module stores every post as a `.phk` file. Each file is a **YAML frontmatter block** followed by regular **Markdown**. Authors can sprinkle inline PHK components (for example `<Image … />`) anywhere inside the Markdown, but there is no longer a root `<Post>` wrapper or XML layout.

---

## Where posts live

Posts are kept under `priv/publishing/<group>/…` inside your host application (with legacy `priv/blogging/` fallback for existing content). The folder layout depends on the group's storage mode:

| Group mode | Path template | Example |
|-----------|---------------|---------|
| Timestamp (legacy/default) | `priv/publishing/<group>/<YYYY-MM-DD>/<HH:MM>/<language>.phk` | `priv/publishing/news/2025-01-15/09:30/en.phk` |
| Slug (new) | `priv/publishing/<group>/<post-slug>/<language>.phk` | `priv/publishing/docs/getting-started/en.phk` |

Each language/localisation of a post gets its own `.phk` file in the same directory.

---

## File anatomy

```yaml
---
slug: simple-version-original-size
title: Simple Version (Original Size)
status: draft            # draft | published | archived
published_at: 2025-11-07T22:42:00Z
created_at: 2025-11-07T22:42:17.231679Z
created_by_email: max@don.ee
updated_by_email: max@don.ee
---

# Heading 1

Standard **Markdown** lives here. Use `##` for subheadings, `-` for bullet lists, code fences, etc.

Inline PHK components can appear anywhere in the Markdown body:

<Image file_uuid="019a6f96-e895-74e2-a745-1b596ee235af" file_variant="medium" alt="Screenshot" />

Continue writing Markdown below the component.
```

### Frontmatter keys

Only a subset is required, but the publishing UI will populate everything shown above. Notable keys:

- `slug` – used for slug-mode directories and public URLs.
- `title` – displayed in admin tables and public templates.
- `status` – controls whether the post is discoverable publicly (`published` only).
- `published_at` – timestamp used for ordering and for timestamp-mode folders.
- `featured_image_id` – optional PhoenixKit Storage file ID used for the public listing thumbnail.
- `created_by_* / updated_by_*` – audit metadata; the editor manages these.

---

## Markdown + inline PHK components

After the frontmatter, everything is standard Markdown. The renderer automatically:

1. Runs Markdown through Earmark (GitHub-flavoured Markdown).
2. Scans for inline PHK components (`<Image />`, `<CTA />`, `<Headline>`, `<Subheadline>`, `<Video>`).
3. Renders those components with Phoenix components before returning HTML.

This means you can drop components alongside text:

```markdown
You can mix **bold text** and inline components:

<CTA primary="true" action="/signup">Start Free Trial</CTA>

- Bullet one
- Bullet two
```

### Supported inline components

| Component | Notes |
|-----------|-------|
| `<Image … />` | Works with either `src="/path/to/file.jpg"` or `file_uuid="…"`. Optional `file_variant="thumbnail" | "small" | "medium" | "large"` picks a specific variant from PhoenixKit Storage. The renderer now always returns the natural dimensions; add your own `class` if you want to constrain width. |
| `<Headline>…</Headline>` | Renders a hero-style heading. |
| `<Subheadline>…</Subheadline>` | Medium-sized supporting text. |
| `<CTA primary="true|false" action="/path-or-anchor">Label</CTA>` | Button styled by the admin theme. |
| `<Video …>Caption</Video>` | Responsive YouTube embeds. Provide either `video_id="dQw4w9WgXcQ"` or a `url="https://youtu.be/dQw4w9WgXcQ"`. Optional attributes: `autoplay`, `muted`, `controls`, `loop`, `start` (seconds), and `ratio` (`16:9`, `4:3`, `1:1`, `21:9`). Use the component body (or `caption="..."` when self-closing) to show a caption. |

Additional components can be introduced by adding Phoenix components under `lib/modules/publishing/components/` and registering them in the PageBuilder renderer.

---

## Storage integration & variants

When an `<Image>` references `file_uuid="…"`, the renderer calls `PhoenixKit.Storage.get_public_url_by_uuid/2`. The storage layer:

1. Looks for a matching file + variant (`original`, `thumbnail`, `small`, `medium`, `large`, etc.).
2. Returns the provider’s public URL if available (S3, R2, CDN…).
3. Falls back to PhoenixKit’s signed `/phoenix_kit/file/:id/:variant/:token` route for local/dev setups.

If a variant does not exist yet (for example someone references `medium` before the variant generator runs), the renderer falls back to `original`. The `<Image>` component now *always* renders the file at its natural size; supply your own classes (e.g. `class="w-full"`) if you need to stretch or constraint it.

---

## Complete example

```yaml
---
slug: product-updates-oct-2025
title: Product Updates – October 2025
status: published
published_at: 2025-10-31T09:00:00Z
---

# October Highlights

Thanks for building with PhoenixKit! Here are the highlights from this month.

<Headline>Maintenance Mode v2</Headline>
<Subheadline>Plan downtime with confidence.</Subheadline>
<CTA primary="true" action="/admin/modules">Enable Module</CTA>
<Image file_uuid="018e3c4a-9f6b-7890-abcd-ef1234567890" alt="Maintenance Mode Screenshot" />

## New referral analytics

- Multi-touch attribution
- CSV exports
- Improved fraud detection

<Image
  file_uuid="019a6f96-e895-74e2-a745-1b596ee235af"
  file_variant="thumbnail"
  class="w-full"
  alt="Referral dashboard"
/>
```

---

## Reference example – storage-focused post

```yaml
---
slug: storage-integration-example
title: Storage Integration Example
status: draft
published_at: 2025-07-01T10:00:00Z
---

# Working with PhoenixKit Storage

<!-- Example 1: Using direct URL -->
<Headline>Direct URL Image Example</Headline>
<Subheadline>This uses a direct asset path to display an image.</Subheadline>
<CTA primary="true" action="/signup">Get Started</CTA>
<Image src="/assets/dashboard-preview.png" alt="Dashboard Preview" />

<!-- Example 2: Using file_uuid -->
<Headline>Storage File ID Example</Headline>
<Subheadline>This pulls from PhoenixKit Storage.</Subheadline>
<CTA primary="true" action="/upload">Upload Image</CTA>
<Image file_uuid="018e3c4a-9f6b-7890-abcd-ef1234567890" alt="Uploaded Image" />

<!-- Example 3: Using file_uuid with variant -->
<Headline>Thumbnail Variant</Headline>
<Subheadline>Great for small inline previews.</Subheadline>
<Image
  file_uuid="018e3c4a-9f6b-7890-abcd-ef1234567890"
  file_variant="thumbnail"
  alt="Thumbnail Image"
/>

<!-- Example 4: Custom classes -->
<Headline>Custom Styling</Headline>
<Subheadline>Combine variants with Tailwind utility classes.</Subheadline>
<Image
  file_uuid="018e3c4a-9f6b-7890-abcd-ef1234567890"
  file_variant="medium"
  class="border-4 border-primary"
  alt="Styled Image"
/>
```

---

## Example – embedding a YouTube video

```markdown
## Watch the launch recap

<Video
  url="https://youtu.be/dQw4w9WgXcQ"
  autoplay="false"
  muted="false"
  ratio="16:9"
  start="42"
>
  Highlights from our community livestream.
</Video>
```

---

## Rendering pipeline (current behaviour)

1. **Frontmatter parsing** – YAML is parsed to capture metadata.
2. **Markdown rendering** – Earmark converts the Markdown body to HTML.
3. **Component pass** – the renderer finds inline PHK component tags and swaps them with Phoenix component output.
4. **Storage resolution** – `<Image>` elements fetch URLs from `PhoenixKit.Storage`; caching and signed URLs ensure files are served even when only local storage exists.
5. **Output** – the resulting HTML is cached for published posts to speed up public requests.

There is no longer a pure-XML PageBuilder flow; Markdown is the primary content format. The legacy component pipeline still powers inline components, which is why the supporting modules remain in the codebase.

---

## Stretch / align — breaking out of the text column

Every PHK component accepts two optional layout attributes, applied by the
renderer (no per-component support needed):

| Attribute | Values | Effect |
|-----------|--------|--------|
| `stretch` | `1`–`100` | The element renders that many percent **wider than the text column**, centered — `stretch="20"` is 20% wider (10% overhang each side). |
| `align` | `wide` \| `full` | Presets: `wide` = +30%; `full` = full-bleed to the viewport edge (1rem gutter). |

```markdown
<Image src="hero.jpg" alt="Skyline" stretch="20" />
<Headline align="wide">A title that escapes the column</Headline>
<Video src="launch.mp4" align="full" />
```

Rules of thumb:

- An explicit `stretch` wins when both are given.
- The overhang is automatically clamped to the space between the column and
  the viewport — on phones the element simply stays in the column. No JS.
- Invalid values (`0`, `>100`, non-numbers, unknown `align`) are ignored and
  the component renders normally.

---

## Audio — `<Audio>` and the post audio version

Inline audio in the body:

```markdown
<Audio file_uuid="018e3c4a-…" title="Episode 12" caption="42 min" />
<Audio src="https://cdn.example.com/ep12.mp3" />
```

Renders a native `<audio controls preload="none">` player — no JavaScript,
streamed on demand. `file_uuid` resolves through Storage's signed URLs (same
as `<Image>`); `src` accepts http(s) or root-relative URLs only.

Separately, the post editor's **Audio version** field (a Media ID) attaches
an audio rendition of the whole post — e.g. a narration. It renders as a
player above the content, and the group's RSS feed carries it as a podcast
`<enclosure>`, so a group whose posts have audio versions is subscribable in
podcast apps.

---

## Showcase bands — `<Showcase>`

An image bled to one edge with text on the other, the two sharing an
overlap so the words sit partly over the picture:

```markdown
<Showcase file_uuid="018e3c4a-…" side="left" overlap="18" alt="The bedroom">
### Paintings, reconstructed

Excitingly recreated and brought to life. Step into Van Gogh's bedroom!
</Showcase>
```

The body is ordinary Markdown (heading, paragraphs, links). Attributes:

| Attribute | Values | Effect |
|-----------|--------|--------|
| `file_uuid` / `src` | Media ID / URL | The image. `file_uuid` resolves through Storage (`file_variant` picks the variant, default `large`); `src` takes an http(s) or root-relative URL. |
| `alt` | text | Image alt text. Always set it. |
| `side` | `left` \| `right` | Which edge the image bleeds to. Default `left`. |
| `overlap` | `0`–`40` | How much of the band the image and text share, in percent. Default `15`. |
| `tone` | `page` \| `dark` \| `light` \| `none` | How the band is coloured. `page` (default) uses the page's own `base-100`/`base-content`, so there is no visible slab beside the image — the picture dissolves into the page. `dark` and `light` paint a deliberate band (dark background + light text, or the inverse) for a section that should stand apart. `none` inherits the theme and skips the tint entirely. |
| `height` | `short` \| `medium` \| `tall` \| `120`–`1200` | How tall the image area is: `short` = 18rem, `medium` = 26rem, `tall` = 38rem, or a plain pixel count. Omit it to keep the image's natural shape — which on a full-bleed band can be very tall. `object-fit: cover` crops to whatever you pick. |
| `align` / `stretch` | `full` \| `wide` \| `none` \| `1`–`100` | How far the band reaches past the text column. `align="full"` (the default here) runs to the page edge, `align="wide"` adds 30%, `stretch="20"` adds 20%, and `align="none"` keeps the band inside the column like ordinary prose. |

Behaviour worth knowing:

- The overlap is a real CSS grid track shared by the image and the text —
  the browser lays it out, there is no JavaScript.
- The image is blended into the band colour on the side the text comes
  from, and **the wider the overlap, the earlier that blend starts**, so
  the text stays readable.
- On narrow screens the two stack, the overlap becomes total, and the tint
  becomes a full vertical wash over the image.
- An unusable `src` (or none) renders the text on its own rather than an
  empty band.
- The band's height is the taller of the image area and the text, so a long
  paragraph still gets the room it needs even with `height="short"`.

---

## Author notes — `<Note>`

Annotate a phrase to clarify it for readers:

```markdown
The design uses <Note note="Content-addressed: the key is a hash of the bytes.">CAS storage</Note> under the hood.
```

Two display styles, chosen per group in the group's settings ("Author
notes style"):

- **Footnotes** (default) — the phrase gets a superscript number linking to
  a collected **Notes** section at the bottom of the post, plus a
  hover/focus popover showing the note text (pure CSS, no JavaScript).
- **Slide-out panel** — clicking the phrase slides a panel out from the
  right side with the note text; when the group has commenting enabled,
  readers can comment on that specific note inside the panel (the hover
  popover still works). Also pure CSS (`:target`), no JavaScript.

- Numbering is automatic and sequential through the document.
- A note's comment thread is anchored to the note's *text* (a content
  hash), not its number — inserting an earlier note doesn't detach
  comments; rewording the note does.
- The `note` text is plain text; it cannot contain double quotes (use
  apostrophes) and HTML in it is shown literally, never executed.
- A literal `<Note>` inside a code fence is left as code.

---

## Hashtags — tags live in the body

Tags are written inline as `#hashtags` — there is no separate tags field in
the editor. On save, the post's tag list is derived from the text (union
across all of the version's languages), and on the public page each hashtag
renders as a link to that tag's archive.

```markdown
We shipped the new importer today. #elixir #changelog
```

What counts as a hashtag: `#` followed immediately by a letter, at the start
of a line or after whitespace/`(`. Letters are Unicode; digits, `_` and `-`
may follow (up to 30 chars). By construction this excludes:

- Markdown headings (`# Title` — the space breaks the match);
- URL fragments (`…/page#section` — no preceding whitespace);
- anything in code fences or inline backticks;
- anything inside a Markdown link — `[jump](#section)` stays an anchor,
  and a `#word` in link text stays part of that link.

Dedup is case-insensitive keeping the first spelling; capped at 20 per post.
To remove a tag, remove it from the text and save.

The body is the **only** source of tags: there is no tags field, and a
`"tags"` list passed programmatically is ignored. That keeps the invariant
that every tag a post carries is visible in its prose — which is why the
post page no longer lists tags separately.

---

## Best practices

- **Let Markdown do the heavy lifting.** Use inline components only when you need structured UI blocks.
- **Always set `alt` text** for `<Image>` components.
- **Reference the correct blog mode path.** If you switch a blog from timestamp to slug mode (or vice versa), migrate the files accordingly.
- **Check variants in Storage.** If you expect `thumbnail` files, verify that automatic variant generation is enabled in Settings → Storage.
- **Keep frontmatter clean.** Avoid adding arbitrary keys unless the publishing UI or your host app actually reads them.
- **Preview before publishing.** The admin preview now uses the same renderer as the public site, so what you see there should match production output.

---

Built with ❤️ for PhoenixKit (updated early 2025)
