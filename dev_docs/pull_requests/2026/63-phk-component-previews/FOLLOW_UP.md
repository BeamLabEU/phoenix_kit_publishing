# PR #63: follow-up

- **Open: a CTA's preview shows no destination (finding 5).** Needs a Leaf release:
  add `attr_value(attrs, "action")` to the `link` lookup in `kind_preview(:button, …)`
  in `Leaf.PreservedTags`. Nothing changes here once it lands.
- **Open: Leaf's strings are mostly untranslated in this module (finding 11).** Add a
  `leaf` domain to `priv/gettext` when someone takes on the translations.
- **`mix precommit` does not run `mix test`.** That is how the red pin test (finding 1)
  got through. Run the suite as well before merging.
