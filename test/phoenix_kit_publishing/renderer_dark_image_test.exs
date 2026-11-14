defmodule PhoenixKit.Modules.Publishing.RendererDarkImageTest do
  # `<Image dark_src|dark_file_uuid>`: a light/dark pair, one of which a
  # generated stylesheet hides according to the site theme (`data-theme` on
  # <html>) or, without one, the OS preference. Synthetic content only.
  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Modules.Publishing.PageBuilder
  alias PhoenixKit.Modules.Publishing.PageBuilder.Components.Image
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Renderer.Sanitizer
  alias PhoenixKit.Modules.Shared.Components.Image, as: CoreImage

  @uuid "018e3c4a-9f6b-7890-abcd-ef1234567890"

  defp assigns(attributes),
    do: %{
      __changed__: nil,
      attributes: attributes,
      variant: "default",
      content: nil,
      children: []
    }

  defp to_html(rendered), do: rendered |> Safe.to_iodata() |> IO.iodata_to_binary()

  defp imgs(html), do: Regex.scan(~r/<img [^>]*>/, html) |> List.flatten()

  describe "without a dark attribute" do
    test "the component's output is core's, byte for byte" do
      for attrs <- [
            %{"src" => "/l.png", "alt" => "Shot"},
            %{"src" => "/l.png", "alt" => "Shot", "class" => "w-full", "dark_src" => ""},
            %{"src" => "/l.png", "dark_file_uuid" => "  "}
          ] do
        core = attrs |> Map.drop(~w(dark_src dark_file_uuid)) |> assigns() |> CoreImage.render()
        assert to_html(Image.render(assigns(attrs))) == to_html(core)
      end
    end

    test "the rendered post carries no pair and no stylesheet" do
      html = Renderer.render_markdown(~s(<Image src="/l.png" alt="Shot" />))

      assert [img] = imgs(html)
      assert img =~ ~s(src="/l.png")
      refute html =~ "pk-img-"
      refute html =~ "<style>"
    end
  end

  describe "with dark_src" do
    setup do
      html =
        Renderer.render_markdown(
          ~s(Intro\n\n<Image src="/l.png" dark_src="/d.png" alt="The dashboard" class="w-full" />\n\nEnd)
        )

      %{html: html}
    end

    test "renders both images, marked, lazy, with the same alt and class", %{html: html} do
      assert [light, dark] = imgs(html)

      assert light =~ ~s(src="/l.png")
      assert light =~ "pk-img-light"
      assert dark =~ ~s(src="/d.png")
      assert dark =~ "pk-img-dark"

      for img <- [light, dark] do
        assert img =~ ~s(alt="The dashboard")
        assert img =~ ~s(loading="lazy")
        assert img =~ "w-full"
        refute img =~ "aria-hidden"
      end
    end

    test "appends the theme stylesheet once, after the body", %{html: html} do
      css = Image.dark_image_css()
      assert String.ends_with?(html, css)
      assert length(String.split(html, "<style>")) == 2
    end

    test "the stylesheet follows data-theme first and the OS preference only without one" do
      css = Image.dark_image_css()

      assert css =~ ~s([data-theme="phoenix-dark"])
      assert css =~ ~s([data-theme="dark"])
      refute css =~ ~s([data-theme="light"])
      refute css =~ ~s([data-theme="phoenix-light"])

      assert css =~
               "@media (prefers-color-scheme:dark){:root:not([data-theme]) .pk-img-light{display:none!important}}"

      assert css =~
               "@media (prefers-color-scheme:light){:root:not([data-theme]) .pk-img-dark{display:none!important}}"

      assert css =~ ~s(:root[data-theme]:not([data-theme="abyss"])
    end

    test "a second dark image does not add a second stylesheet" do
      html =
        Renderer.render_markdown(
          ~s(<Image src="/a.png" dark_src="/b.png" alt="a" />\n\n<Image src="/c.png" dark_src="/d.png" alt="c" />)
        )

      assert length(imgs(html)) == 4
      assert length(String.split(html, "<style>")) == 2
    end
  end

  test "dark_file_uuid takes a Storage file; one that does not resolve leaves the light image alone" do
    html = Renderer.render_markdown(~s(<Image src="/l.png" dark_file_uuid="#{@uuid}" alt="x" />))

    assert [img] = imgs(html)
    assert img =~ ~s(src="/l.png")
    refute html =~ "pk-img-"
    refute html =~ "<style>"
  end

  test "stretch and align wrap the pair in one lane" do
    html =
      Renderer.render_markdown(~s(<Image src="/l.png" dark_src="/d.png" alt="x" stretch="20" />))

    assert [_, inner] = String.split(html, ~s(<div class="pk-stretch"), parts: 2)
    [inside | _] = String.split(inner, "</div>", parts: 2)
    assert length(imgs(inside)) == 2

    full =
      Renderer.render_markdown(~s(<Image src="/l.png" dark_src="/d.png" alt="x" align="full" />))

    assert full =~ ~s(<div class="pk-stretch")
    assert length(imgs(full)) == 2
  end

  test "the page builder block path renders the pair" do
    {:ok, rendered} =
      PageBuilder.render_content(~s(<Image src="/l.png" dark_src="/d.png" alt="Shot" />))

    assert [light, dark] = rendered |> to_html() |> imgs()
    assert light =~ "pk-img-light"
    assert dark =~ "pk-img-dark"
  end

  test "the page sanitiser keeps both images, their classes and alt" do
    {:ok, rendered} =
      PageBuilder.render_content(~s(<Image src="/l.png" dark_src="/d.png" alt="Shot" />))

    assert [light, dark] = rendered |> to_html() |> Sanitizer.page() |> imgs()
    assert light =~ "pk-img-light" and light =~ ~s(alt="Shot") and light =~ ~s(loading="lazy")
    assert dark =~ "pk-img-dark" and dark =~ ~s(src="/d.png") and dark =~ ~s(alt="Shot")
  end

  test "an unsafe dark_src does not reach the page" do
    html =
      Renderer.render_markdown(~s|<Image src="/l.png" dark_src="javascript:alert(1)" alt="x" />|)

    refute html =~ "javascript:"
  end

  describe "the post-link pass" do
    test "keeps the stylesheet when it rewrites a [[post:]] link" do
      cached =
        Renderer.render_markdown(
          ~s(See [[post:#{@uuid}|the other post]].\n\n<Image src="/l.png" dark_src="/d.png" alt="x" />)
        )

      resolved = Renderer.resolve_post_links(cached, "en")

      refute resolved == cached
      refute resolved =~ "[[post:"
      assert String.ends_with?(resolved, Image.dark_image_css())
      assert length(imgs(resolved)) == 2
    end

    test "keeps a sheet cached under another theme list, and drops a forged one" do
      sheet = Image.dark_image_css(["midnight", "dark"])
      body = "<p>[[post:#{@uuid}|x]]</p>"

      assert String.ends_with?(Renderer.resolve_post_links(body <> sheet, "en"), sheet)

      forged = String.replace(sheet, "display:none", "background:red")
      refute Renderer.resolve_post_links(body <> forged, "en") =~ "<style>"
    end
  end

  describe "dark_image_css?/1" do
    test "recognises exactly the generated shape" do
      assert Image.dark_image_css?(Image.dark_image_css())
      assert Image.dark_image_css?(Image.dark_image_css([]))
      assert Image.dark_image_css?(Image.dark_image_css(["a_1", "b-2"]))

      refute Image.dark_image_css?("<style>.x{}</style>")
      refute Image.dark_image_css?(Image.dark_image_css(["a"]) <> "<p>")
      refute Image.dark_image_css?(nil)
    end
  end

  test "dark theme names are plain selector-safe names" do
    names = Image.dark_theme_names()
    assert "phoenix-dark" in names
    assert Enum.all?(names, &(&1 =~ ~r/\A[A-Za-z0-9_-]+\z/))
  end
end
