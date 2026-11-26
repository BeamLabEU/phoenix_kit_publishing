defmodule PhoenixKit.Modules.Publishing.Web.CSPInlineTagsTest do
  @moduledoc """
  The module works under a host's nonce Content-Security-Policy: every inline
  `<script>` / `<style>` it renders per request carries the nonce
  (`PhoenixKit.Modules.Publishing.Web.CSP`), and it renders no inline event
  handler (no nonce covers an attribute). Modelled on core's
  `csp_inline_tags_test.exs`. The module ships no JavaScript of its own.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Web.CSP
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML

  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  # The stylesheets the renderer appends to a post's body. That body is CACHED
  # (the render cache) and the same for every reader, so no request's nonce may
  # reach it: these `<style>` blocks carry none, on purpose. A host with a
  # strict `style-src` allows them another way (they are styles only, never
  # script). `Renderer` also matches `<style>` as text to recognise its own
  # blocks in a cached render.
  @cached_body [
    "lib/phoenix_kit_publishing/renderer.ex",
    "lib/phoenix_kit_publishing/page_builder/components/image.ex"
  ]

  # A data block (`application/ld+json`) is not executed and not checked by
  # `script-src`.
  @data_block ~r/type="application\/ld\+json"/

  @tag_opening ~r/<(script|style)\b[^>]*>/s

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path not in @cached_body,
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not (opening =~ @data_block),
          not (opening =~ "CSP.nonce(" or opening =~ "CSP.attr("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without `nonce={Publishing.Web.CSP.nonce(kind)}`:\n" <>
             Enum.join(offenders, "\n")
  end

  test "the scan sees the tags the module renders, in HEEx and in a string" do
    openings = tag_openings("lib/phoenix_kit_publishing/web/html.ex")

    assert Enum.any?(
             openings,
             &(elem(&1, 0) =~ "<script nonce={CSP.nonce(:script)}>")
           )

    assert Enum.any?(
             openings,
             &(elem(&1, 0) =~ "<style nonce={CSP.nonce(:style)}>")
           )

    assert Enum.any?(openings, &(elem(&1, 0) =~ "CSP.attr(:style)"))

    # The exempt files are exempt because they do hold bare tags.
    for path <- @cached_body do
      assert Enum.any?(tag_openings(path), &(elem(&1, 0) == "<style>")), path
    end
  end

  test "a cached post body never carries a nonce" do
    Process.put({PhoenixKitWeb.CSP, :nonces}, %{style: "st-1", script: "sc-1"})

    html = Renderer.render_markdown(~s|Body <Note note="n">p</Note> end|)

    assert html =~ "<style>"
    refute html =~ "nonce"
  after
    Process.delete({PhoenixKitWeb.CSP, :nonces})
  end

  # `nonce={…}` is HEEx. In a plain string it is rendered as written.
  test "a `nonce={…}` attribute in an .ex file sits inside a ~H template" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          lines = path |> File.read!() |> code_lines(),
          {line, number} <- lines,
          line =~ ~r/nonce=\{[\w.]*CSP/,
          not in_heex?(lines, number),
          do: "#{path}:#{number}"

    assert offenders == [],
           "write `<style\#{Publishing.Web.CSP.attr(:style)}>` in a plain string:\n" <>
             Enum.join(offenders, "\n")
  end

  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding or a hook):\n" <>
             Enum.join(offenders, "\n")
  end

  test "the handler pattern catches what it is for" do
    assert ~S|<button onclick="window.print()">| =~ @handler
    assert ~s(<img onerror={@x}>) =~ @handler
    assert ~S|<a href="javascript:void(0)">| =~ @js_url
    refute ~s(<button phx-click="go" data-x>) =~ @handler
  end

  describe "Publishing.Web.CSP" do
    # Whatever core is installed (the published one has no `PhoenixKitWeb.CSP`),
    # a page with no nonce renders as it always did.
    test "with no nonce on the page: no attribute, the session untouched" do
      assert CSP.nonce(:style) == nil
      assert CSP.nonce(:script) == nil
      assert CSP.attr(:style) == ""
      assert CSP.nested_session(%{"id" => "x"}) == %{"id" => "x"}
      assert CSP.on_mount(:default, %{}, %{}, :socket) == {:cont, :socket}

      html =
        Phoenix.LiveViewTest.rendered_to_string(
          PublishingHTML.reading_progress(%{
            enabled: true,
            __changed__: nil
          })
        )

      assert html =~ "<style>"
      assert html =~ "<script>"
      assert html =~ "__pkReadingProgress"
      refute html =~ "nonce"
    end

    test "with core's CSP support: the page's nonce reaches the tags and a nested view" do
      if Code.ensure_loaded?(PhoenixKitWeb.CSP) do
        session = %{"phoenix_kit_csp_nonces" => %{"style" => "st-1", "script" => "sc-1"}}
        assert CSP.on_mount(:default, %{}, session, :socket) == {:cont, :socket}

        assert CSP.nonce(:style) == "st-1"
        assert CSP.nonce(:script) == "sc-1"
        assert CSP.attr(:style) == ~s( nonce="st-1")
        assert CSP.nested_session(%{"id" => "x"}) == Map.put(session, "id", "x")

        html =
          Phoenix.LiveViewTest.rendered_to_string(
            PublishingHTML.reading_progress(%{
              enabled: true,
              __changed__: nil
            })
          )

        assert html =~ ~s(<style nonce="st-1">)
        assert html =~ ~s(<script nonce="sc-1">)
        refute html =~ "<script>"
      end
    end
  end

  defp in_heex?(lines, number) do
    lines
    |> Enum.take(number - 1)
    |> Enum.reverse()
    |> Enum.find(fn {line, _} -> line =~ ~s(""") end)
    |> case do
      {opener, _} -> opener =~ ~s(~H""")
      nil -> false
    end
  end

  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept:
  # documentation, HEEx comments and Elixir comment lines.
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/@(?:moduledoc|doc|typedoc)\s+"[^"\n]*"/, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
