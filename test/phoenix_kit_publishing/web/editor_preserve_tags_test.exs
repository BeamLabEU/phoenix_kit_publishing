defmodule PhoenixKit.Modules.Publishing.Web.EditorPreserveTagsTest do
  @moduledoc """
  The editor must hand Leaf the full list of PHK component tags.

  Pinned because the failure is silent and destructive. Leaf's visual mode is
  a WYSIWYG surface: markdown becomes HTML, the browser edits the HTML, and
  the HTML is converted back. A tag Leaf has not been told to preserve does
  not survive that return trip — so opening a post that contains `<Showcase>`
  or `<Audio>`, typing one character anywhere, and letting autosave run writes
  back a body with those components flattened into loose paragraphs. No error,
  no warning, and the original is overwritten.

  `preserve_tags` is Leaf's answer: each listed tag is swapped for an atomic,
  non-editable placeholder carrying the verbatim source, so it round-trips
  untouched. This test exists to make sure a tag added to the renderer later
  cannot quietly miss that list.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer

  @editor_source "lib/phoenix_kit_publishing/web/editor.ex"
  @renderer_source "lib/phoenix_kit_publishing/renderer.ex"

  test "the editor passes the renderer's tag list to Leaf" do
    source = File.read!(@editor_source)

    assert source =~ "preserve_tags={Renderer.component_tags()}",
           "the body editor must declare every PHK component as atomic, or the " <>
             "visual mode silently flattens them on the next autosave"
  end

  test "the body editor opens in markdown mode" do
    source = File.read!(@editor_source)

    # Leaf defaults to :hybrid, which is a visual surface. Posts here are
    # written with PHK components, and those are only editable as text — so
    # the mode is chosen explicitly and should stay chosen.
    assert source =~ "mode={:markdown}",
           "the body editor must open in markdown mode; Leaf's :hybrid default " <>
             "renders PHK components as uneditable blocks"
  end

  test "every tag the renderer dispatches on is declared" do
    declared = MapSet.new(Renderer.component_tags())

    # Read the tags straight out of the regexes the renderer matches with, so
    # this fails the moment someone teaches the renderer a new component and
    # forgets the editor.
    dispatched =
      @renderer_source
      |> File.read!()
      |> then(fn source ->
        Regex.scan(~r/~r\/\^?<\(?([A-Za-z|]+)\)?/, source)
        |> Enum.flat_map(fn [_, alternation] -> String.split(alternation, "|") end)
      end)
      # PHK components are PascalCase; the renderer's other regexes match plain
      # HTML (`<code`, `<p`), which Leaf handles natively.
      |> Enum.filter(&(&1 =~ ~r/^[A-Z]/))
      |> MapSet.new()

    missing = MapSet.difference(dispatched, declared)

    assert MapSet.size(missing) == 0,
           "renderer components missing from component_tags/0: #{inspect(MapSet.to_list(missing))}"
  end

  test "the components the demo content actually uses are all covered" do
    # A concrete guard against a clever-but-wrong regex above: these are the
    # tags real posts are written with today.
    for tag <- ~w(Image CTA Headline Subheadline Video Audio EntityForm Showcase Note) do
      assert tag in Renderer.component_tags()
    end
  end
end
