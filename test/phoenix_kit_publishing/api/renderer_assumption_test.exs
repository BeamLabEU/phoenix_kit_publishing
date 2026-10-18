defmodule PhoenixKit.Modules.Publishing.API.RendererAssumptionTest do
  # Tests the assumption of spec §14.2, it does not prove it. A failure is a bug in the rule.
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.API.TextScan
  alias PhoenixKit.Modules.Publishing.Renderer

  @documents 10_000
  @seed 20_261_018

  test "markdown without a '<' renders no script, no event attribute and no active URL" do
    :rand.seed(:exsss, {@seed, @seed, @seed})

    for n <- 1..@documents do
      doc = generate()
      refute String.contains?(doc, "<"), "generator bug (seed #{@seed}, doc #{n})"

      if TextScan.dangerous?(doc) do
        flunk(
          "generator produced a dangerous document (seed #{@seed}, doc #{n}): #{inspect(doc)}"
        )
      end

      html = render(doc)
      check_html(n, doc, html)
    end
  end

  # The messages are built only when an assertion fails.
  defp check_html(n, doc, html) do
    if html =~ ~r/<script/i, do: flunk("<script in output. " <> failure(n, doc, html))

    if html =~ ~r/\son[a-z]+\s*=/i,
      do: flunk("event attribute in output. " <> failure(n, doc, html))

    # Deliberately strict: it matches the scheme words anywhere in the output, not only in
    # a URL, so a piece must never put them in plain text (e.g. "metadata:").
    if html =~ ~r/(javascript|vbscript|data):/i,
      do: flunk("active scheme in output. " <> failure(n, doc, html))

    for [_, url] <- Regex.scan(~r/(?:href|src)="([^"]*)"/i, html) do
      if not safe_url?(url), do: flunk("unsafe url=" <> url <> ". " <> failure(n, doc, html))
    end
  end

  defp safe_url?(url) do
    case String.split(url, ":", parts: 2) do
      [_only] ->
        true

      [scheme, _] ->
        String.downcase(scheme) in ~w(http https mailto tel) or
          String.contains?(scheme, ["/", "?", "#"])
    end
  end

  defp failure(n, doc, html),
    do: "seed #{@seed} doc #{n}\nINPUT: #{inspect(doc)}\nOUTPUT: #{inspect(html)}"

  defp render(doc), do: Renderer.render_markdown(doc, [])

  @pieces [
    "# Heading",
    "## Sub *heading*",
    "- item\n- item two",
    "1. one\n2. two",
    "  - nested\n    - deeper",
    "- [ ] todo\n- [x] done",
    "| a | b |\n|---|---|\n| 1 | 2 |",
    "> quote\n> more",
    "text with *em* and **strong** and ~~del~~",
    "term[^1]\n\n[^1]: the note",
    "#hashtag #another_tag",
    "&amp; &#106;avascript &#x6A;ava &lt;script&gt; &colon; &Tab;",
    "\\* \\[ \\] \\\\ \\&",
    "[ref]: https://example.com\n[ref2]: /path\n[mail]: mailto:a@b.c",
    "[text][ref] and [other][ref2] and [mail][mail]",
    "[inline](https://h/p?a=1&b=2) ![img](/file/uuid/large/ab12)",
    "www.example.com and https://example.com/x and user@example.com",
    "`code span` and ``double `tick` span``",
    "```\nfenced code\n```",
    "~~~\ntilde fence\n~~~",
    "    indented code",
    "---",
    "***",
    "Hard  \nbreak",
    "word&nbsp;word",
    "[c]: mailto:x@y.z\n[c2]: tel:+123456789",
    "[call](tel:+123456789) and [mailto](mailto:a@b.c) and [c]",
    "[proto](//example.com/x) and [rel](../up/x.md) and [frag](#anchor)",
    "para text\n[adj]: https://example.com/adj\n[adj]",
    "[amp](https://h/?a=1&amp;b=2) and [dec](https://h/&#47;x)",
    "![alt](https://h/i.png \"title\") [t](/p 'title')",
    "https://h/p?a=1&b=2#frag, www.example.com/p. (https://h/paren)",
    "1) paren list\n2) second",
    "+ plus\n+ list\n\n* star\n* list",
    "Setext\n======\n\nSub\n---",
    "- a\n\n  para in item\n\n  > quote in item\n\n      code in item",
    "| a |\n|:-:|\n| `x \\| y` |",
    "\u00e9\u00fc \u4e2d\u6587 \u{1F600} \u200b zero width"
  ]

  # No brackets, parentheses or colons: junk must not form a link or a definition by itself
  # (the rule rejects those fail-closed), but it may sit next to the pieces that do.
  @junk_chars ~c"abcXYZ 019!@#$%^&*_+-={};'\",.>?/\\|~`\t"

  defp junk do
    count = :rand.uniform(30)
    for _ <- 1..count, into: "", do: <<Enum.random(@junk_chars)>>
  end

  defp piece do
    case :rand.uniform(10) do
      1 -> junk()
      2 -> Enum.random(@pieces) <> " " <> junk()
      _ -> Enum.random(@pieces)
    end
  end

  defp separator, do: Enum.random(["\n\n", "\n", " ", "\n\n\n"])

  defp generate do
    count = :rand.uniform(8) + 1

    1..count
    |> Enum.map(fn _ -> piece() end)
    |> Enum.reduce(fn next, acc -> acc <> separator() <> next end)
  end
end
