defmodule PhoenixKit.Modules.Publishing.RendererGalleryTest do
  @moduledoc """
  `<Gallery>` — images on a slowly turning double helix.

  The interesting property is that it needs no JavaScript. The published
  versions of this effect run a requestAnimationFrame loop writing transforms
  onto every card each frame; public post pages here are dead views, so that
  would render as a pile of cards stacked at the centre. Everything below
  pins the arrangement that makes CSS sufficient — one shared animation plus
  a per-card delay — because it is the kind of thing a later "simplification"
  would quietly undo.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer

  defp render(body), do: Renderer.render_markdown(body, cache: false)

  defp gallery(inner, attrs \\ ~s(height="520" radius="420" speed="60")) do
    render("""
    Before.

    <Gallery #{attrs}>
    #{inner}
    </Gallery>

    After.
    """)
  end

  defp four_images do
    Enum.map_join(1..4, "\n", fn i ->
      "![Picture #{i}](https://example.test/#{i}.jpg)"
    end)
  end

  defp cards(html) do
    Regex.scan(~r/<div class="pk-helix__card" style="([^"]*)"/, html)
    |> Enum.map(fn [_, style] -> style end)
  end

  test "each image becomes one card" do
    html = gallery(four_images())

    assert length(cards(html)) == 4
    assert html =~ "https://example.test/1.jpg"
    assert html =~ ~s(alt="Picture 4")
  end

  test "the surrounding prose is untouched" do
    html = gallery(four_images())

    assert html =~ "Before."
    assert html =~ "After."
  end

  test "cards are spread along the strand by delay, not stacked" do
    delays =
      gallery(four_images())
      |> cards()
      |> Enum.map(fn style ->
        [_, move] = Regex.run(~r/--pk-hx-d1:(-?[\d.]+)s/, style)
        move
      end)

    # All identical would mean every card sits at the same point of the loop —
    # the pile this design exists to avoid.
    assert length(Enum.uniq(delays)) > 1
  end

  test "the two strands sit half a turn apart" do
    phases =
      gallery(four_images())
      |> cards()
      |> Enum.map(fn style ->
        [_, phase] = Regex.run(~r/--pk-hx-phase:([\d.]+)turn/, style)
        phase
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert phases == ["0.0", "0.5"]
  end

  test "every card carries a resting pose, as a variable not a transform" do
    # Shows through only where animations don't run; without it that case is a
    # heap of cards at dead centre.
    #
    # It has to be a custom property. As a plain inline `transform` it would
    # ALSO apply on devices that fall back to the grid — inline styles beat
    # stylesheet rules — flinging those cards off-screen. The @supports block
    # is what promotes it to a real transform.
    for style <- cards(gallery(four_images())) do
      assert style =~ "--pk-hx-rest:translate(-50%,-50%) rotateY("
      assert style =~ "translateZ(420px)"
      refute style =~ ~r/(^|;)transform:/
    end
  end

  test "the helix is an enhancement over a plain grid, not the floor" do
    html = gallery(four_images())

    # Anything that can't do this drops to a real image grid rather than to a
    # pile of absolutely-positioned cards at the centre.
    assert html =~ "@supports (transform-style: preserve-3d) and (--probe: 0)"
    assert html =~ "grid-template-columns:repeat(auto-fill,minmax(180px,1fr))"

    # Custom properties are in the gate on purpose: the whole layout is
    # expressed in var()s, so preserve-3d alone is not enough.
    assert html =~ "(--probe: 0)"
  end

  test "the helix gets the page's width, not the text column's" do
    html = gallery(four_images())

    # The cylinder is wider than a text column, so confined to one it is
    # sliced by two hard vertical edges — a box cutting through the middle of
    # a rotation. Full-bleed by default, same lane system as <Showcase>.
    assert html =~ ~s(class="pk-stretch")
  end

  test "align and stretch are honoured when given" do
    narrow = gallery(four_images(), ~s(height="400" align="none"))
    refute narrow =~ ~s(class="pk-stretch")
  end

  test "all four edges fade, not just top and bottom" do
    html = gallery(four_images())

    # Top/bottom hide the wrap point. Left/right hide the fact that the
    # rotation continues past the frame.
    assert html =~ "linear-gradient(to bottom,"
    assert html =~ "linear-gradient(to right,"
  end

  test "the backdrop and the depth cue both follow the theme" do
    html = gallery(four_images())

    # A hardcoded near-black panel is a foreign object on a light theme —
    # the same mistake the Showcase band's default tone once made.
    assert html =~ "var(--pk-hx-bg,var(--color-base-100,#fff))"
    refute html =~ "#0d0d0c"

    # Darkening only recedes over a dark backdrop; on a light theme it makes
    # the far cards jump forward instead.
    refute html =~ "brightness("
  end

  test "cards stay opaque; distance is a scrim over them" do
    html = gallery(four_images())

    # A photograph you can see through reads as a rendering fault rather than
    # as distance — and fading the card's own opacity let cards show through
    # one another. The scrim keeps each card a solid object.
    assert html =~ ".pk-helix__card::after"
    assert html =~ "@keyframes pk-hx-scrim"

    scrim = html |> String.split("@keyframes pk-hx-scrim") |> Enum.at(1) |> String.slice(0, 300)
    assert scrim =~ "0%{opacity:0}"

    # Nothing may animate the CARD's opacity.
    move = html |> String.split("@keyframes pk-hx-move") |> Enum.at(1) |> String.slice(0, 400)
    refute move =~ "opacity"
  end

  test "the scrim can reach the card's own delay" do
    # A pseudo-element can inherit a custom property but cannot read its
    # host's animation-delay, so the offsets travel as variables.
    for style <- cards(gallery(four_images())) do
      assert style =~ "--pk-hx-d1:"
      assert style =~ "--pk-hx-d2:"
      refute style =~ "animation-delay:"
    end
  end

  defp figure_class(html) do
    [_, cls] = Regex.run(~r/<figure class="([^"]*)"/, html)
    cls
  end

  test "motion=scroll ties the turn to the reader's scroll" do
    html = gallery(four_images(), ~s(height="520" motion="scroll"))

    assert figure_class(html) =~ "pk-helix--scroll"
    assert html =~ "@supports (animation-timeline: view())"

    # Neither a delay nor a range offset can carry per-card phase on a scroll
    # timeline, so each card names keyframes of its own.
    for style <- cards(html) do
      assert style =~ "--pk-hx-k1:pk-hx-"
      assert style =~ "--pk-hx-k2:pk-hx-"
    end

    # Those keyframes have to actually exist, and differ per card — identical
    # ones would be lockstep rotation wearing a disguise.
    names = Regex.scan(~r/@keyframes (pk-hx-g\d+-m\d+)/, html) |> Enum.map(&Enum.at(&1, 1))
    assert length(names) == 4
    assert length(Enum.uniq(names)) == 4

    starts =
      Regex.scan(
        ~r/@keyframes pk-hx-g\d+-m\d+\{from\{transform:[^}]*rotateY\(([-\d.]+)turn\)/,
        html
      )
      |> Enum.map(&Enum.at(&1, 1))

    assert length(Enum.uniq(starts)) > 1, "every card would start facing the same way"
  end

  test "the scroll timeline is named, not view() on the cards" do
    html = gallery(four_images(), ~s(motion="scroll"))

    # `view()` resolves against the nearest scroll container, and the scene is
    # overflow:hidden — which counts as one. Bound to that, the timeline never
    # advances and every card freezes at whatever progress it started on. The
    # figure sits outside the clip, so the timeline is declared there.
    assert html =~ ".pk-helix--scroll{view-timeline-name:--pk-hx-view"
    assert html =~ "animation-timeline:--pk-hx-view"

    # The @supports condition still mentions view() as a feature probe, so
    # check the card rule itself rather than the whole document.
    card_rule =
      html
      |> String.split(".pk-helix--scroll .pk-helix__card{")
      |> Enum.at(1)
      |> String.split("}")
      |> List.first()

    refute card_rule =~ "animation-timeline:view()"
  end

  test "the scroll fallback only runs where the CSS can't" do
    source = File.read!("lib/phoenix_kit_publishing/web/html.ex")

    [_, script] = String.split(source, "defp helix_scroll_fallback_script", parts: 2)
    script = String.slice(script, 0, 3000)

    # CSS is the real implementation — around 84% of browsers run it, and the
    # script must not touch those. Firefox only gained animation-timeline in
    # 156 and Safari in 26, which is the gap this fills.
    assert script =~ "CSS.supports('animation-timeline: view()')"
    assert script =~ "return"

    # It drives the EXISTING drift animations rather than re-deriving the
    # geometry, so there is no second copy of the maths to drift out of step.
    assert script =~ "a.pause()"
    assert script =~ "currentTime"
    refute script =~ "rotateY"

    # Someone who asked for less motion gets none of it.
    assert script =~ "prefers-reduced-motion"
  end

  test "drift mode emits no per-card keyframes" do
    # They're only needed where delays can't carry phase; emitting them always
    # would bloat every cached post body for nothing.
    refute gallery(four_images()) =~ "@keyframes pk-hx-g"
  end

  test "drift is the default and an unknown motion falls back to it" do
    refute figure_class(gallery(four_images())) =~ "pk-helix--scroll"
    refute figure_class(gallery(four_images(), ~s(motion="sideways"))) =~ "pk-helix--scroll"
  end

  test "scroll mode degrades to drift, not to a still gallery" do
    html = gallery(four_images(), ~s(motion="scroll"))

    # The timeline is applied inside @supports; the time-based animation is
    # declared outside it, so a browser without scroll timelines keeps
    # turning rather than freezing.
    [before_supports, _] = String.split(html, "@supports (animation-timeline: view())", parts: 2)
    assert before_supports =~ "animation:pk-hx-move"
  end

  test "an explicit background still wins" do
    html = gallery(four_images(), ~s(height="400" background="#101014"))
    assert html =~ "--pk-hx-bg:#101014"

    themed = gallery(four_images(), ~s|background="var(--color-base-300)"|)
    assert themed =~ "--pk-hx-bg:var(--color-base-300)"
  end

  test "a background that isn't a colour is dropped, not escaped into the style" do
    # This lands inside a `style` attribute, where `;` opens a new declaration
    # — HTML escaping doesn't stop that, so the value is allow-listed instead.
    html = gallery(four_images(), ~s(background="red;position:fixed;inset:0"))

    refute html =~ "position:fixed"
    refute html =~ "--pk-hx-bg:"
  end

  test "expensive and unwanted work is dropped where it should be" do
    html = gallery(four_images())

    # Blur is the costly part, off on small screens and on coarse pointers.
    assert html =~ "@media (max-width:767px){.pk-helix__scene{--pk-hx-blur:0px}}"
    assert html =~ "(hover:none) and (pointer:coarse)"

    # Reduced motion poses it; reduced data / slow displays abandon it.
    assert html =~ "prefers-reduced-motion"
    assert html =~ "prefers-reduced-data"
    assert html =~ "(update:slow)"
  end

  test "the stylesheet rides along only when a gallery rendered" do
    with_gallery = gallery(four_images())
    without = render("Just prose, no gallery here.")

    assert with_gallery =~ "@keyframes pk-hx-move"
    assert with_gallery =~ "@keyframes pk-hx-scrim"
    assert with_gallery =~ "prefers-reduced-motion"
    refute without =~ "pk-hx-move"
  end

  test "a gallery with no usable images renders nothing rather than a black box" do
    html = gallery("Some words but no pictures.")

    refute html =~ "pk-helix"
    assert html =~ "Before."
  end

  test "geometry attributes are honoured and clamped" do
    html = gallery(four_images(), ~s(height="640" radius="500" turns="3" speed="45"))

    assert html =~ "--pk-hx-height:640px"
    assert html =~ "--pk-hx-radius:500px"
    assert html =~ "--pk-hx-turns:3"
    assert html =~ "--pk-hx-dur:45s"

    # The depth animation runs on the ROTATION period; getting this wrong
    # desynchronises the dimming from the actual angle.
    assert html =~ "--pk-hx-rot:15.0s"

    # The strand must overrun the frame or the wrap becomes visible.
    assert html =~ "--pk-hx-span:960px"
  end

  test "absurd values are clamped instead of trusted" do
    html = gallery(four_images(), ~s(height="99999" radius="-40" turns="0"))

    assert html =~ "--pk-hx-height:1200px"
    assert html =~ "--pk-hx-radius:120px"
    assert html =~ "--pk-hx-turns:1"
  end

  test "image sources and alt text are escaped" do
    hostile =
      "![\" onerror=\"alert(1)](https://example.test/x.jpg\"><script>alert(1)</script>)"

    html = gallery(hostile)

    refute html =~ "<script>alert(1)</script>"
    refute html =~ ~s(onerror="alert)
  end
end
