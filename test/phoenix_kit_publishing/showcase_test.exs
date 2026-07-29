defmodule PhoenixKit.Modules.Publishing.ShowcaseTest do
  @moduledoc """
  Pins the `<Showcase>` band (boss call 2026-07-29): an image bled to one
  edge with the text on the other, the two sharing an overlap column, and
  the image tinted toward the band colour where the text sits over it.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer

  defp render(markup), do: Renderer.render_markdown(markup)

  describe "layout" do
    test "renders the band, the image and the markdown body" do
      html =
        render("""
        <Showcase src="https://cdn.example.com/a.jpg" alt="A room">
        ### Paintings, reconstructed

        Step into the bedroom.
        </Showcase>
        """)

      assert html =~ "pk-showcase"
      assert html =~ ~s(src="https://cdn.example.com/a.jpg")
      assert html =~ ~s(alt="A room")
      # The body is MARKDOWN, not literal text.
      assert html =~ "<h3"
      assert html =~ "Paintings, reconstructed"
      assert html =~ "Step into the bedroom."
      # Lazy by default — these are large decorative images.
      assert html =~ ~s(loading="lazy")
    end

    test "side picks which edge the image bleeds to; left is the default" do
      left = render(~s(<Showcase src="/a.jpg">Text</Showcase>))
      right = render(~s(<Showcase src="/a.jpg" side="right">Text</Showcase>))

      # Assert on the figure's own classes — the stylesheet carries rules for
      # BOTH sides, so a bare substring check would pass either way.
      assert left =~ ~s(class="pk-showcase pk-showcase--left)
      refute left =~ ~s(class="pk-showcase pk-showcase--right)
      assert right =~ ~s(class="pk-showcase pk-showcase--right)
    end

    test "the band is full-bleed by default but honors align/stretch" do
      default = render(~s(<Showcase src="/a.jpg">Text</Showcase>))
      narrowed = render(~s(<Showcase src="/a.jpg" stretch="20">Text</Showcase>))

      assert default =~ "pk-stretch"
      assert default =~ "100vw"
      # An explicit lane wins over the full-bleed default.
      assert narrowed =~ "min(10.0%,"
    end
  end

  describe "overlap and scrim" do
    test "overlap becomes a grid track and drives the scrim strength" do
      small = render(~s(<Showcase src="/a.jpg" overlap="0">Text</Showcase>))
      large = render(~s(<Showcase src="/a.jpg" overlap="40">Text</Showcase>))

      assert small =~ "--pk-sc-overlap:0%"
      assert large =~ "--pk-sc-overlap:40%"

      # More text over the image ⇒ more tint, so it stays readable.
      [small_shade, large_shade] =
        Enum.map([small, large], fn html ->
          [_, shade] = Regex.run(~r/--pk-sc-shade:([0-9.]+)/, html)
          String.to_float(shade)
        end)

      assert large_shade > small_shade
      assert large_shade <= 0.8
    end

    test "out-of-range and junk overlaps fall back to the default" do
      for bad <- [~s(overlap="999"), ~s(overlap="-5"), ~s(overlap="lots"), ""] do
        html = render(~s(<Showcase src="/a.jpg" #{bad}>Text</Showcase>))
        assert html =~ "--pk-sc-overlap:15%"
      end
    end

    test "tone selects the band's own colours; dark is the default" do
      dark = render(~s(<Showcase src="/a.jpg">Text</Showcase>))
      light = render(~s(<Showcase src="/a.jpg" tone="light">Text</Showcase>))
      none = render(~s(<Showcase src="/a.jpg" tone="none">Text</Showcase>))

      assert dark =~ "pk-showcase--dark"
      assert light =~ "pk-showcase--light"
      assert none =~ "pk-showcase--none"
    end
  end

  describe "stylesheet" do
    test "ships once per document, and only when a showcase is present" do
      plain = render("Just prose.")
      refute plain =~ "pk-showcase"

      one = render(~s(<Showcase src="/a.jpg">A</Showcase>))
      assert one =~ ".pk-showcase{display:grid"

      two =
        render("""
        <Showcase src="/a.jpg">A</Showcase>

        <Showcase src="/b.jpg" side="right">B</Showcase>
        """)

      # Two bands, one stylesheet.
      assert length(String.split(two, "pk-showcase__media{grid-row")) - 1 == 1
      assert length(String.split(two, ~s(class="pk-showcase ))) - 1 == 2
    end

    test "narrow screens stack and wash the image so the text stays readable" do
      html = render(~s(<Showcase src="/a.jpg">Text</Showcase>))

      assert html =~ "@media (max-width:767px)"
      assert html =~ "grid-template-columns:1fr"
      assert html =~ "linear-gradient(to bottom"
    end
  end

  describe "safety" do
    test "unsafe src schemes render the prose alone, never the image" do
      for bad <- ["javascript:alert(1)", "data:image/png;base64,x", "ftp://x/y.jpg"] do
        html = render(~s(<Showcase src="#{bad}">Fallback text</Showcase>))
        refute html =~ "<img"
        refute html =~ "pk-showcase"
        # The words still reach the reader.
        assert html =~ "Fallback text"
      end
    end

    test "alt text is escaped, not injected" do
      html = render(~s[<Showcase src="/a.jpg" alt="a < b & c">Text</Showcase>])
      assert html =~ ~s(alt="a &lt; b &amp; c")
    end

    test "an attribute value containing '>' closes the tag early (house-wide limit)" do
      # Every PHK component's opening tag is scanned with [^>]*, so a '>' in a
      # value ends the tag there. Pinned as KNOWN behavior: the parse degrades
      # to an empty attribute — it must never emit the raw value into markup.
      html = render(~s[<Showcase src="/a.jpg" alt="<script>x</script>">Text</Showcase>])
      refute html =~ "<script>"
      assert html =~ ~s(alt="")
    end

    test "a Showcase inside a code fence renders as text, not a band" do
      html =
        render("""
        ```
        <Showcase src="/a.jpg">Example</Showcase>
        ```
        """)

      refute html =~ "pk-showcase"
      assert html =~ "&lt;Showcase"
    end
  end
end
