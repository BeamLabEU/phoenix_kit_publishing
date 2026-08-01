# Dialyzer warnings to ignore (matched by dialyxir).
[
  # `PhoenixKitOG` is an optional plugin, not a dependency of this repo.
  # Every call site is guarded by `Code.ensure_loaded?/1` +
  # `function_exported?/3` at runtime and the compiler is told not to warn
  # via `@compile {:no_warn_undefined, PhoenixKitOG}`, but Dialyzer doesn't
  # understand that directive — it still resolves the remote call against
  # the PLT and reports it as calling a nonexistent function.
  {"lib/phoenix_kit_publishing/web/editor.ex", :unknown_function},

  # `PhoenixKitComments` is the same shape of optional plugin (see
  # `Publishing.Comments`): no dependency here except `only: :test`, every
  # call `Code.ensure_loaded?` + `function_exported?` guarded and rescued,
  # and `@compile {:no_warn_undefined, …}` for the compiler. Dialyzer needs
  # telling separately, exactly as it does for PhoenixKitOG above.
  {"lib/phoenix_kit_publishing/comments.ex", :unknown_function},

  # Gettext.Backend expands into code that constructs %Expo.PluralForms{}
  # literals inline; that struct is @opaque in Expo, so dialyzer flags the
  # generated call to Gettext.Plural.plural/2 as a call_without_opaque
  # mismatch. Known upstream false positive (gettext >= 0.26) — the plural
  # forms work correctly. Mirrors the same ignore in phoenix_kit_ecommerce /
  # phoenix_kit_staff / phoenix_kit_billing / phoenix_kit_catalogue /
  # phoenix_kit_projects.
  {"lib/phoenix_kit_publishing/gettext.ex", :call_without_opaque}
]
