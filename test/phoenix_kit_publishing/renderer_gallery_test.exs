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
        [_, move] = Regex.run(~r/animation-delay:(-?[\d.]+)s/, style)
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

  test "the backdrop and the depth cue both follow the theme" do
    html = gallery(four_images())

    # A hardcoded near-black panel is a foreign object on a light theme —
    # the same mistake the Showcase band's default tone once made.
    assert html =~ "var(--pk-hx-bg,var(--color-base-100,#fff))"
    refute html =~ "#0d0d0c"

    # Distance reads as opacity, not brightness. Darkening only recedes over a
    # dark backdrop; on a light theme it makes the far cards jump forward.
    assert html =~ "opacity:0.15;"
    refute html =~ "brightness("
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
    assert with_gallery =~ "@keyframes pk-hx-depth"
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
