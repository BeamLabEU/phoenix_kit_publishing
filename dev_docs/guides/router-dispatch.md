# Public dispatch — `RouterDispatch`

How publishing's public catch-all coexists with a host app's own routes, and
what the public 404 policy is.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Conventions.

## Why a dispatch strategy exists at all

`PhoenixKitPublishing.RouterDispatch` is the host-side routing strategy that lets
publishing's catch-all coexist with host routes shaped `/:locale/<literal>/...`
declared after `phoenix_kit_routes()` in the parent's router. Without this,
publishing's `/:language/:group/*path` matches every two-or-more-segment URL
(Phoenix matches by declaration order with no fall-through), silently shadowing
host routes — most painfully under `url_prefix: "/"`. See the
`lib/phoenix_kit_publishing/router_dispatch.ex` moduledoc for the full mechanism.

Public routes are therefore NOT registered through `PhoenixKitPublishing.Routes.public_routes/1`;
that function returns an empty AST. It is kept as a no-op for backwards
compatibility with core's route compiler in `PhoenixKitWeb.Integration` (the
`compile_external_public_routes` hook), which walks every route module looking
for the function. Removing the callback entirely would require a coordinated
bump of the `function_exported?/3` guard in core.

## Three pieces

1. **Internal-prefix scope with root/localized discriminators.** Publishing's
   catch-all is registered under `/__phoenix_kit_publishing_dispatch/...` with
   **two sub-scopes** — `/localized` (binds `:language` + `:group`) and `/root`
   (binds `:group` only). The discriminator is load-bearing: without it, both
   `/:language/:group` and `/:group/*path` match a 2-segment internal path and
   Phoenix's first-match-wins picks the localized form even when the URL had no
   locale prefix, sending the controller `language=<group-slug>,
   group=<post-slug>` and 404'ing because the post slug isn't a group. With the
   discriminator, the override picks the right shape based on which segment
   matched a known group, and Phoenix unambiguously dispatches the right route.
   Core's `phoenix_kit_routes/0` macro emits the parent scope with the standard
   `:browser` + `:phoenix_kit_*` pipelines plus an extra
   `:phoenix_kit_publishing_internal` pipeline that runs
   `RouterDispatch.restore_path/2`.

2. **`call/2` override on the host router.** Phoenix.Router's `match_dispatch/0`
   emits `def call/2` with `defoverridable init: 1, call: 2` (a documented
   extension point). The macro emits an override that calls
   `RouterDispatch.maybe_rewrite/1`:
   - cache hit on a known group slug → rewrites `path_info` + `request_path` to
     prepend the internal prefix, stashes originals in `conn.private`, then
     `super(conn, opts)` runs Phoenix's matcher against the internal-prefix route
     and dispatches via the standard pipeline.
   - cache miss → conn passes through unchanged; `super` matches host routes
     normally.

3. **Path restore.** `restore_path/2` (run as part of the internal scope's
   pipeline, after route bindings are extracted into `conn.params`) un-mutates
   `request_path` and `path_info` so controllers reading them for canonical-URL
   generation see the URL the client sent. **Without this**, publishing's
   `default_language_no_prefix` redirect computes a Location header with the
   internal prefix, the browser follows, the override re-rewrites — infinite
   loop. The redirect-loop trap is the single failure mode worth pinning a test
   for.

The override is emitted unconditionally inside `phoenix_kit_routes/0`
(compile-time gated on `Code.ensure_loaded?(PhoenixKitPublishing.RouterDispatch)`),
so installs that don't have publishing in the dep tree get a no-op.

## `mix phx.routes` blind spot

The publishing routes appear under the `__phoenix_kit_publishing_dispatch`
prefix. Devs grepping for `:group` or `/blog` won't find a top-level route; they
need to know to look for the internal prefix. Documented here so the mismatch
with the user-facing URLs is intentional, not surprising.

## Host with their own `def call/2` override

Phoenix.Router's `defoverridable init: 1, call: 2` consumes one override token.
The macro emits ours via `def call(conn, opts) do ... super(conn, opts) end` and
does NOT re-arm `defoverridable [call: 2]` afterwards. If a host app's router has
their own `def call/2` (e.g. a hand-rolled instrumentation hook before
`use PhoenixKitWeb, :router`), there are two cases:

* Host's override comes BEFORE `phoenix_kit_routes()` — host consumes the token;
  our subsequent `def call/2` would emit a "redefining" warning AND not call
  host's via super (we'd call Phoenix's instead). Host's instrumentation is
  bypassed silently.
* Host's override comes AFTER `phoenix_kit_routes()` — same warning shape but
  with the directions reversed; host's def replaces ours and bypasses publishing
  dispatch.

Recommendation for hosts: put instrumentation in a pipeline plug or in the
endpoint's plug stack, not in `def call/2`. A pipeline plug runs through
Phoenix's normal flow and composes cleanly with the override. If you absolutely
must override `call/2`, do it inside the endpoint module rather than the router
(endpoints have their own override surface that doesn't conflict with
router-level overrides).

## No per-segment constraints

Phoenix.Router has **no per-segment regex constraint mechanism** —
`constraints: %{...}` on a route is silently ignored. Don't add one expecting it
to filter. Locale-vs-group disambiguation is done in the controller by
`Web.Controller.Language.detect_language_or_group/2`, which rewrites
`conn.params` so the smart fallback below reads the corrected interpretation.

## Smart fallback semantics

The public Controller delegates 404 handling to `Web.Controller.Fallback`. The
policy is two-layer:

| Situation | Behavior |
|-----------|----------|
| Requested **group exists**, post/version/translation/time missing | redirect to nearest valid parent (other language → other time on date → group listing) with the `"Showing closest match"` flash |
| Requested **group does not exist** | render 404. Never redirect to "the first group in the DB" |

This split is **load-bearing when `url_prefix` is `"/"`** — publishing's
`/:group/*path` catch-all then sits at the host's absolute root and sees every
URL the host's own routes don't claim earlier. Falling back to the first group in
that mode would hijack random host-app paths (`/about`, `/contact`, ...) and
silently redirect them to an unrelated publishing page.

Tests pin the exact contract in
`test/phoenix_kit_publishing/web/controller/public_routes_test.exs` — "smart
fallback contract" describe block. Don't loosen those to
`assert conn.status in [...]` matches; the bug they prevent only shows up when
the assertion is exact.

## Admin routes are not part of this

Admin LiveView routes are auto-discovered by PhoenixKit and compiled into
`live_session :phoenix_kit_admin`. Never hand-register them in a parent app's
`router.ex`. A hand-written route sits outside that session, which (a) loses the
admin layout — `:phoenix_kit_ensure_admin` only applies it inside the session —
and (b) crashes the socket on navigation between admin pages (`navigate event
failed because you are redirecting across live_sessions`). Core's
`guides/custom-admin-pages.md` is the authoritative reference.

Publishing uses the **route module** pattern via `PhoenixKitPublishing.Routes`.
Both `admin_locale_routes/0` and `admin_routes/0` declare every admin LiveView
path (the localized variant gets a `:locale` segment + `_localized` `:as`
aliases). Tabs in `admin_tabs/0` carry only the parent-level Publishing entry;
per-page routes come from the route module so we can express the full
Listing/Editor/Preview/PostShow tree (including dynamic `:group` / `:post_uuid`
segments) without enumerating each as a `Tab` struct.

An all-groups public overview does not exist. If one comes back it comes back as
an opt-in reserved route, not as a catch-all sibling.
