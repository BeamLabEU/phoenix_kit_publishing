# MarkdownEditor: inline suggestions (`#tag` autocomplete and beyond)

**For:** the developer maintaining `PhoenixKitWeb.Components.Core.MarkdownEditor`
(core: `lib/phoenix_kit_web/components/core/markdown_editor.ex` + the
`MarkdownEditor` hook in `priv/static/assets/phoenix_kit.js`).

**From:** publishing (`phoenix_kit_publishing`), which now stores tags as
hashtags typed into the post body and wants autocomplete while writing.

**Status of this doc:** a request + proposed contract. The API shape is a
starting point, not a decision — anything marked *(your call)* is yours.

---

## 1. Why publishing needs this

As of `b509330`, publishing has **no tags field**. Tags are `#hashtags`
written inline in the post body; on save the post's tag list is derived
from the text (union across the version's languages), and the public page
renders each hashtag as a link to its tag archive.

That makes tagging fast to write but easy to fragment: nothing stops a
writer typing `#elixir`, `#Elixir` and `#elixir-lang` across three posts.
Dedup is case-insensitive, so the first two collapse — the third doesn't.
The fix is suggesting existing tags **as they type the `#`**, which needs
editor support we don't have.

Publishing already owns the data side (which tags exist in a group, with
usage counts). What's missing is the editor half: detect the trigger,
show a popup, insert the pick.

---

## 2. What exists today

Read from the current source; no changes assumed.

| Capability | Where | Notes |
|---|---|---|
| Textarea + cursor tracking | hook `_acquireTextarea` | tracks `lastCursorPosition` on blur/select/click/keyup |
| Formatting toolbar | `data-md-action` + `_handleToolbarMouseDown` | wrap / line-prefix / insert / link |
| Insert at cursor from server | `update(%{action: :insert_at_cursor})` → `push_event("markdown-editor-insert")` | used for `<Image>`/`<Video>` inserts |
| Client prompt + insert | `action: :prompt_insert` → `window.prompt` | used for video URLs |
| Content → host | textarea `phx-keyup="editor_content_change"` → `send(self(), {:editor_content_changed, …})` | host folds into its own form |
| Multi-editor safety | `global_id` echoed in every `push_event`, hook filters | the established pattern; keep it |
| Enter handling | `_handleEnter` | markdown list auto-continue |
| Save / dirty state | `data-save-status`, `changes-status`, `beforeunload` | opt-in nav guard |

**No** suggestion/typeahead/popup machinery of any kind exists in the editor.

### Prior art worth copying (already in core)

- **`PhoenixKitWeb.Components.Core.SearchPicker`** — a generic instant
  typeahead where *the client renders everything* and the server only
  answers the search over `push_event`. Its contract (search event →
  results event carrying the query it answers) is almost exactly what we
  need, minus caret anchoring. Its moduledoc also documents the
  multi-instance trap: `push_event` replies broadcast to **every** hook
  listening on that event name, so payloads must carry an id and each
  instance drops what isn't addressed to it.
- **`RowMenu` hook** — portals its dropdown to `<body>` while open, which
  is how it escapes `overflow` clipping from ancestors. A caret popup
  inside a scrollable editor panel will need the same trick.

---

## 3. Two defects this feature will amplify (please fix first)

Both verified in a live browser against the current build, 2026-07-29.

### 3.1 Programmatic edits destroy the browser's undo stack — **P0**

`_insertAtCursor`, `_wrap`, `_linePrefix` and `_link` all assign
`textarea.value` directly. Assigning `.value` clears the native undo
history in Chromium/Firefox.

**Repro (Chrome, verified):**

1. Focus the editor, type `hello world` with real keystrokes.
2. Run `ta.value = ta.value + " PROGRAMMATIC"` (what the toolbar does).
3. Press Ctrl/Cmd+Z.
4. **Observed:** nothing happens. The value stays `hello world PROGRAMMATIC`
   — undo can restore neither the programmatic write *nor the typing that
   preceded it*. The whole stack is gone.

**Fix candidate (verified working in the same session):**
`document.execCommand("insertText", false, text)` inserts at the current
selection *and* preserves undo — after the same probe, Ctrl+Z correctly
reverted only the insertion and left `typed base` intact. It's deprecated
but remains the practical approach for textareas; the modern
`beforeinput`/`InputEvent` path is the alternative *(your call)*.

This matters for autocomplete because every accepted suggestion is a
programmatic edit. Without the fix, using the feature silently disables
undo for the rest of the session — worse than not having it.

### 3.2 Content sync rides `keyup` only — **P0 (or at least, know it)**

The textarea syncs to the server via `phx-keyup="editor_content_change"`.
Programmatic edits work around this by dispatching a **synthetic keyup**
(`_notifyChange`). Consequences:

- A value change with no key event never reaches the server: paste via
  context menu, drag-dropped text, and (in our experience) browser
  automation `fill`. The editor shows "Post saved" while persisting
  **empty or stale content** — no error, no warning. We lost content this
  way while testing and it took a while to see.
- Every hook path that edits text must remember to fake a keyup. A new
  code path that forgets it fails silently.

**Ask:** drive the sync from the `input` event (which covers typing,
paste, drop, IME commit, and `execCommand` insertions) instead of
`keyup` + synthetic events. Keep the existing debounce.

> Note for whoever does this: publishing's editor form has a
> `phx-change` on the surrounding form, but it ignores `editor_content`
> (the content path is the LiveComponent's own event), so switching to
> `input` shouldn't double-post content — worth a check on your side.

---

## 4. The ask: a generic inline-suggestion API

Publishing needs `#`. But building it as "hashtag support" would be a
waste of the same 90% of the work, so **please make the trigger a
parameter, not a feature.** The same machinery then gives the whole
ecosystem:

| Trigger | Suggests | Who wants it |
|---|---|---|
| `#` | existing tags in the group | publishing (now) |
| `@` | users / staff | core has users; CRM, staff, comments |
| `/` | PHK components (`<Image>`, `<Video>`, `<Audio>`, `<Note>`, `<CTA>`…) | publishing — would replace toolbar + `window.prompt` |
| `:` | emoji | anyone |

The editor should know **nothing** about tags. It detects a trigger, asks
the host what matches, renders the list, inserts the chosen value.

### 4.1 Proposed component API *(shape is your call)*

```elixir
<.live_component
  module={PhoenixKitWeb.Components.Core.MarkdownEditor}
  id="content-editor"
  content={@content}
  suggestions={[
    %{
      trigger: "#",
      # Fire only at a token boundary — start of line, whitespace, or "(".
      # Publishing's hashtag rules must match exactly (see §5).
      boundary: :word_start,
      # Characters that may continue the token after the trigger.
      token: ~r/[\p{L}\p{N}_-]/u,
      min_chars: 0,        # 0 = open the list on the bare trigger
      debounce: 150,
      max_results: 10,
      allow_create: true,  # offer "Create #newtag" when nothing matches
      insert_suffix: " ",  # what follows the inserted value
      label: "Tags"        # for the popup header / SR announcement
    }
  ]}
/>
```

### 4.2 Proposed round trip

Consistent with how the editor already talks to its host (`send/2` to the
parent LiveView, `send_update/2` back):

1. **Editor → host** (process message, like `{:editor_content_changed, …}`):

   ```elixir
   {:editor_suggest, %{editor_id: "content-editor", trigger: "#", query: "eli", seq: 7}}
   ```

2. **Host → editor** (`send_update/2`, mirroring `:insert_at_cursor`):

   ```elixir
   send_update(MarkdownEditor,
     id: "content-editor",
     action: :suggestions,
     trigger: "#",
     query: "eli",          # echoed so the client can drop stale replies
     seq: 7,                # ditto, monotonic per editor
     results: [
       %{value: "elixir", label: "#elixir", sublabel: "12 posts", icon: "hero-hashtag"}
     ]
   )
   ```

   → `push_event("markdown-editor-suggestions", %{global_id: …, …})`.

3. **Client** renders, handles keyboard/mouse, and on accept replaces the
   token (from the trigger char through the caret) with `value <>
   insert_suffix`.

**Staleness:** the client must drop any reply whose `seq`/`query` doesn't
match what's currently typed — keystrokes outrun round trips constantly.

**Never block typing.** If the host never answers, the popup shows a
spinner and closes quietly; the writer keeps typing and the manual
`#tag` they typed is already valid. This is an enhancement over a system
that works fine without it.

---

## 5. Trigger rules must match publishing's parser

Publishing derives tags from the saved text with these rules
(`PhoenixKit.Modules.Publishing.Hashtags`). A suggestion that inserts
something the parser then ignores is worse than no suggestion:

- Trigger is `#` **at start of line, or after whitespace, or after `(`**.
- The first character after `#` must be a **letter** (Unicode — `#новости`
  is a valid tag); then letters, digits, `_`, `-`, up to 30 chars.
- **Not** a tag, and the popup must not open: inside fenced/inline code,
  inside a Markdown link or image (`[jump](#section)`), in a URL fragment
  (`…/page#section` — no preceding whitespace), and `# Heading` (the
  space after `#` breaks it).

The code/link exclusions are the fiddly ones. A pragmatic client-side
approximation *(your call)*: track whether the caret is inside an unclosed
fence or backticks and inside `](…)`, and suppress there. If that's too
messy, we can live with v1 firing in code blocks as long as **accepting**
a suggestion is the only thing that inserts text — a stray popup is
cosmetic; a stray insertion is not.

---

## 6. TODO list

Grouped by priority. Acceptance criteria are the point — feel free to
reshape the implementation.

### P0 — prerequisites

- [ ] **Preserve undo on all programmatic edits** (§3.1). *Accept:* type,
      apply a toolbar action, Ctrl+Z → the action is undone and the typed
      text survives. Covers toolbar, server inserts, and suggestion accepts.
- [ ] **Sync content from `input`, not `keyup`** (§3.2). *Accept:* paste via
      right-click → menu, and drag-dropped text, both reach the server; no
      synthetic `KeyboardEvent` remains in the hook.

### P1 — the core loop

- [ ] **`suggestions` config attr** on the component; absent/empty = today's
      behavior exactly, zero new DOM or listeners.
- [ ] **Trigger detection** honoring boundary + token charset + `min_chars`,
      with the exclusions in §5 (or the documented v1 subset).
- [ ] **Query extraction + debounce**, monotonic `seq` per editor.
- [ ] **Host round trip** (`{:editor_suggest, …}` → `action: :suggestions`),
      `global_id`-filtered, **stale replies dropped**.
- [ ] **Popup rendering**: list of results with label + optional sublabel +
      optional icon; loading state; empty state; "create" row when
      `allow_create` and no exact match.
- [ ] **Accept semantics**: replace trigger→caret token with `value <>
      insert_suffix`, caret lands after, content syncs, popup closes and
      does not immediately reopen.
- [ ] **Dismiss semantics**: Esc, caret moving out of the token, blur,
      click outside, typing a character outside the token charset.
- [ ] *Accept (whole P1):* in publishing's editor, typing `#eli` shows
      matching tags, ↓/Enter inserts `#elixir `, and the saved post's
      derived tags contain `elixir`.

### P2 — interaction quality

- [ ] **Keyboard**: ↑/↓ (wrapping), Enter **and** Tab accept, Esc dismiss.
      Critical: while the popup is open, Enter must **not** insert a
      newline, must not run the list auto-continue in `_handleEnter`, and
      must not submit the surrounding form.
- [ ] **Mouse**: hover highlights, click accepts, and the click must not
      steal focus from the textarea (the toolbar's `mousedown` +
      `preventDefault` trick already in the hook).
- [ ] **Caret anchoring**: popup follows the caret. The standard technique
      is a hidden mirror `<div>` copying the textarea's computed styles,
      text up to the caret, and a marker span to measure. Must survive
      wrapping, textarea scroll, window resize/zoom. *If that proves
      expensive, a v1 anchored to the textarea's bottom edge is acceptable
      to us* — the value is in the list + keyboard, not the pixel position.
- [ ] **Clipping**: portal the popup to `<body>` while open (the `RowMenu`
      hook already does this) so a scrollable editor panel or sticky admin
      header can't clip or cover it.
- [ ] **IME/composition**: never trigger or accept during
      `compositionstart`…`compositionend` (CJK input commits without the
      key events you'd expect).
- [ ] **Mobile**: touch-tap accepts; the popup flips above the caret when
      the virtual keyboard leaves no room below; no hover-only affordances.

### P3 — accessibility, polish, reach

- [ ] **ARIA combobox pattern**: `aria-expanded` / `aria-controls` /
      `aria-activedescendant` on the textarea, `role="listbox"` +
      `role="option"` on the popup, and a polite live-region announcement
      of the result count. *Accept:* usable start-to-finish with a screen
      reader and no mouse.
- [ ] **Client-side result cache** per `(trigger, query)` for the session;
      cancel in-flight requests superseded by newer keystrokes.
- [ ] **daisyUI theming** + dark mode; matches `SearchPicker`'s dropdown
      look so the ecosystem feels consistent.
- [ ] **Test affordances**: stable ids/data attributes for the popup and
      its rows, and a documented way to drive the flow from a LiveView
      test (what to `render_hook`) — we'd like to pin our `#` wiring.
- [ ] **Docs**: moduledoc section + a working trigger wired in
      `phoenix_kit_hello_world` (the house reference module), so consumers
      copy from something that runs.
- [ ] **Multiple triggers in one editor** (`#` and `/` together) — worth
      designing for now even if only one ships.

---

## 7. What publishing builds on our side (once the API lands)

Ours to do; listed so you know the host half is covered and cheap:

- [ ] `Hashtags.suggest(group_slug, prefix, opts)` — distinct tags across
      the group with usage counts. Cheap: our listing cache
      (`:persistent_term`) already carries `metadata.tags` per post, so
      this is an in-memory aggregation, no DB round trip.
- [ ] Ranking: exact prefix first, then substring; ties by usage count
      desc, then alphabetical. Cap 10.
- [ ] Include tags present in the **current unsaved buffer** so a tag the
      writer just coined in this post suggests consistently before save.
- [ ] Handle `{:editor_suggest, …}` in the publishing editor LV and reply.
- [ ] Tests: suggestion ranking, and an end-to-end "insert then save
      derives the tag" pin.
- [ ] Later, same API: `/` for PHK components, `@` for users.

---

## 8. Open questions for you

1. **Config shape** — declarative `suggestions` list on the component (as
   sketched), or a single trigger attr + a `suggest_source` callback?
2. **Event routing** — via the host LiveView (`send/2` + `send_update/2`,
   consistent with the rest of the editor), or let the hook `pushEventTo`
   a target the host names? The former is more consistent; the latter is
   fewer hops.
3. **Caret anchoring in v1** — mirror-div immediately, or ship anchored
   and follow up?
4. **Code/link exclusion** — client-side approximation now, or accept
   stray popups in code blocks for v1?
5. **Is `execCommand("insertText")` acceptable** as the undo-preserving
   insert, given its deprecated status? (It works today in all targets we
   checked; the `beforeinput` alternative is more code.)

---

## 9. Contacts / reference

- Publishing's hashtag rules: `lib/phoenix_kit_publishing/hashtags.ex`
  (`extract/1`, `linkify/2`, the masking regex) + the "Hashtags" section
  of `phk-publishing-format.md`.
- Publishing's editor call site:
  `lib/phoenix_kit_publishing/web/editor.ex` (search `MarkdownEditor`).
- Prior art: `search_picker.ex` (contract + multi-instance trap),
  `RowMenu` hook in `phoenix_kit.js` (body portal).
