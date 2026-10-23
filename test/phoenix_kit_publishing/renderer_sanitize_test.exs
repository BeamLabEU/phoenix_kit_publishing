defmodule PhoenixKit.Modules.Publishing.RendererSanitizeTest do
  # Defence in depth for the renderer output (issue #60): the final HTML goes
  # through an allow-list sanitiser, after the notes section and the post-link
  # pass have run. Synthetic content only.
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Renderer.Sanitizer

  @uuid "018e3c4a-9f6b-7890-abcd-ef1234567890"

  # A budget far above the sub-second runtime and far below what the quadratic
  # regexes needed (about 4 s for 80 KB, close to a minute for 260 KB: a lone `>` at the end
  # is what makes each unclosed opener scan to the end); no sleeping, only a bound.
  @time_budget_ms 3_000

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {div(us, 1000), result}
  end

  # An opening tag is "balanced" when every `<` in the output starts a tag the
  # renderer could have produced; here: no `<` outside well-formed tags.
  defp assert_no_stray_lt(html) do
    stripped = Regex.replace(~r/<\/?[a-zA-Z][^<>]*>/, html, "")
    refute stripped =~ "<", "stray '<' left in: #{inspect(stripped)}"
  end

  describe "dangerous markup is removed" do
    test "script elements and their bodies" do
      html = Renderer.render_markdown("before\n\n<script>alert(1)</script>\n\nafter")
      refute html =~ "<script"
      refute html =~ "alert(1)"
      assert html =~ "before"
      assert html =~ "after"
    end

    test "on* event handler attributes" do
      html = Renderer.render_markdown(~s|<img src="/a.png" onerror="alert(1)" alt="x">|)
      refute html =~ "onerror"
      refute html =~ "alert(1)"
      assert html =~ ~s(src="/a.png")

      html = Renderer.render_markdown(~s|<div onclick="x()" class="grid">hi</div>|)
      refute html =~ "onclick"
      assert html =~ "grid"
    end

    test "javascript: and vbscript: URLs in href and src" do
      html = Renderer.render_markdown(~s|<a href="javascript:alert(1)">x</a>|)
      refute html =~ "javascript:"

      html = Renderer.render_markdown(~s|<a href=" jav&#x61;script:alert(1)">x</a>|)
      refute html =~ "script:"

      html = Renderer.render_markdown(~s|<img src="vbscript:msgbox(1)">|)
      refute html =~ "vbscript:"
    end

    test "style attributes that carry expressions or script URLs" do
      html =
        Renderer.render_markdown(
          ~s|<div style="width:expression(alert(1))">a</div>\n\n| <>
            ~s|<div style="background:url(javascript:alert(1))">b</div>\n\n| <>
            ~s|<div style="behavior:url(x.htc)">c</div>|
        )

      refute html =~ "expression"
      refute html =~ "javascript:"
      refute html =~ "behavior"
    end

    test "a plain declaration list in style survives" do
      html = Renderer.render_markdown(~s(<div style="text-align:center;margin:0 auto">a</div>))
      assert html =~ ~s(style="text-align:center;margin:0 auto")
    end

    test "raw style, iframe, form and object elements in the body" do
      body =
        "<style>body{display:none}</style>\n\n" <>
          ~s(<iframe src="https://evil.example/"></iframe>\n\n) <>
          ~s(<form action="https://evil.example/"><input name="p"></form>\n\n) <>
          ~s(<object data="x.swf"></object>\n\n<embed src="x.swf">)

      html = Renderer.render_markdown(body)

      for tag <- ~w(<style <iframe <form <object <embed) do
        refute html =~ tag, "#{tag} should not survive in author HTML"
      end
    end
  end

  describe "legitimate editor output is unchanged" do
    test "headings, links, lists, tables, code and emphasis keep their classes" do
      md = """
      # Title

      A [link](https://example.com/x) and **bold** and `code`.

      - one
      - two

      | a | b |
      |---|---|
      | 1 | 2 |

      ```elixir
      IO.puts("<b>")
      ```
      """

      html = Renderer.render_markdown(md)
      assert html =~ ~s(<h1 class="text-4xl)
      assert html =~ ~s(<a class="link link-primary" href="https://example.com/x")
      assert html =~ "list-disc"
      assert html =~ ~s(<table class="table w-full my-4">)
      assert html =~ "language-elixir"
      assert html =~ "&lt;b&gt;"
      assert html =~ "<strong>bold</strong>"
    end

    test "inline HTML containers with daisyUI classes survive" do
      html =
        Renderer.render_markdown(
          ~s(<div class="grid grid-cols-2 gap-4"><div class="card bg-base-200">a</div></div>)
        )

      assert html =~ ~s(<div class="grid grid-cols-2 gap-4">)
      assert html =~ ~s(<div class="card bg-base-200">)
    end

    test "details/summary and images survive" do
      html =
        Renderer.render_markdown(
          "<details><summary>More</summary>\n\nBody\n\n</details>\n\n![alt](/a.png)"
        )

      assert html =~ "<details>"
      assert html =~ "<summary>More</summary>"
      assert html =~ ~s(src="/a.png")
      assert html =~ ~s(alt="alt")
    end

    test "task list checkboxes survive" do
      html = Renderer.render_markdown("- [x] done\n- [ ] todo")
      assert html =~ ~s(type="checkbox")
      assert html =~ "checked"
    end

    test "notes keep their ids, data attribute, class and style block" do
      html =
        Renderer.render_markdown(~s(Text <Note note="It's a `tick`">phrase</Note> more))

      assert html =~ ~s(id="pk-note-ref-1")
      assert html =~ "pk-note-ref"
      assert html =~ ~s(href="#pk-note-1")
      assert html =~ ~s(id="pk-note-1")
      assert html =~ "data-note="
      assert html =~ "<style>"
      assert html =~ ~s(<section class="pk-notes)
    end
  end

  describe "footnotes escape quotes and backticks" do
    test "an apostrophe or backtick cannot end the data-note value or add attributes" do
      body = "x' onmouseover='alert(1) `onfocus=`alert(2)"
      html = Renderer.render_markdown(~s|x <Note note="#{body}">p</Note> y|)

      [tag] = Regex.run(~r/<a [^>]*pk-note-ref[^>]*>/, html)
      refute String.replace(tag, ~s|data-note="#{body}"|, "") =~ ~r/onmouseover|onfocus/
      # The text round-trips: shown to the reader exactly as written.
      assert html =~ ~s|data-note="#{body}"|
      assert html =~ ~s|<li id="pk-note-1">#{body} |
    end

    test "escape_html/1 encodes quote, backtick, hash and the markup characters" do
      # The cleaner that runs afterwards re-serialises quotes, so the end result
      # cannot show this; the escape is the first line of defence and is pinned here.
      assert Renderer.escape_html(~s|it's `x` #1 & <b> "q"|) ==
               "it&#39;s &#96;x&#96; &#35;1 &amp; &lt;b&gt; &quot;q&quot;"
    end

    test "no double escaping of the quote entities" do
      html = Renderer.render_markdown(~s|x <Note note="it's `tick`">p</Note> y|)
      refute html =~ "&amp;#"
      assert html =~ ~s|data-note="it's `tick`"|
    end
  end

  describe "unclosed markup does not assemble dangerous output" do
    test "an unclosed raw tag followed by notes stays inside its own element" do
      body = ~s(<div class="x" title="open\n\ntext <Note note="n1">phrase</Note> end)
      html = Renderer.render_markdown(body)

      refute html =~ ~r/<script/i
      assert_no_stray_lt(html)
      # The notes section must be a real, top-level section, not swallowed by
      # the attribute the body left open.
      assert html =~ ~s(<section class="pk-notes)
      [before_section, _] = String.split(html, "<section class=\"pk-notes", parts: 2)
      refute before_section =~ ~r/<[a-z]+[^<>]*$/
    end

    test "an unclosed comment or tag in the body cannot absorb the notes section" do
      html = Renderer.render_markdown(~s(<!-- never closed\n\nx <Note note="n">p</Note>))
      refute html =~ "<!--"
      assert html =~ ~s(<section class="pk-notes)
    end

    test "an unclosed anchor does not wrap a resolved post link" do
      cached = Renderer.render_markdown(~s(<a href="/x" [[post:#{@uuid}|Alias]]))
      resolved = Renderer.resolve_post_links(cached, "en")

      assert_no_stray_lt(resolved)
      refute resolved =~ ~r/<a[^>]*<a/
    end

    test "an unclosed attribute cannot swallow the alias a resolved link adds" do
      cached = Renderer.render_markdown(~s(<img alt="[[post:#{@uuid}|Alias" src=x>))
      resolved = Renderer.resolve_post_links(cached, "en")
      assert_no_stray_lt(resolved)
    end

    test "resolve_post_links sanitises what it appends" do
      # A token whose alias slice came out of a hand-built page: the final pass
      # must still strip a handler that arrives with it.
      html = "<p>[[post:#{@uuid}|<img src=x onerror=alert(1)>]]</p>"
      resolved = Renderer.resolve_post_links(html, "en")
      refute resolved =~ "onerror"
    end
  end

  describe "linear-time handling of long runs of unclosed anchors" do
    test "260 KB of '<a ' renders inside the time budget" do
      body = String.duplicate("<a ", div(260_000, 3)) <> ">"
      {ms, html} = timed(fn -> Renderer.render_markdown(body) end)

      assert ms < @time_budget_ms, "render took #{ms} ms"
      assert is_binary(html)
      assert_no_stray_lt(html)
    end

    test "260 KB of '<a href' renders inside the time budget" do
      body = String.duplicate("<a href", div(260_000, 7)) <> ">"
      {ms, _html} = timed(fn -> Renderer.render_markdown(body) end)
      assert ms < @time_budget_ms, "render took #{ms} ms"
    end

    test "resolve_post_links on 260 KB of '<a ' with a token stays linear" do
      html = String.duplicate("<a ", div(260_000, 3)) <> "> [[post:#{@uuid}|Alias]]"
      {ms, _} = timed(fn -> Renderer.resolve_post_links(html, "en") end)
      assert ms < @time_budget_ms, "resolve took #{ms} ms"
    end

    test "resolve_post_links on 260 KB of '<pre ' and '<code ' stays linear" do
      html = String.duplicate("<pre <code ", div(260_000, 11)) <> "> [[post:#{@uuid}|Alias]]"
      {ms, _} = timed(fn -> Renderer.resolve_post_links(html, "en") end)
      assert ms < @time_budget_ms, "resolve took #{ms} ms"
    end

    test "skip regions still protect tokens inside closed <a>, <code> and <pre>" do
      html = "<p>x <a href=\"/x\">[[post:#{@uuid}|A]]</a> <code>[[post:#{@uuid}|B]]</code></p>"
      assert Renderer.resolve_post_links(html, "en") == html
    end

    test "closing a nested code element does not end the surrounding literal region" do
      for tag <- ["pre", "a"] do
        html = "<#{tag}><code>sample</code>[[post:#{@uuid}|Literal]]</#{tag}>"
        assert Renderer.resolve_post_links(html, "en") == html
      end
    end

    test "only the token after a nested literal region is resolved" do
      html =
        "<pre><code>sample</code>[[post:#{@uuid}|Literal]]</pre>" <>
          "<p>[[post:#{@uuid}|Resolved]]</p>"

      resolved = Renderer.resolve_post_links(html, "en")
      assert resolved =~ "[[post:#{@uuid}|Literal]]"
      assert resolved =~ "<p>Resolved</p>"
      refute resolved =~ "[[post:#{@uuid}|Resolved]]"
    end
  end

  describe "style elements" do
    test "page/1 removes every style element, in any position" do
      html = Sanitizer.page("<p>a</p><style>X{}</style><p>b</p>")
      refute html =~ "<style"
      refute html =~ "X{}"
      assert html == "<p>a</p><p>b</p>"
    end

    test "page/1 does not let a malformed closing tag end a style early" do
      hostile = "<style>a{}</style x><img src=x onerror=alert(1)></style>"
      html = Sanitizer.page(hostile)
      refute html =~ "<style"
      refute html =~ "onerror"
    end

    test "a style element inside an attribute value does not become live" do
      html = Sanitizer.page(~s|<span title='<style>" onmouseover=alert(1) x="</style>'>t</span>|)
      # Still one attribute (the title, with the text escaped inside it).
      [tag] = Regex.run(~r/<span[^>]*>/, html)
      assert length(Regex.scan(~r/ [a-z-]+="/, tag)) == 1
      refute html =~ "<style"
    end

    test "resolve_post_links does not pass a hostile style element through" do
      html = "<style>a{}</style x><img src=x onerror=alert(1)></style> [[post:#{@uuid}|A]]"
      resolved = Renderer.resolve_post_links(html, "en")
      refute resolved =~ "onerror"
      refute resolved =~ "<style"
    end

    test "author style elements never reach the output, generated ones follow the body" do
      html =
        Renderer.render_markdown(~s|<style>.x{}</style>\n\nBody <Note note="n">p</Note> end|)

      refute html =~ ".x{}"
      body_at = :binary.match(html, "Body") |> elem(0)
      notes_at = :binary.match(html, ~s(<section class="pk-notes)) |> elem(0)
      css_at = :binary.match(html, "<style>") |> elem(0)
      assert body_at < notes_at and notes_at < css_at
    end

    test "a scrolling gallery's keyframes are appended after the figure" do
      md =
        ~s|<Gallery motion="scroll" height="400">\n![a](https://h/1.jpg)\n![b](https://h/2.jpg)\n</Gallery>|

      html = Renderer.render_markdown(md)
      assert html =~ "@keyframes"
      {fig_at, _} = :binary.match(html, "</figure>")
      {style_at, _} = :binary.match(html, "<style>")
      assert fig_at < style_at
    end
  end

  describe "style attribute values" do
    test "scroll-behavior and overscroll-behavior are plain declarations" do
      assert Sanitizer.style_value_safe?("scroll-behavior:smooth;overscroll-behavior:contain")
    end

    test "behavior, binding, url-like and attr functions are refused" do
      for bad <- [
            "behavior:url(x.htc)",
            "-moz-binding:url(x)",
            "background:image(x)",
            "background:cross-fade(a,b)",
            "background:paint(x)",
            "content:attr(title)",
            "width:expression(1)"
          ] do
        refute Sanitizer.style_value_safe?(bad), bad
      end
    end

    test "an unsafe style drops the whole attribute and keeps the tag" do
      html = Sanitizer.author(~s|<div style="color:red;behavior:url(x)">a</div>|)
      assert html == "<div>a</div>"
    end
  end

  describe "valueless media attributes" do
    test "a code block that shows them is left alone" do
      html = Renderer.render_markdown("```html\n<video controls=\"\"></video>\n```")
      assert html =~ ~s|&lt;video controls=""&gt;|
    end
  end

  describe "page profile in the live pipeline" do
    test "Embed keeps its sandboxed iframe, author iframes do not survive" do
      html =
        Renderer.render_markdown(
          ~s|<Embed src="https://example.com/w" title="T" />\n\n<iframe src="https://evil.example/"></iframe>|
        )

      assert html =~ ~s|<iframe src="https://example.com/w"|
      assert html =~ "sandbox="
      refute html =~ "evil.example"
    end

    test "Audio keeps its player, bare controls attribute included" do
      html = Renderer.render_markdown(~s|<Audio src="https://cdn.example.com/a.mp3" />|)
      assert html =~ ~s|<audio controls preload="none"|
    end

    test "Video keeps its markup" do
      html =
        Renderer.render_markdown(
          ~s|<Video url="https://www.youtube.com/watch?v=dQw4w9WgXcQ" caption="Cap" />|
        )

      assert html =~ "<iframe"
      assert html =~ "dQw4w9WgXcQ"
      refute html =~ ~r/\son[a-z]+=/
    end

    test "page/1 keeps form controls that author/1 removes" do
      form =
        ~s|<form action="/submit" method="post"><label for="n">N</label><input name="n" id="n" type="text"><select name="s"><option value="1">1</option></select><textarea name="t"></textarea><button type="submit">Go</button></form>|

      page = Sanitizer.page(form)

      for tag <- ~w(<form <input <select <option <textarea <button <label) do
        assert page =~ tag, "#{tag} should survive in the page profile"
      end

      author = Sanitizer.author(form)
      refute author =~ "<form"
      refute author =~ "<button"
    end
  end

  describe "resolve_post_links keeps the generated stylesheets" do
    @doc_with_everything """
    Intro <Note note="a note">phrase</Note> and a link [[post:#{@uuid}|Alias]].

    <Showcase src="/a.jpg">Text</Showcase>

    <Gallery motion="scroll" height="400">
    ![a](https://h/1.jpg)
    ![b](https://h/2.jpg)
    </Gallery>
    """

    defp style_blocks(html), do: Regex.scan(~r/<style>.*?<\/style>/s, html) |> Enum.map(&hd/1)

    test "notes, showcase, helix and gallery sheets survive byte for byte" do
      cached = Renderer.render_markdown(@doc_with_everything)
      before = style_blocks(cached)
      assert length(before) >= 4, "expected notes, keyframes, showcase and helix sheets"

      resolved = Renderer.resolve_post_links(cached, "en")
      assert resolved =~ "Alias"
      refute resolved =~ "[[post:"
      assert style_blocks(resolved) == before
    end

    test "a hostile style next to the generated ones is still removed" do
      cached = Renderer.render_markdown(@doc_with_everything)
      hostile = "<style>.hostile-marker{color:red}</style>"
      resolved = Renderer.resolve_post_links(hostile <> cached, "en")

      refute resolved =~ "hostile-marker"
      assert style_blocks(resolved) == style_blocks(cached)
    end

    test "a hostile style at the very end is not taken for a generated one" do
      cached = Renderer.render_markdown(@doc_with_everything)
      tail = "<style>a{}</style x><img src=x onerror=alert(1)></style>"
      resolved = Renderer.resolve_post_links(cached <> tail, "en")

      refute resolved =~ "onerror"
      refute resolved =~ "a{}"
      refute resolved =~ "<style x"
      # The sheets before it are no longer the tail of the document, so they go too.
      assert resolved =~ "Alias"
    end

    test "a keyframes-looking sheet with another rule after it is refused" do
      cached = Renderer.render_markdown(@doc_with_everything)
      sheet = "<style>@keyframes x{from{opacity:0}}.hostile-marker{color:red}</style>"
      resolved = Renderer.resolve_post_links(cached <> sheet, "en")
      refute resolved =~ "hostile-marker"
    end
  end

  describe "recognising the generated stylesheet tail" do
    defp everything, do: Renderer.render_markdown(@doc_with_everything)
    defp resolve(html), do: Renderer.resolve_post_links(html, "en")

    test "text after the sheets is not part of the tail" do
      resolved = resolve(everything() <> "<img src=x onerror=alert(1)>")
      refute resolved =~ "onerror"
    end

    test "a keyframes sheet that does not end the document is not recognised" do
      resolved =
        resolve(
          everything() <>
            "<style>@keyframes a{0%{x:y}}</style><img src=x onerror=alert(1)>"
        )

      refute resolved =~ "onerror"
    end

    test "a keyframes sheet with a fetching value is refused" do
      resolved = resolve(everything() <> "<style>@keyframes a{0%{background:url(x.png)}}</style>")
      refute resolved =~ "url(x.png)"
    end

    test "a keyframes name cannot carry another rule" do
      for sheet <- [
            "<style>@keyframes a;.hostile{b{color:red}}</style>",
            "<style>@keyframes a\n.hostile{b{color:red}}</style>"
          ] do
        resolved = resolve(everything() <> sheet)
        refute resolved =~ "hostile", sheet
      end
    end

    test "a constant sheet with an extra rule inside is refused" do
      cached = everything()
      helix = "<style>" <> (cached |> String.split("<style>") |> List.last())
      assert String.ends_with?(helix, "</style>\n")

      tampered = String.replace(helix, "</style>", ".hostile{color:red}</style>")
      resolved = resolve(cached <> tampered)
      refute resolved =~ "hostile"
    end

    test "foreign text between two sheets is cleaned and the sheets after it stay" do
      cached = everything()
      [before, rest] = String.split(cached, "<style>\n.pk-showcase", parts: 2)
      rest = "<style>\n.pk-showcase" <> rest

      resolved = resolve(before <> "<img src=x onerror=alert(1)>" <> rest)

      refute resolved =~ "onerror"
      assert String.ends_with?(resolved, rest)
    end
  end

  describe "generated style collection" do
    @key :pk_publishing_generated_styles

    test "a stale collection before a render does not reach the output, and is put back" do
      Process.put(@key, ["junk{}"])
      html = Renderer.render_markdown("plain text")

      refute html =~ "junk{}"
      assert Process.get(@key) == ["junk{}"]
      Process.delete(@key)
    end

    test "nothing is left behind when there was nothing before" do
      Process.delete(@key)

      _ =
        Renderer.render_markdown(
          ~s|<Gallery motion="scroll" height="400">\n![a](https://h/1.jpg)\n</Gallery>|
        )

      assert Process.get(@key) == nil
    end
  end

  describe "style property names" do
    test "behavior and binding are refused without any url()" do
      refute Sanitizer.style_value_safe?("behavior:x")
      refute Sanitizer.style_value_safe?("color:red; behavior : x")
      refute Sanitizer.style_value_safe?("-moz-binding:x")
    end
  end

  describe "valueless attributes in code" do
    test "a code sample keeps every valueless media attribute as written" do
      html =
        Renderer.render_markdown(
          ~s|```html\n<video controls="" autoplay="" src="x"></video>\n```|
        )

      assert html =~ ~s|controls="" autoplay="" src="x"|
    end
  end
end
