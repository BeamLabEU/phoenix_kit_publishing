# Machine API

The publishing module's part of core's machine API: 20 admin tools that let an AI agent, a script or an integration read and edit groups, posts, versions, translations and categories. Core serves the transport (REST at `/api/admin/v1/<tool>`, MCP at `/mcp/admin`), the keys and scopes, rate limits, JSON Schema validation and the confirmation flow; this module declares the tools (`PhoenixKit.Modules.Publishing.API.Tools`) and owns the data rules. Core's own guide covers keys, error documents and the flow in general; this one covers what is specific to publishing.

The tools exist only while Publishing is enabled and only on a core that carries the machine API. When the loaded core cannot enforce the confirmation flow, every tool that has a `danger` is withheld (a core without the flow ignores `danger`, so `update_post` on a live version would apply on the first call); only the reads and `create_version` remain.

## Overview

- **Audience:** admin only. There is no public tool: pages, RSS and the sitemap already serve readers.
- **Permission:** every tool needs the role permission `publishing` on the key's owner, checked on every request, plus the tool's scope on the key.
- **The rule:** anything that changes what a visitor sees needs a confirmation; everything else runs at once. The confirmation is core's mechanism (see [Confirmation](#fingerprints-and-the-confirmation-round-trip)).
- **Writes go through the module's context functions** (`Posts`, `Versions`, `Groups`, `Categories`, `TranslationManager`), so listing caches, PubSub broadcasts and activity entries behave exactly as for an admin click. The API never calls `DBStorage` writes, `ListingCache`, `PubSub` or the render cache itself (`list_posts` reads the per-day counts of its URL builder through the module's listing code, which may fill the listing cache on a miss). A write through a context function can run the same self-heal of the module's own post rows as an editor save does; a read never does.
- **Core adds three fields to every write tool:** `dry_run` (boolean), `confirm_token` (string) and `idempotency_key` (16 to 128 characters of `[A-Za-z0-9_-]`). A read tool has none of them. Over MCP the tool names use `_` for `.` (`publishing_update_post`).

## References

- **Post:** `{"id": uuid}` or `{"group": slug, "slug": slug}`; exactly one form, anything else is `invalid_ref` (a row error in a batch). A timestamp-mode post has no slug and is addressed by `id`; `list_posts` returns it. A `{group, slug}` ref never finds a trashed post, except in `trash_posts` and `restore_posts`, which resolve trashed posts too. An `id` ref to a trashed post is found, and a write is refused with `post_trashed`. `get_post` answers `not_found` with `context.trashed: true` for a trashed post; `list_posts` with `status: "trashed"` is how to see one.
- **Group:** the group slug (`"group": "blog"`). A group reference in a batch is `{"slug": slug}`. Group slugs and category slugs are never renamed through the API.
- **Category:** `{"id": uuid}` or `{"slug": slug}`, inside the request's `group`. In `upsert_categories` a row with both is accepted only when they name the same category.
- **Version:** an integer. Without one, READS use the active version, else the latest; WRITES use the highest-numbered `draft` version. A write with no draft and no `version` is `no_draft_version` (call `create_version` first, or name the version). Naming the live version or an archived one is legal, and it is what makes `update_post` and `set_translation` need a confirmation. `publish_post` and `schedule_post` fall back to the live version when there is no draft, so a plain retry after a lost answer is `unchanged`.
- **Language:** a code of an ENABLED language, full (`de-DE`) or a bare code that matches exactly one enabled code (`de`). Otherwise `validation_failed` with reason `language_not_enabled` and `allowed` listing the enabled codes. The default is the primary language. Reads also accept a language the post already HAS even if it was disabled since; writes need an enabled one.
- **Trashed containers:** a write into a trashed group is `group_trashed`, a write onto a trashed post is `post_trashed`. The exceptions are `restore_posts` and `restore_groups`.

## The tools

`kind`: `read`, `write`, or `batch` (a list of rows, rows are independent, one bad row never stops the others). `max` is the number of rows (`max_items`).

