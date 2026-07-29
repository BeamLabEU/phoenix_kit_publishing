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

    test "tone defaults to the PAGE's colours, not a coloured slab" do
      # The band spans the full width, so a hardcoded dark background painted a
      # black rectangle beside the image on a light page (reported on a live
      # post). The default now takes base-100/base-content, which makes the
      # band invisible against the page and the image dissolve into it.
      default = render(~s(<Showcase src="/a.jpg">Text</Showcase>))

      assert default =~ ~s(class="pk-showcase pk-showcase--left pk-showcase--page)
      refute default =~ "pk-showcase--dark pk-showcase"
      assert default =~ ".pk-showcase--page{background:var(--color-base-100"
      assert default =~ "var(--color-base-100,#fff))}"
    end

    test "explicit tones opt into a deliberate band" do
      for {tone, class} <- [{"dark", "--dark"}, {"light", "--light"}, {"none", "--none"}] do
        html = render(~s(<Showcase src="/a.jpg" tone="#{tone}">Text</Showcase>))
        assert html =~ "pk-showcase pk-showcase--left pk-showcase#{class}"
      end
    end

    test "the scrim starts earlier as the overlap widens" do
      [narrow, wide] =
        Enum.map([5, 40], fn o ->
          html = render(~s(<Showcase src="/a.jpg" overlap="#{o}">T</Showcase>))
          [_, fade] = Regex.run(~r/--pk-sc-fade:(\d+)%/, html)
          String.to_integer(fade)
        end)

      assert wide < narrow
      assert wide >= 30
    end
  end

  describe "width and height controls" do
    test "align/stretch control how far the band reaches past the text column" do
      full = render(~s(<Showcase src="/a.jpg">T</Showcase>))
      wide = render(~s(<Showcase src="/a.jpg" align="wide">T</Showcase>))
      pct = render(~s(<Showcase src="/a.jpg" stretch="20">T</Showcase>))
      inside = render(~s(<Showcase src="/a.jpg" align="none">T</Showcase>))

      # Default: full-bleed to the viewport edge.
      assert full =~ "pk-stretch"
      assert full =~ "(100vw - 100%) / 2 - 1rem"
      # Presets and explicit percentages hang out by a measured amount.
      assert wide =~ "min(15.0%,"
      assert pct =~ "min(10.0%,"
      # align="none" keeps the band inside the text column — no wrapper at all.
      refute inside =~ "pk-stretch"
    end

    test "height pins the image area; presets and pixel values both work" do
      auto = render(~s(<Showcase src="/a.jpg">T</Showcase>))
      short = render(~s(<Showcase src="/a.jpg" height="short">T</Showcase>))
      px = render(~s(<Showcase src="/a.jpg" height="420">T</Showcase>))

      # Default keeps the image's natural aspect — no fixed height at all.
      # `--fixed"` (with the quote) matches only the figure's class attribute;
      # a bare "pk-showcase--fixed" also matches the stylesheet's own rules.
      refute auto =~ ~s(pk-showcase--fixed")
      refute auto =~ "--pk-sc-height:"

      assert short =~ ~s(pk-showcase--fixed")
      assert short =~ "--pk-sc-height:18rem"
      assert px =~ "--pk-sc-height:420px"
      # The fixed rule must out-specify the responsive min-heights.
      assert short =~ ".pk-showcase--fixed .pk-showcase__media{height:var(--pk-sc-height"
      assert short =~ ".pk-showcase--fixed .pk-showcase__media img{height:100%;min-height:0}"
    end

    test "an out-of-range or junk height falls back to the natural aspect" do
      for bad <- ["10", "99999", "enormous", "auto"] do
        html = render(~s(<Showcase src="/a.jpg" height="#{bad}">T</Showcase>))
        refute html =~ ~s(pk-showcase--fixed")
      end
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

      # The mobile scrim rules MUST carry the side classes. The desktop rules
      # are `.side.tone .media::after` (three classes); a two-class mobile rule
      # loses on specificity and the wash silently never applies — which is
      # exactly what shipped until a browser measurement caught it. A textual
      # test can't evaluate specificity, so pin the shape instead.
      [_, mobile] = String.split(html, "@media (max-width:767px)")

      for tone <- ~w(page dark light) do
        assert mobile =~
                 ".pk-showcase--left.pk-showcase--#{tone} .pk-showcase__media::after,\n" <>
                   "  .pk-showcase--right.pk-showcase--#{tone} .pk-showcase__media::after"
      end
    end
  end

  describe "interactions with the rest of the pipeline" do
    # Every feature in the body is regex-driven over the same source: the code
    # mask, the note extractor, the hashtag linkifier and the component
    # scanner. A quorum reviewer flagged that they were only ever tested in
    # isolation, which is fair — this renders them all at once.
    test "showcase, notes, hashtags and code coexist" do
      html =
        Renderer.render_markdown(
          """
          Intro with #elixir and a <Note note="a clarifying remark">phrase</Note>.

          <Showcase src="/a.jpg" side="right" overlap="20" alt="Band">
          ### Band heading #phoenix

          Band prose with a <Note note="note inside a band">second note</Note>.
          </Showcase>

          ```
          <Showcase src="/x.jpg">literal example #nottag</Showcase>
          ```

          Outro #otp.
          """,
          tag_links: {"blog", "en"}
        )

      # The band rendered, once, with its own markup.
      assert length(String.split(html, ~s(class="pk-showcase ))) - 1 == 1
      assert html =~ "Band heading"

      # Prose hashtags outside the band link, and so do the band's own —
      # a Showcase body is markdown, so it gets the same treatment.
      assert html =~ ~s(/blog/tag/elixir")
      assert html =~ ~s(/blog/tag/otp")
      assert html =~ ~s(/blog/tag/phoenix")
      # ...and the fenced example neither renders nor tags.
      refute html =~ ~s(/blog/tag/nottag)
      assert html =~ "&lt;Showcase"

      # Notes still number sequentially across the whole document, including
      # the one inside the band, and neither is duplicated as bare text.
      assert html =~ "<sup>1</sup>"
      assert html =~ "<sup>2</sup>"
      refute html =~ "a clarifying remarkphrase"

      # Exactly one copy of each stylesheet.
      assert length(String.split(html, "pk-showcase__media{grid-row")) - 1 == 1
      assert length(String.split(html, ".pk-note-ref{text-decoration")) - 1 == 1
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
