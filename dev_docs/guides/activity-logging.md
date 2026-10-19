# Activity logging

How publishing mutations reach `phoenix_kit_activities`, the call patterns for
new sites, and the auto-logged self-healing events.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Conventions → Activity logging.

## The wrapper

Mutations route through `PhoenixKit.Modules.Publishing.ActivityLog` — a thin
wrapper around core's `PhoenixKit.Activity.log/1` that injects
`module: "publishing"`. Core never raises: a missing `phoenix_kit_activities`
table, a sandbox-ownership error or a dead pool is logged there and returned as
`{:error, _}`, and the wrapper returns `:ok` regardless. Audit failures must
never crash the primary mutation.

The wrapper exposes three call shapes:

```elixir
# Standard "user-driven mutation" — used by every CRUD context fn. The sixth
# argument, `opts`, is optional (see "Options of log_manual/6" below).
ActivityLog.log_manual(action, actor_uuid, resource_type, resource_uuid, metadata, opts)

# Extracts `:actor_uuid` from opts (keyword or map). Returns nil when the
# key isn't present — context fns thread this through every mutation.
ActivityLog.actor_uuid(opts)

# Raw map shape (used by the self-healing auto-events).
ActivityLog.log(%{action: …, mode: "auto", resource_type: …, resource_uuid: …, metadata: …})
```

## Pattern for new call sites

```elixir
def my_mutation(arg, opts \\ []) do
  case do_mutation(arg) do
    {:ok, record} = result ->
      ActivityLog.log_manual(
        "publishing.<resource>.<verb>",
        ActivityLog.actor_uuid(opts),
        "publishing_<resource>",
        record.uuid,
        %{... PII-safe keys only ...}
      )

      result

    other ->
      other
  end
end
```

LiveView callers thread the actor UUID via `Shared.actor_uuid_from_socket/1`:

```elixir
def handle_event("trash_post", %{"uuid" => post_uuid}, socket) do
  case Publishing.trash_post(group_slug, post_uuid,
         actor_uuid: Shared.actor_uuid_from_socket(socket)
       ) do
    ...
  end
end
```

Reading the actor in one place keeps assign-reading from being copy-pasted
into every event handler. `Shared.actor_uuid_from_socket/1` is core's
`PhoenixKitWeb.Actor.uuid/1` (the scope first, then the bare current user);
for an options list use `PhoenixKitWeb.Actor.opts/1` directly:

```elixir
# in handle_event/3:
Posts.trash_post(group_slug, post_uuid, PhoenixKitWeb.Actor.opts(socket))
```

Mutating context fns accept `opts \\ []` and pull `actor_uuid` out via
`ActivityLog.actor_uuid/1`. `update_post/4` additionally falls back to the
audit-metadata path's `:updated_by_uuid` when no explicit `actor_uuid` opt is
present, so legacy LV callers that only thread `:scope` continue to attribute
correctly.

Module enable/disable runs without an actor (`actor_uuid: nil`) since it can be
triggered from IEx as well as the UI; if you need attribution add it from the
admin LV before calling `enable_system/0`.

## Options of `log_manual/6` and `log_failed_mutation/6`

Both take the call's `opts` (keyword list or map, the same value the context
function received) as an optional sixth argument; the 4- and 5-argument forms
keep working and `log/1` is untouched. Two keys are read:

| key | meaning |
|---|---|
| `:activity_mode` | The entry's `mode`. A binary; default `"manual"`. A missing, blank or non-binary value falls back to `"manual"`. |
| `:log_metadata` | A map merged UNDER the entry's own metadata: the entry's keys win on a clash. Only string keys are taken; atom keys and a non-map value are ignored. |

A failed-mutation row keeps `db_pending: true` and takes the same mode and
metadata. The key is `:activity_mode`, deliberately not `:mode`: the same `opts`
reach `Groups.add_group/2`, where `:mode` is the group's URL mode, and an
`"auto"` there would build the group in the default mode, which is locked at
creation. Context functions pass their own `opts` through at every mutation site
an API tool can reach (posts, versions, groups, categories, `add_language_to_post`),
so a caller can attribute a whole call without the contexts knowing who it is.