| Tool | Scope | Kind | Needs a confirmation | max |
|---|---|---|---|---|
| `publishing.list_groups` | `publishing.groups:read` | read | never | |
| `publishing.get_group_settings_schema` | `publishing.groups:read` | read | never | |
| `publishing.list_posts` | `publishing.posts:read` | read | never | |
| `publishing.get_post` | `publishing.posts:read` | read | never | |
| `publishing.list_categories` | `publishing.categories:read` | read | never | |
| `publishing.create_post` | `publishing.posts:write` | write | when `content` trips the text rule | |
| `publishing.update_post` | `publishing.posts:write` | write | text rule; or the post has a live version and the target version is the live or an archived one; or `slug` changes on a post with a live version | |
| `publishing.create_version` | `publishing.posts:write` | write | never | |
| `publishing.set_translation` | `publishing.posts:write` | write | text rule; or the live or an archived version is the target | |
| `publishing.translate_post` | `publishing.translations:ai` | write | always (costs money) | |
| `publishing.publish_post` | `publishing.posts:publish` | write | always | |
| `publishing.unpublish_post` | `publishing.posts:publish` | write | always | |
| `publishing.schedule_post` | `publishing.posts:publish` | write | always | |
| `publishing.trash_posts` | `publishing.posts:delete` | batch | always | 50 |
| `publishing.restore_posts` | `publishing.posts:delete` | batch | when a post to restore has a live version | 50 |
| `publishing.upsert_categories` | `publishing.categories:write` | batch | when a row changes an existing category; core also confirms a request of more than 50 rows | 100 |
| `publishing.delete_categories` | `publishing.categories:delete` | batch | always (permanent) | 100 |
| `publishing.upsert_groups` | `publishing.groups:write` | batch | when a row changes an existing group | 20 |
| `publishing.trash_groups` | `publishing.groups:delete` | batch | always | 20 |
| `publishing.restore_groups` | `publishing.groups:delete` | batch | always | 20 |

The restore tools use the trash scope (`posts:delete`, `groups:delete`), not `write`: restoring undoes a deliberate removal and can make content visible again, so a key that may only edit cannot reverse a trashing.

Input names that differ per tool: `trash_posts` and `restore_posts` take `posts` (post refs), `delete_categories` takes `group` and `refs`, `upsert_categories` takes `group` and `categories`, `upsert_groups` takes `groups`, `trash_groups` and `restore_groups` take `groups` (each `{slug}`). Every input object is closed: an unknown key, at any depth, is `validation_failed`. No write tool accepts `status`, `published_at`, `url_slug`, `tags` or `force`.

Annotations: `destructive` on `unpublish_post`, `trash_posts`, `delete_categories`, `trash_groups`; `idempotent` describes STATE (the same request leaves the same state), not the answer; `create_post`, `create_version` and `translate_post` are not idempotent (send an `idempotency_key` when retrying them). `translate_post` is `open_world` (it calls an AI provider) and costs 5 rate-limit units.

## Output shapes

**Post summary** (rows of `list_posts`, base of `get_post`):

```json
{"id": "...", "group": "blog", "slug": "my-post", "mode": "slug",
 "status": "published",
 "title": "...", "languages": ["en-US", "de-DE"],
 "active_version": 2, "latest_version": 3,
 "versions": [{"number": 1, "status": "archived", "published_at": "..."}],
 "date": "2026-10-18", "time": "09:30", "category_ids": ["..."],
 "public_paths": {"en-US": "https://example.com/blog/my-post",
                  "de-DE": "https://example.de/blog/my-post"}}
```

`status` is `trashed` if the post is in the trash; else `scheduled` if a version is live but dated ahead of now (timestamp groups); else `published` if a version is live; else `draft`. `public_paths` is present only for `published` posts and is built with the module's own URL builders, one absolute URL per language, never from the request's `Host`. A language served from its own domain (the host app's `:canonical_host_resolver`, read through core's `PhoenixKit.Utils.Routes.canonical_absolute/3`) gets that domain without the language segment, e.g. `https://example.de/blog/my-post` for `de-DE`; a sibling dialect such as `en-GB` loses its own `/en-gb` segment the same way. A language without a domain gets the site's configured origin and the prefixed path (`https://example.com/de/blog/my-post`), and so does every language when the resolver is not configured or the core predates that function. Core calls the resolver with the base code (`de` for `de-DE`), so two dialects of one language share a domain. A timestamp-mode post has `slug: null`.

