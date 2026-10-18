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

      refute TextScan.dangerous?(doc),
             "generator produced a dangerous document (seed #{@seed}, doc #{n}): #{inspect(doc)}"

      html = render(doc)
      refute html =~ ~r/<script/i, failure(n, doc, html)
      refute html =~ ~r/\son[a-z]+\s*=/i, failure(n, doc, html)
      refute html =~ ~r/(javascript|vbscript|data):/i, failure(n, doc, html)

      for [_, url] <- Regex.scan(~r/(?:href|src)="([^"]*)"/i, html) do
        assert safe_url?(url), failure(n, doc, html) <> " url=" <> url
      end
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
    "word&nbsp;word"
  ]

  defp generate do
    1..(:rand.uniform(8) + 1) |> Enum.map_join("\n\n", fn _ -> Enum.random(@pieces) end)
  end
end