```elixir
Posts.trash_post(group_slug, post_uuid,
  actor_uuid: user_uuid,
  activity_mode: "auto",
  log_metadata: %{"via" => "api", "tool" => "publishing.trash_posts"}
)
```

The machine API (`dev_docs/guides/machine-api.md`) builds these options once per
request in `API.Common.write_opts/3`: `actor_uuid` is the key owner,
`activity_mode` is `"auto"`, and `log_metadata` holds `via: "api"`, `key_prefix`,
`request_id` and `tool` (plus `approved_by_uuid` for an approved operation, and
`fields`, the NAMES of the changed fields, for `update_post` and
`set_translation`). Never put values or free text in it.

## Rows the API layer adds

| action | when | resource_type |
|--------|------|---------------|
| `publishing.translation.requested` | `publishing.translate_post` queued its jobs. Mode `auto`, API metadata plus `group_slug`, `version`, `targets`, `enqueued` and `conflicts`. The per-language Oban jobs run in another process, so the writes they make appear as `publishing.post.updated` with the key owner as actor, mode `manual` and no API attribution. | `publishing_post` |

Every other API write is logged by the ordinary context function, with the
attribution above. A write that `update_post` or `set_translation` refuses under
the post row lock (the post was trashed, or the version went live, between the
check and the write) leaves one `publishing.post.updated` row with
`db_pending: true`, like any failed mutation. Core adds its own `api.request`
entry for every write call beside the module's rows.

## Auto-logged self-healing events

| action | when | resource_type |
|--------|------|---------------|
| `publishing.content.language_normalized` | Legacy base-code content (e.g. `"en"`) rewritten to the enabled dialect (`"en-US"`) by `StaleFixer` | `publishing_content` |
| `publishing.content.merged` | Legacy and dialect rows for the same version merged by `StaleFixer`. Metadata includes `discarded_body` — true when a divergent non-blank legacy body lost to the target's; its text is stashed in the merged row's `data["_stale_fixer"]["discarded"]` (whitelisted in Posts' content-data preservation, so edits keep it) | `publishing_content` |
| `publishing.content.promoted` | Legacy base-code row promoted in place when the admin adds the corresponding dialect translation | `publishing_content` |
| `publishing.content.metadata_promoted` | Legacy V1 content.data keys (`description`, `featured_image_uuid`, `seo_title`, `excerpt`) promoted to `version.data` on first edit so the V2 whitelist (`previous_url_slugs`, `updated_by_uuid`, `custom_css`, `og`, `_stale_fixer`) can wipe content.data without losing the value. Metadata: `language`, `version_uuid`, `promoted_keys`. Self-healing — runs at most once per legacy row | `publishing_content` |
| `publishing.post.auto_trashed` | An empty post (no content in any version) past the grace period, trashed by `StaleFixer` | `publishing_post` |

All five run with `mode: "auto"` and no `actor_uuid` — they're system-triggered,
not user-initiated. Metadata includes `from_language` / `to_language` /
`version_uuid`.

`StaleFixer` runs on the public READ path, so it tracks whether any fixer
actually wrote (a process-local dirty flag set by `mark_listing_dirty/0`) and
invalidates the group's listing cache exactly once, only when something changed —
invalidating unconditionally would nuke the cache on every post read.

## The failure side

Every user-driven mutation also leaves a `db_pending` row via
`ActivityLog.log_failed_mutation/5` when it fails, so a vanished admin action is
still auditable. Categories and translations funnel their error branches through
single chokepoints (`log_category_failure/5`, `log_translation_failure/6`) rather
than logging at each site. Reasons go through `ActivityLog.reason_string/1`,
which collapses an `%Ecto.Changeset{}` to `"changeset_error"` — changesets carry
the submitted params (names, free text) and must never reach metadata.

> **Known drift:** `reorder_categories/3` logs success against
> `"publishing_group"` (the reorder is a group-scoped operation) but its failure
> rows go through the shared `log_category_failure/5` chokepoint, which hardcodes
> `"publishing_category"`. Filtering an activity feed by `resource_type`
> therefore splits reorder successes from failures. Harmless today; fix by
> passing the resource type into the chokepoint.

`cleared` vs `deleted` on translations distinguishes the two entry points
(`clear_translation/5` vs `delete_language/5`) in the feed — both hard-delete the
row.