**Post detail** (`get_post`) is the summary plus `version`, `language`, `markdown` (omitted with `include_content: false`), `fields`, `content_updated_at` and `revision`. `fields` holds `description`, `seo_title`, `excerpt`, `featured_image_id`, `featured`, `sitemap_exclude`, `og: {title, description, image_id}`, `tags` (derived, read-only), `category_ids` and `url_slug`. `title` is the title of the language shown. When the requested language has no text the module falls back to another one: the answer then carries the language actually returned and a `language_missing` warning, never the fallback text presented as the requested language. A read never writes: no read tool of this API runs the module's stale fixer (`list_groups` reads the group rows as stored, too), so a stale post (an active-version pointer to a version that is not published, a legacy language code) is shown as stored.

**Write summary.** A single-write answer is `{"action": ..., "post": <write summary>, "changed": [...]}` plus tool-specific keys. The write summary is the post summary WITHOUT `title`, `slug` and `public_paths`: core does not store an answer that holds a string starting with `pk_` or a key named `token` or `secret`, so free text must stay out of a write answer, or an idempotent retry of a post titled `pk_sale` would run the handler again. Read the slug of a created post with `get_post`.

| Tool | `action` | Extra keys |
|---|---|---|
| `create_post` | `created` | `changed`: `["title", "content"]` |
| `update_post` | `updated`, `unchanged` | `changed`: `[{"field", "scope"}]` |
| `create_version` | `created` | `version` (the new number) |
| `set_translation` | `created`, `updated`, `unchanged` | `language`, `version` |
| `translate_post` | `queued` | see [Async translation](#async-translation) |
| `publish_post` | `published`, `unchanged` | `version` |
| `unpublish_post` | `unpublished` | `version` |
| `schedule_post` | `scheduled`, `unchanged` | `version`, `publish_at`, `time_zone` |

**Batch answers** (`trash_posts`, `restore_posts`, `upsert_categories`, `delete_categories`, `upsert_groups`, `trash_groups`, `restore_groups`):

```json
{"results": [{"ref": {}, "action": "created|updated|unchanged|removed|restored|error",
              "id": "...", "error": {"code": "...", "message": "...", "context": {}}}],
 "summary": {"updated": 2, "unchanged": 1, "error": 1}}
```

Rows are independent and come back in request order. `trash_posts`, `trash_groups` and `delete_categories` report `removed`; the restore tools report `restored`. A row may carry `warnings` (see `unfile_incomplete`).

**Pagination.** `list_posts` answers `{"posts": [...], "count": N, "next_cursor": "..."|null}`. `limit` defaults to 20 and is trimmed to 100 with a `limit_trimmed` warning. The cursor is opaque; the next page starts after that post in the CURRENT order. A cursor whose post vanished from the filtered list, or a value this tool did not issue, is `validation_failed` / `cursor_stale`. `count` is the exact size of the filtered list. `status` is `all` (default, not trashed), `published` (live now), `scheduled`, `draft` or `trashed`; `category_id` limits the list to a category and its whole subtree.

## Previews, `raw_html` and `diff`

Every write answers `dry_run: true` with a preview and writes nothing: no content, version or post row, no activity entry, no cache regeneration, no broadcast. No read of this API runs the self-heal of the module's own reads, so a stale legacy post is read, and previewed, as stored.

A preview is `{"rows": [...], "summary": {...}, "requires_confirmation": true|false}` plus tool keys. `requires_confirmation` tells the agent to expect a confirmation round trip for the real call. Single-post tools have one row.

An `update_post` row:

```json
{"action": "update", "version": 2, "live": true, "public": "active",
 "changes": {
   "title": {"scope": "language", "from": "...", "to": "..."},
   "content": {"scope": "language", "from_bytes": 1200, "to_bytes": 1260,
               "from_sha256": "...", "to_sha256": "...",
               "head": "first 300 characters of the new body", "tail": "last 300 characters",
               "diff": {"mode": "line", "text": "@@ -3,5 +3,6 @@\n context\n-old\n+new", "hunks": 1, "truncated": false},
               "added_urls": ["example.org"], "added_urls_truncated": false,
               "raw_html": {"dangerous": false, "count": 0, "truncated": false, "findings": []}}}}
```

- `public` says how visitors can reach the version: `active` (it is live), `history` (a superseded version still readable at `/v/N` while the post is live) or `none`.
- **`diff`** is a unified line diff (`-` and `+` lines with two lines of context), bounded: a pure insertion or deletion is always an exact `"line"` diff; two changed middles of up to 400 lines each are diffed line by line; larger rewrites give one `"coarse"` hunk (the first and last 10 lines of each side with an `... N lines omitted` marker, plus `old_lines` and `new_lines`). `diff.text` is capped at 4,096 bytes (cut at a line, `truncated: true`) and every line at 300 characters. A cut or coarse diff can miss a harmful hunk, so every content row ALSO carries facts computed over the whole new body, not the diff: `added_urls` (hosts of http(s) links and images the old body does not contain; advice, not a gate) and `raw_html`.
- **`raw_html`** is the text-rule scan over the whole new body: `dangerous`, `count` (total), `truncated` (more than 20 findings) and the first 20 `findings` in text order, each `{kind, line, fragment}`. `kind` is `html`, `post_link`, `scheme`, `link_scheme`, `autolink_scheme` or `not_scanned`; `line` is the 1-based line of the match; `fragment` is the text from the match to the end of its line, at most 80 characters, control characters escaped as `\xNN`. The approver must read it: it is the only protection against a prompt-injected agent that asks to confirm a write.
- Short fields (`title`, `description`, ...) show `from` and `to` in full up to 500 characters.
- `set_translation` rows have the same shape per language (`action` is `add` for a new language row, `update` otherwise). A `create_post` row carries the same `content` object. `publish_post` and `schedule_post` previews carry `goes_live: {version, languages: [{code, title, head, body_bytes, public_path}]}` where `head` is the first 300 characters of each body, `archived: {version}` (the version the publish will archive) or `null`, and `contains_raw_html`: a list of `{language, kind, line, fragment}` (at most 20 per language, `[]` when clean) computed by the same scan over the STORED bodies, so content written in the editor or by an AI job is covered too, and `raw_html_totals`: `[{language, count, truncated}]` for each language with a finding, so the approver can tell that the list is cut. The publish preview also lists a `warnings` entry (`empty_translation`) for any language whose body is empty. `schedule_post` adds `from`, `publish_at`, `time_zone`, `public_url_changes_with_date` and `disappears_until`. `unpublish_post` lists `public_paths_stop`. `trash_posts` and `restore_posts` rows carry `changes.status {from, to}`, `title`, `languages` and `public_paths` (restore also `becomes_visible`). `delete_categories` rows carry `irreversible: true`, `children`, `published_posts`, `filed_versions` and `post_categories`. `trash_groups` and `restore_groups` rows carry `post_count` and `live_posts`. `translate_post` lists the targets, the skipped languages, the languages whose text will be overwritten, whether the version is `live` and its `public` state (the jobs overwrite a live version without a later preview), the endpoint and the prompt. An `unchanged` preview of `update_post` or `set_translation` asks for a confirmation exactly when the real call would (a stored body with HTML, or the live version), because the gate runs before the handler.
- **Previews show existing values to a writer.** A dry run needs no read scope, yet an `update_post` diff shows old body lines and the trash previews show titles, so a key with `posts:write` but without `posts:read` can read parts of a post. A key that must not read posts must not hold `posts:write` either.

## Fingerprints and the confirmation round trip

Each preview carries a fingerprint: a hash (64 hex characters) of the VALUES the operation depends on, never `updated_at`. It covers the post (uuid, slug, trash state, active version pointer, date and time, group status), every version touched (number, status, `published_at`, hash of its data) and every content row touched (language, `url_slug` and a hash of title and body); for category tools the touched categories and their published-post counts; for group tools the touched groups and their data; for `translate_post` the post state above (so the source text, the live pointer and every language's path), the target list, the existing-content flags and the endpoint and prompt ids. A text write also covers the hash of the NEW body, so a confirmation code cannot be redeemed for different text. If anything changed between preview and confirmation, core refuses the code with `409 confirm_token_invalid` and `context.reason: "changed"`.

A worked example, `update_post` on the live version of an about page (version 2 is live). First call:

```bash
curl -s -X POST https://example.com/api/admin/v1/publishing.update_post \
  -H "Authorization: Bearer pk_0123abcd_..." -H "Content-Type: application/json" \
  -d '{"post": {"group": "pages", "slug": "about"}, "version": 2, "title": "About us"}'
```

The version is live, so nothing is written and the answer is the preview and a code:

```json
{"executed": false, "status": "confirmation_required",
 "preview": {"rows": [{"action": "update", "version": 2, "live": true, "public": "active",
                       "changes": {"title": {"scope": "language", "from": "About", "to": "About us"}}}],
             "summary": {"update": 1}, "requires_confirmation": true},
 "confirm_token": "ct_...", "expires_at": "...", "expires_in_seconds": 120}
```

The agent shows the preview to its user and, once the user agrees, repeats the SAME call with the code:

```bash
curl -s -X POST https://example.com/api/admin/v1/publishing.update_post \
  -H "Authorization: Bearer pk_0123abcd_..." -H "Content-Type: application/json" \
  -d '{"post": {"group": "pages", "slug": "about"}, "version": 2, "title": "About us",
       "confirm_token": "ct_..."}'
```

```json
{"action": "updated",
 "post": {"id": "...", "group": "pages", "mode": "slug", "status": "published", "languages": ["en-US"],
          "active_version": 2, "latest_version": 2,
          "versions": [{"number": 1, "status": "archived", "published_at": "..."},
                       {"number": 2, "status": "published", "published_at": "..."}],
          "date": null, "time": null, "category_ids": []},
 "changed": [{"field": "title", "scope": "language"}]}
```

A code is bound to the key, the tool, the arguments and the fingerprint, lives `api_confirm_ttl_seconds` (120 by default) and is spent once. A key with `requires_approval` gets `status: "pending_approval"` and an `approval_id` instead; a person decides in `/admin/settings/api/approvals` and the agent polls `system.get_approval`. Core's own batch rule also applies: an admin write whose longest list holds more than `api_confirm_batch_over` (50) rows is confirmed; the batch caps keep post batches at 50, so only `upsert_categories` and `delete_categories` (up to 100 rows) can trip it.

The confirmation is only as strong as who gives it. With the code round trip the AGENT repeats the call; a prompt-injected agent can do that without asking. A key that must not be able to publish HTML or take pages down on its own needs `requires_approval`.

## `if_revision`

`update_post`, `set_translation`, `publish_post` and `schedule_post` take an optional `if_revision`: the `revision` string `get_post` returned. It is a hash of VALUES the writes depend on (post uuid, slug, trash state, active version, date and time, the shown version's number, status, `published_at` and data, and the shown language's title and body), never of `updated_at`, so an unrelated job touching a row does not change it. A mismatch is `409 revision_mismatch` with `context.current_revision`. It protects against an editor session or another agent changing the post since it was read; the module has no merge UX.

The revision covers the version and language `get_post` showed. Pass `if_revision` together with that same `version`: the write tools default to the highest DRAFT, which is not the version a plain read shows when one is live. `publish_post` and `schedule_post` compare the primary-language text, so read the primary language for them. For `set_translation` of a language without text yet, use the revision `get_post` showed for the text it fell back to.

## The text danger rule

A write of body text (`create_post.content`, `update_post.content`, `set_translation.content`) needs a confirmation, live or not, when the SUBMITTED string contains any of:

1. **`html`**: `<` followed by an ASCII letter, `/`, `!` or `?`. Raw tags, closing tags, components (`<CTA`, `<Image`, `<Note`, ...), HTML comments, `<!DOCTYPE`, angle-bracket autolinks. Code fences and inline code are NOT excluded. `1 < 2`, `a <= b` and `<3` do not match.
2. **`post_link`**: the token `[[post:` (any case). The page rewrites it at request time and the rewrite can complete markup around it.
3. **`scheme`**: `javascript:`, `vbscript:` or `data:` after removing whitespace and invisible characters and lower-casing, so `Java Script:` matches. There is no word boundary on the left: `metadata:` matches.
4. **`link_scheme`**: a markdown link or image destination (`](...)`, or a reference definition `]: ...`) that is not provably `http`, `https`, `mailto`, `tel` or relative (`//host/path` is another site, so it is not relative). A destination whose scheme zone holds `&`, a backslash or a control character is flagged too (an entity can spell a scheme).
5. **`autolink_scheme`**: text the renderer turns into a link without any markdown link syntax. The renderer enables the GFM autolink extension and decodes entities before it runs, so the scan reads the text with entities that stand for a printable ASCII character decoded (`&colon;`, `&#58;`, `&#x3a;`, ...) and flags a bare `scheme://` whose scheme is not `http` or `https` (`ftp://x`, `file:///x`, `intent://x`), `xmpp:` in any case, and `mailto:` directly preceded by a character of an email local part (`x-mailto:a@b.c`, which becomes a link with the scheme `x-mailto`). `https://example.com` and `a@b.c` in prose are not flagged.

Plain markdown runs at once. The scan reads the submitted string only; it renders nothing, parses no markdown and needs no database read. It fails closed: a `content` that is present but not a string counts as dangerous, and `null` (clear) does not. False positives are accepted: `a <b` in prose, a `<script>` shown in a code fence, the word `metadata:`, a plain `ftp://` address; a request whose `content` equals the stored body but contains HTML is still a confirmation. An `update_post` without `content` is not touched by the rule.

What the rule does NOT do:

- **It does not sanitise.** The module still renders raw HTML unsanitised by design (admin trust). A CONFIRMED write can put any HTML into a page, scripts included; the API makes inserting HTML an explicit step, not a safe one. The long-term fix is output sanitisation in the renderer.
- **`requires_approval` is the human gate.** The code round trip is performed by the agent; a person only decides on a key marked "Needs approval".
- **It does not look at hosts.** `[text](https://evil.example)` and a tracking image run at once; `added_urls` in the preview is the aid for the approver.
- **Editor and AI-job bodies bypass the rule.** Only the `contains_raw_html` report of the `publish_post` preview covers them.
- **Other fields are not scanned.** `title`, `description`, `seo_title`, `excerpt`, `og_*`, names and category or group descriptions are not rendered as markdown or HTML by any module page; a test pins an escaping marker per field.
- **Size.** A body field is capped at 262,144 bytes (`content_too_large`), and a text field must be valid UTF-8 without a NUL byte (`validation_failed`, no reason). Other text fields: `title` 500 characters; `description`, `seo_title`, `excerpt`, `og_title` and `og_description` 5,000 bytes.

## Field scope

`update_post` changes ONE version in ONE language, and each field has a scope that every `changes` entry of a preview and every name in `changed` carries:

- **version-level** (`"scope": "version"`): `description`, `seo_title`, `excerpt`, `featured_image_id`, `featured`, `sitemap_exclude`, `category_ids`. They change every language of the version: `language: "de"` with `description` also changes English.
- **language-level** (`"scope": "language"`): `title`, `content`, `og_title`, `og_description`, `og_image_id`. When any `og_*` is sent, all three are written, the unspecified ones kept.
- **post-level** (`"scope": "post"`): `slug`, slug-mode groups only (`slug_not_allowed` otherwise). A rename moves the live URL, so it needs a confirmation on a post with a live version even when the written version is a draft.

A string field accepts `null`, meaning "clear" (stored as an empty string; `title` cannot be cleared). An absent key means "keep". `featured_image_id` and `og_image_id` are ids of files of the media library (UUIDs) or `null`; an id that names no file, a trashed file or a system file is `unknown_file`. `category_ids` (up to 50) must be categories of the post's group (`unknown_category`). At least one field is required (`empty_update`). A request that changes nothing answers `unchanged` and writes nothing. `update_post` never publishes (`publish: false` always) and never sends `status`, `published_at` or `url_slug`. The language must already have text on the version; `set_translation` creates a language.

**Tags are derived.** Tags come from `#hashtags` in the body on save; there is no `tags` input.

## Async translation

`translate_post` queues one AI job per target language and answers when the jobs are INSERTED, not finished:

```json
{"action": "queued", "version": 3, "source_language": "en-US", "targets": ["de-DE", "fr-FR"],
 "skipped": [], "enqueued": 2, "conflicts": 0, "errors": [], "in_flight": ["de-DE", "fr-FR"]}
```

`enqueued` is the number of new jobs, `conflicts` the jobs already in flight (de-duplicated by post, version and language), `errors` the per-language failures to queue. The result is never "translated": poll `get_post`; a language appears in `languages` with its title once its job wrote the row. A failed job shows in the AI module's own UI and in the activity log of the key owner; the module has no retry layer.

Cost control: nothing about the AI call comes from the request. The source is the primary language; the endpoint is the `publishing_translation_endpoint_uuid` setting if set and enabled, else the AI module's unattended endpoint (never the last-used one, which may be an expensive model tried once); the prompt is the module's default prompt. Missing configuration is `ai_not_configured`. Languages that already have text are skipped unless `overwrite_existing: true`, because the job overwrites; nothing to do is `nothing_to_translate`; an empty primary body is `empty_translation`. `languages` (up to 50) defaults to every enabled language except the primary. `version` defaults to the highest draft.

## Limits and `max_items`

- Batch rows: 50 posts, 100 categories, 20 groups per request (`max_items`; a longer list is refused by core before the handler).
- Lists outside batch tools: `translate_post.languages` and `update_post.category_ids` up to 50.
- `list_posts.limit`: default 20, trimmed to 100.
- Body field 262,144 bytes; core's request limit is 2 MB.
- Rate limits: a write costs `max(1, ceil(rows / 50))` units; `translate_post` costs 5.
- The listing cache is regenerated on every post write, so a post batch costs the size of the group per row: that is why post batches stop at 50.

## Errors

Request-level errors are core's problem documents; this module uses these codes:

| code | HTTP | when |
|---|---|---|
| `not_found` | 404 | the group, post, category or version of a ref does not exist (`context.ref` echoes the post reference or group slug as given, clipped to 100 characters) |
| `validation_failed` | 422 | bad input or a refused state; `context.errors` is a list of `{path, message, reason, allowed?}` |
| `revision_mismatch` | 409 | `if_revision` no longer matches, or a version went live between the check and the write (`context.reason: "went_live"`: repeat the call to get a confirmation) |
| `internal_error` | 500 | `db_update_failed` and every module error without a mapping; the reason is logged, never returned |
| `confirm_token_invalid`, `forbidden`, `rate_limited`, ... | | core's, unchanged |

**The `reason` convention.** `context.errors[].reason` is this module's own field (core's validator and the catalogue use `path`, `message`, `limit`, `allowed`). It is a stable machine-readable string; `message` is for people. In a batch the row's `error.code` is the reason when there is one (`slug_taken`), else a core code (`not_found`, `internal_error`, `revision_mismatch`, `validation_failed`). No tool emits a reason outside these lists.

Reasons:

| reason | meaning |
|---|---|
| `invalid_ref` | a post, group or category ref is not one of the accepted forms, or names the same record twice in one batch |
| `empty_update` | `update_post` was given no field to change |
| `no_draft_version` | a write without `version` and no draft version exists |
| `version_not_found` | the named version does not exist |
| `language_not_enabled` | the language is not enabled (`allowed` lists the codes), or `translate_post` was asked to translate into the primary language |
| `group_trashed` | the write targets a group in the trash |
| `post_trashed` | the write targets a post in the trash |
| `slug_not_allowed` | a slug was sent for a timestamp-mode group |
| `slug_taken` | the slug is used by a post (live or trashed; `context.trashed: true` says which) or, for a group, by any group |
| `invalid_slug` | the slug is not a valid slug |
| `reserved_language_code` | the slug is a language code |
| `reserved_route_word` | the slug is a reserved route word |
| `invalid_name` | a group name is blank |
| `invalid_mode` | a group mode is not `timestamp` or `slug` |
| `invalid_type` | a group type is not valid |
| `title_required` | a blank title, or publishing a post whose primary title is empty or the default "Untitled" |
| `unknown_category` | a category id is not a category of the group |
| `unknown_file` | `featured_image_id` or `og_image_id` names no usable file of the media library |
| `content_too_large` | a body field over 262,144 bytes |
| `not_published` | nothing is live (`unpublish_post`) |
| `not_timestamp_group` | `schedule_post` on a slug-mode group |
| `slot_taken` | the date and minute is held by another post (trashed ones count), or no free minute is left |
| `schedule_in_past` | `publish_at` is not later than now on the site clock |
| `mode_locked` | `mode` of an existing group differs from the stored one |
| `immutable_field` | `type`, `item_singular` or `item_plural` of an existing group differs from the stored one |
| `invalid_setting` | a group setting value is outside its allowed values |
| `parent_not_found` | a category parent does not exist |
| `parent_wrong_group` | a category parent belongs to another group |
| `category_cycle` | a category would become its own ancestor |
| `ai_not_configured` | no usable AI endpoint or prompt is configured |
| `nothing_to_translate` | every target language already has text |
| `cursor_stale` | the `list_posts` cursor no longer matches the list |
| `empty_translation` | a blank `set_translation` title or body, or an empty primary body in `translate_post` |
| `language_missing` | `update_post` was asked to edit a language the version has no row for |

Warnings (`warnings: [{code, message}]` in an answer): `language_missing` (`get_post` fell back to another language), `limit_trimmed` (`list_posts` trimmed the limit), `empty_translation` (a `publish_post` preview: a language whose body is empty) and `unfile_incomplete` (on a `delete_categories` row: the category is gone but some versions still name it; `count` says how many).

Writes that fail half-way say what stays: `set_translation` creates the language row first, and when the body write then fails an empty "Untitled" row stays (the API deletes nothing) and the error carries `context.left_behind`; the next `publish_post` preview warns about the empty language. `schedule_post` moves the post's date and time first and publishes second; if the publish fails the date is put back, and if that fails too the error carries `context.left_behind: ["date", "time"]`.

## The one permanent delete

`delete_categories` is the only permanent delete the API offers, and it has its own scope (`publishing.categories:delete`) and always needs a confirmation. Categories have no trash. It deletes the category row, its rows in `post_categories`, and the category's uuid from every version of the group; child categories move to the top level (descendants are NOT deleted). Posts, their versions and their content stay. The preview states `irreversible: true` and the counts. Groups, posts, versions and languages are never hard-deleted: trashing is the removal the API offers, and `restore_posts` and `restore_groups` bring things back. There is also no stale-fixer tool and no media reorganizer.

## Activity log

Every API write is logged by the context functions with the key owner as actor, activity mode `auto` and metadata `via: "api"`, `key_prefix`, `request_id`, `tool` (plus `approved_by_uuid` for an approved operation and, for `update_post` and `set_translation`, `fields`: the NAMES of the changed fields, never values). `translate_post` additionally writes `publishing.translation.requested`, because the per-language jobs run in another process and log as the key owner without API attribution. Core adds its own `api.request` entry beside the module's. The module's own automatic entries made during a write (`publishing.content.metadata_promoted`, `publishing.content.promoted`) carry no `via` and no actor. See [activity-logging.md](activity-logging.md).

A write that `update_post` or `set_translation` refuses under the post lock (a trash or a version going live between the check and the write) leaves one `publishing.post.updated` row with `db_pending: true`, like any failed mutation.

## Known residuals

- **`set_translation` step 1.** A new language is created as a blank row before the body is written. If the version goes live in the milliseconds between the recheck and the body write, an empty row exists on a live version and the body write is refused (`revision_mismatch` / `went_live`, with `context.left_behind`).
- **`if_revision` window.** The revision is compared before the post row lock (it covers content rows the lock hook does not read), so a change in the milliseconds between the comparison and the write is not caught. The lock hook closes the race that matters for visitors (a version going live, a post being trashed).
- **A confirmed call skips the live recheck.** A draft write that needed its confirmation only because of its text (the version was a draft when the code was issued) is checked against the fingerprint, which covers the version status, but a version that goes live in the milliseconds between the fingerprint check and the post lock is written to a live page. The window is as small as the others listed here.
- **`publish_post` and `schedule_post` publish what is stored when the handler runs**, not the state the fingerprint hashed a moment earlier; an editor save in that window is published. `if_revision` has the same gap.
- **Concurrent editors.** An editor autosave can overwrite an API write and vice versa; `if_revision` mitigates it.
- **Create versus update races.** A category or group classified as a create can become an update when another actor creates the slug in between; the write re-classifies each row and, if it became a change that needs a confirmation, reports a row error `revision_mismatch` ("changed since the check; repeat the call").
