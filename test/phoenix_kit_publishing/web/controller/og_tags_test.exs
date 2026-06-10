defmodule PhoenixKit.Modules.Publishing.Web.Controller.OgTagsTest do
  @moduledoc """
  Unit tests for the in-page OpenGraph/Twitter meta-tag component
  (`Web.HTML.og_meta_tags/1`). Publishing renders these inside the public
  page body so social link previews work even when the host's root layout
  doesn't render the forwarded `:og` assign in `<head>`.

  The full controller→layout render path can't be asserted here: the test
  endpoint's stand-in `Layouts.app` only surfaces layout chrome, not the
  publishing template's inner content (where these tags live). End-to-end
  rendering + the `publishing_render_og_tags` toggle are verified against a
  running host. This component test pins the tag set + conditionals.
  """

  use PhoenixKitPublishing.DataCase

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Publishing.Web.HTML

  defp render_og(og), do: render_component(&HTML.og_meta_tags/1, og: og)

  test "renders the full OpenGraph + Twitter Card set" do
    html =
      render_og(%{
        type: "article",
        title: "Hello World",
        description: "A nice post",
        image: "https://cdn.example.com/x.png",
        url: "https://example.com/blog/hello",
        locale: "en-US"
      })

    assert html =~ ~s(<meta property="og:type" content="article">)
    assert html =~ ~s(<meta property="og:title" content="Hello World">)
    assert html =~ ~s(<meta name="twitter:title" content="Hello World">)
    assert html =~ ~s(<meta property="og:description" content="A nice post">)
    assert html =~ ~s(<meta name="twitter:description" content="A nice post">)
    assert html =~ ~s(<meta property="og:image" content="https://cdn.example.com/x.png">)
    assert html =~ ~s(<meta name="twitter:image" content="https://cdn.example.com/x.png">)
    assert html =~ ~s(<meta property="og:url" content="https://example.com/blog/hello">)
    assert html =~ ~s(<meta property="og:locale" content="en-US">)
    assert html =~ ~s(property="og:site_name")
    assert html =~ ~s(<meta name="twitter:card" content="summary_large_image">)
  end

  test "without an image, twitter:card falls back to summary and no og:image is emitted" do
    html = render_og(%{type: "website", title: "Blog", url: "https://example.com/blog"})

    refute html =~ "og:image"
    refute html =~ "twitter:image"
    assert html =~ ~s(<meta name="twitter:card" content="summary">)
  end

  test "renders nothing when there is no og data" do
    assert String.trim(render_og(nil)) == ""
  end

  test "html-escapes attacker-influenced values (title/description/image/url)" do
    html =
      render_og(%{
        type: "article",
        title: ~s|Evil" /><script>alert(1)</script>|,
        description: ~s(D" onload="x),
        image: ~s(https://x/"><script>),
        url: ~s(https://x/"><img src=x>)
      })

    # No tag breakout: the crafted markup must not survive as live HTML.
    refute html =~ "<script>"
    refute html =~ ~s(Evil" />)
    refute html =~ ~s(onload="x)
    refute html =~ ~s(<img src=x>)
    # Dangerous chars land escaped inside the attribute value.
    assert html =~ "&quot;" or html =~ "&gt;"
  end
end
