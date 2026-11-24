# PR #66 — Hand the admin Edit target to the host layout; in-page button behind a setting

**Author:** timujinne · **State:** merged 2026-11-24 (`d3eb51b`) · **Reviewed:** 2026-11-24

Public publishing pages (group listing, category archive, post, versioned post, date-only
post) already computed an admin Edit target; the PR hands it to the host layout through
`app_layout`'s `admin_edit_url`/`admin_edit_label` attrs, tightens the gate to the
`publishing` module permission, and moves the in-page button behind
`publishing_show_admin_edit_button` (default off).

**Verdict:** merged. No code findings.

## Checked, fine

- **Permission gate tightened correctly.** `maybe_assign_admin_edit/3` now calls
  `AdminEditHelper.assign_admin_edit(conn, path, label: label, permission: "publishing")`.
  The keyword form with `:permission` exists in every core the module's floor admits
  (verified against the `v3.5.0` tag of core: the `:permission` option is documented there),
  and the module feature-detects the helper itself for older cores. `Scope.has_module_access?/2`
  now also requires the `publishing` key, so an admin scoped to another module gets no Edit
  target anywhere — pinned on all four page types plus the date-only branch
  (`admin_edit_account_menu_test.exs`, with the in-page button switched on so a leak would
  show in both places).
- **The hand-off uses the attrs, not `module_assigns`** (a `module_assigns` value would skip
  core's gate, per `app_layout`'s own doc). Both public templates pass
  `admin_edit_url={assigns[:admin_edit_url]}` / `admin_edit_label={...}` next to
  `module_assigns`, so the target crosses into the host layout; the test host layout surfaces
  it as `data-testid="host-admin-edit"`, mirroring a host account menu.
- **The in-page button switch.** `admin_edit_button?/1` = target present AND
  `Settings.get_boolean_setting("publishing_show_admin_edit_button", false)`; both templates
  gate the button and the post toolbar row on it, so with the setting off no empty toolbar
  row renders (pinned). With it on, the markup is byte-for-byte the historical
  `btn btn-sm btn-outline` link in the same row (pinned by selector). The settings toggle is
  the same raw `toggle toggle-primary` checkbox its five neighbours use (umbrella rule: raw
  toggle-styled inputs stay raw), and the event flips the boolean setting with a flash.
- **gettext:** the four new msgids are in `default.pot` and all ten locales.
- **Tag archives stay without a target**, as before (documented in
  `admin_edit_links_test.exs`, whose scope now carries `cached_permissions: ["publishing"]`
  to match the tightened gate).

## Noted, not fixed here (pre-existing, reported by the PR author)

`GroupSlugsTest "without the counter every lookup asks the database"` is order-dependent on
`main` too (`DesignDecisionsTest` leaves the group-slug counter in `:persistent_term`); fails
on `main` with `--seed 9`. Out of this PR's scope.

## Validation

- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`,
  dialyzer via `mix precommit` — clean (run against the post-sweep core release).
- `mix test` — full suite passes, including the new `admin_edit_account_menu_test.exs` and
  the `settings_live_test.exs` toggle test.
