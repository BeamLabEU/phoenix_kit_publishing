# Leaf: let a host deny the visual and hybrid modes

**Requested by:** phoenix_kit_publishing
**Against:** leaf 0.4.1
**Size:** small — the mechanism already exists, it just stops short of these two modes

---

## What we need

`deny` can already remove the markdown and html modes. We need the same for
the other two:

```elixir
<.leaf_editor
  id="content-editor"
  mode={:markdown}
  deny={[:visual_mode, :hybrid_mode]}
  ...
/>
```

Result: the editor is markdown-only. No visual or hybrid tab in any of the
three mode switchers, and no other route into those modes.

## Why

Our post bodies are written with custom component tags — `<Showcase>`,
`<Note>`, `<Audio>`, `<Headline>`, `<EntityForm>` and friends. `preserve_tags`
handles them correctly and we use it, but it necessarily makes each one an
opaque block: safe from the HTML round-trip, and not editable without
switching to markdown anyway. So for this editor the visual surfaces offer
nothing and mainly create a way to get confused.

There is a sharper reason too. Before we passed `preserve_tags`, opening a
post in the default `:hybrid` mode and typing one character was enough for
autosave to write back a body with every component flattened into loose
paragraphs — silently, over the only copy. That was our bug, not Leaf's, and
`preserve_tags` fixes it. But the blast radius of *forgetting* that attribute
is total content loss, and a host that never enables the visual modes cannot
be bitten by it at all. Being able to opt out is defence in depth.

We currently pass `mode={:markdown}`, which is honoured on every mount (mode
isn't persisted client-side, so each page load starts there). The tabs are
still in the toolbar, so it's one stray click away from a mode we don't want
to support.

## Proposed change

Two new `deny` atoms, named consistently with the existing pair:

| Atom | Effect |
|------|--------|
| `:visual_mode` | Removes the visual tab; `:visual` is no longer reachable |
| `:hybrid_mode` | Removes the hybrid tab; `:hybrid` is no longer reachable |

### Code sites (0.4.1 line numbers)

1. **`mode_denied?/2`** — `lib/leaf.ex:3169-3172`. The two `false` clauses
   become deny-list checks, matching the markdown/html ones directly above:

   ```elixir
   defp mode_denied?(:hybrid, deny), do: :hybrid_mode in deny
   defp mode_denied?(:visual, deny), do: :visual_mode in deny
   ```

2. **`normalize_mode/2`** — `lib/leaf.ex:3164`. This currently falls back to
   `:visual` when the requested mode is denied, which stops being safe the
   moment `:visual` itself can be denied. It needs to fall back to the first
   mode that is *allowed*, in a defined order, rather than to a fixed one.

3. **The three mode switchers** — each needs the same `unless … in @deny`
   wrapper the markdown tab already has at `lib/leaf.ex:1291`:
   - `lib/leaf.ex:1250` — `data-mode-switcher="inline"` (fixed toolbar)
   - `lib/leaf.ex:1361` — `data-mode-switcher-compact` (narrow toolbar)
   - `lib/leaf.ex:1616` — `data-mobile-options-menu`, the "Mode" section

4. **The `:set_mode` command** — `lib/leaf.ex:168`. Should ignore a denied
   mode rather than honour it, so the deny list is one rule rather than a
   default a host can talk its way past. Worth checking the client too: the
   hook resolves `[data-mode-tab="<mode>"]` to perform the switch, so it
   should degrade quietly when that button no longer exists rather than
   throwing.

### Edge cases

- **Everything denied.** `deny: [:visual_mode, :hybrid_mode, :markdown_mode,
  :html_mode]` leaves no mode at all. Please make this loud — a raise with a
  clear message is much better than an editor that renders blank. It is
  always a mistake, never a configuration.
- **`mode` denied at the same time.** `mode={:visual} deny={[:visual_mode]}`
  is contradictory. Falling back to the first allowed mode is fine; so is
  raising. Just not silently rendering the denied one.
- **One mode left.** When only one mode survives, consider hiding the
  switcher entirely rather than rendering a single dead tab.

## Acceptance

With `mode={:markdown} deny={[:visual_mode, :hybrid_mode]}`:

- [ ] No `[data-mode-tab="visual"]` or `[data-mode-tab="hybrid"]` in the DOM,
      in any of the three switchers, at any viewport width
- [ ] `send_update(Leaf, id: …, action: :set_mode, mode: :visual)` leaves the
      editor in markdown mode and doesn't raise client-side
- [ ] Content, `{:leaf_changed, …}`, suggestions and the image/video toolbar
      all behave exactly as they do today in markdown mode
- [ ] Denying every mode raises with a message naming the problem

## Not blocking

We're fine in the meantime: `mode={:markdown}` starts every session in the
right place, and `preserve_tags` means a stray click into visual mode is
merely unhelpful rather than destructive. This is about removing an
affordance we don't want to support, not about fixing something broken.
