defmodule PhoenixKit.Modules.Publishing.Web.Controller.EmbedTest do
  @moduledoc """
  Pins the `<Embed>` inline component's contract: sandboxed iframe, height
  clamping, and the `<Audio>`-style safe-src posture (http(s) or
  root-relative only). Added by PR #48 with no test coverage of its own.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer

  describe "<Embed> inline component" do
    test "renders a sandboxed lazy iframe from a root-relative src" do
      html = Renderer.render_markdown(~s(<Embed src="/demos/leaf" title="Try the editor" />))

      assert html =~ "<iframe"
      assert html =~ ~s(src="/demos/leaf")
      assert html =~ ~s(loading="lazy")
      assert html =~ "sandbox="
      assert html =~ "allow-scripts"
      assert html =~ "allow-same-origin"
      assert html =~ "Try the editor"
    end

    test "renders from an absolute http(s) src" do
      html = Renderer.render_markdown(~s(<Embed src="https://example.com/widget" />))
      assert html =~ ~s(src="https://example.com/widget")
    end

    test "caption renders alongside the title" do
      html =
        Renderer.render_markdown(
          ~s(<Embed src="/demos/leaf" title="Try it" caption="Pan and zoom" />)
        )

      assert html =~ "Try it"
      assert html =~ "Pan and zoom"
    end

    test "height is clamped between 160 and 1200, defaulting to 480" do
      too_small = Renderer.render_markdown(~s(<Embed src="/x" height="10" />))
      assert too_small =~ "height: 160px;"

      too_big = Renderer.render_markdown(~s(<Embed src="/x" height="5000" />))
      assert too_big =~ "height: 1200px;"

      in_range = Renderer.render_markdown(~s(<Embed src="/x" height="520" />))
      assert in_range =~ "height: 520px;"

      no_height = Renderer.render_markdown(~s(<Embed src="/x" />))
      assert no_height =~ "height: 480px;"
    end

    test "unsafe src schemes render nothing" do
      for bad <- ["javascript:alert(1)", "data:text/html,<script>x</script>", "ftp://x/y"] do
        html = Renderer.render_markdown(~s(<Embed src="#{bad}" />))
        refute html =~ "<iframe"
      end
    end

    test "a missing src renders nothing" do
      refute Renderer.render_markdown(~s(<Embed title="No src" />)) =~ "<iframe"
    end

    test "self-closing components honor stretch (the inline path wraps too)" do
      html = Renderer.render_markdown(~s(<Embed src="/x" stretch="20" />))
      assert html =~ "pk-stretch"
    end

    test "Embed is a declared PHK component tag (preserve_tags contract)" do
      assert "Embed" in Renderer.component_tags()
    end
  end
end
