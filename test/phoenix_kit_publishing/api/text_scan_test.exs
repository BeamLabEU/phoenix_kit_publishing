defmodule PhoenixKit.Modules.Publishing.API.TextScanTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.API.TextScan

  defp kinds(text),
    do: text |> TextScan.scan() |> Map.fetch!("findings") |> Enum.map(& &1["kind"])

  @dangerous [
    # html
    {"html", "a <script>alert(1)</script>"},
    {"html", "<SCRIPT >x"},
    {"html", ~s|<img src=x onerror=alert(1)>|},
    {"html", ~s(<a href="x">y</a>)},
    {"html", "text </div>"},
    {"html", "<!-- c -->"},
    {"html", "<!DOCTYPE html>"},
    {"html", "<?php echo 1 ?>"},
    {"html", ~s(<CTA action="x">)},
    {"html", ~s(<Image src="x"/>)},
    {"html", ~s(<Note note="x">)},
    {"html", "<Showcase"},
    {"html", "<https://h>"},
    {"html", "<javascript:alert(1)>"},
    {"html", "#<script>"},
    {"html", "```\n<script>x</script>\n```"},
    {"html", "````\n<b>\n````"},
    {"html", "    <b>indented code"},
    {"html", "inline `<b>` code"},
    {"html", "\\<b>"},
    {"html", "ends with <a"},
    {"html", ~s(# Decor<span class="text-primary">3D</span>print)},
    # post_link
    {"post_link", "[[post:00000000-0000-0000-0000-000000000000]]"},
    {"post_link", "[[POST:00000000-0000-0000-0000-000000000000|alias]]"},
    {"post_link", "prose [[post:x]] more"},
    {"post_link", "```\n[[post:x]]\n```"},
    # scheme
    {"scheme", "javascript:alert(1)"},
    {"scheme", "JavaScript:alert(1)"},
    {"scheme", "Java Script:alert(1)"},
    {"scheme", "java\tscript:alert(1)"},
    {"scheme", "java\nscript:alert(1)"},
    {"scheme", "java\u00A0script:alert(1)"},
    {"scheme", "java\u200Bscript:alert(1)"},
    {"scheme", "vbscript:x"},
    {"scheme", "data:text/html,x"},
    {"scheme", "DATA:x"},
    {"scheme", "see javascript: docs"},
    {"scheme", "metadata: pinned false positive"},
    # link_scheme
    {"link_scheme", "[x](ftp://h)"},
    {"link_scheme", "[x](sms:1)"},
    {"link_scheme", "[x](ssh://h)"},
    {"link_scheme", "![x](data:image/png;base64,AAAA)"},
    {"link_scheme", "[x][r]\n\n[r]: ftp://h"},
    {"link_scheme", "[x]( ftp://h)"},
    {"link_scheme", "[x](&#106;avascript:alert(1))"},
    {"link_scheme", "[x](&#x6A;avascript:alert(1))"},
    {"link_scheme", "[x](java&Tab;script:alert(1))"},
    {"link_scheme", "[x](javascript&colon;alert(1))"},
    {"link_scheme", "[x](jav\\ascript:alert(1))"},
    {"link_scheme", "[r]: &#106;avascript:alert(1)"},
    # autolink_scheme: the renderer autolinks a bare scheme://... of any scheme
    {"autolink_scheme", "ftp://evil.example/x"},
    {"autolink_scheme", "FTP://evil.example/x"},
    {"autolink_scheme", "file:///etc/passwd"},
    {"autolink_scheme", "intent://scan/#Intent;scheme=zxing;end"},
    {"autolink_scheme", "irc://x"},
    {"autolink_scheme", "ssh://x"},
    {"autolink_scheme", "git://x"},
    {"autolink_scheme", "chrome://settings"},
    {"autolink_scheme", "svn+ssh://h/p"},
    {"autolink_scheme", "1ftp://x"},
    {"autolink_scheme", "a_ftp://x"},
    {"autolink_scheme", "see (ftp://x) here"},
    {"autolink_scheme", "https://h/redirect?to=ftp://x"},
    {"autolink_scheme", "javascript://x%0aalert(1)"},
    {"autolink_scheme", "xmpp:a@b.c"},
    {"autolink_scheme", "XMPP:a@b.c"},
    {"autolink_scheme", "prose xmpp:a@b.c.d more"}
  ]

  @clean [
    "# Heading\n\n- a\n- b\n\n| a | b |\n|---|---|\n| 1 | 2 |",
    "- [ ] task\n- [x] done",
    "> quote\n\n*em* **strong** ~~gone~~",
    "text[^1]\n\n[^1]: note",
    "#hashtag and #another",
    "one = 1, a & b, A > B, 1 < 2, a <= b, <3",
    "&amp; and &lt;script&gt; as text",
    "a bare &#106;avascript: in prose",
    "[x](http://h/p) [x](https://h/p) [x](HTTPS://h)",
    "[x](mailto:a@b.c) [x](tel:+123)",
    "[x](/path) [x](//host/p) [x](#frag) [x](?a=1&b=2) [x](page.html) [x](../up) [x](a/b:c)",
    "![x](/file/uuid/large/ab12)",
    "see http://h/p and HTTPS://h/p and https://h/?next=https://other/x",
    "(https://h/paren) and +http://h/x",
    # not autolinked by the renderer (checked against it), so not flagged
    "Hours: 9-5. Note: sms:+123 skype:abc tel:+123 foo:bar ftp:/x ://h",
    "[x](https://h/p?a=1&b=2)",
    "[r]: https://h/p",
    ""
  ]

  describe "dangerous?/1 and scan/1" do
    for {kind, text} <- @dangerous do
      test "dangerous #{kind}: #{inspect(text)}" do
        text = unquote(text)
        assert TextScan.dangerous?(text)
        assert unquote(kind) in kinds(text)
        assert %{"dangerous" => true, "count" => count} = TextScan.scan(text)
        assert count >= 1
      end
    end

    for text <- @clean do
      test "clean: #{inspect(text)}" do
        text = unquote(text)
        refute TextScan.dangerous?(text)

        assert %{"dangerous" => false, "count" => 0, "truncated" => false, "findings" => []} =
                 TextScan.scan(text)
      end
    end

    test "a non-binary is dangerous (fail closed)" do
      for term <- [nil, 1, %{}, ["a"], :atom] do
        assert TextScan.dangerous?(term)
        assert [%{"kind" => "not_scanned"}] = TextScan.scan(term)["findings"]
      end
    end

    test "invalid UTF-8 does not crash and fragments stay valid UTF-8 (JSON-safe)" do
      text = "ok " <> <<0xFF, 0xFE>> <> " <b>bad"
      assert %{"findings" => [%{"fragment" => fragment}]} = TextScan.scan(text)
      assert String.valid?(fragment)
      assert {:ok, _} = Jason.encode(TextScan.scan(text))
      refute TextScan.dangerous?(<<0xFF, 0xFE, "plain">>)
    end

    test "a body over 2,097,152 bytes is not scanned and counts as dangerous" do
      text = String.duplicate("a", 2_097_153)
      assert TextScan.dangerous?(text)
      assert [%{"kind" => "not_scanned", "line" => 1}] = TextScan.scan(text)["findings"]
    end
  end

  describe "findings" do
    test "line numbers: first line, last line, after 1,000 lines, after CRLF" do
      assert [%{"line" => 1}] = TextScan.scan("<b>x")["findings"]
      assert [%{"line" => 3}] = TextScan.scan("a\nb\n<b>")["findings"]
      text = String.duplicate("line\n", 1000) <> "<b>"
      assert [%{"line" => 1001}] = TextScan.scan(text)["findings"]
      assert [%{"line" => 3}] = TextScan.scan("a\r\nb\r\n<b>")["findings"]
    end

    test "the line of a scheme match is the line of its first kept character" do
      assert [%{"kind" => "scheme", "line" => 2}] =
               TextScan.scan("a\njava\u200Bscript:x")["findings"]
    end

    test "fragment: from the match to the end of its line, 80 characters, control characters escaped" do
      long = "<b>" <> String.duplicate("x", 200)
      assert [%{"fragment" => fragment}] = TextScan.scan(long)["findings"]
      assert String.length(fragment) == 80
      assert String.starts_with?(fragment, "<b>x")

      assert [%{"fragment" => f}] = TextScan.scan("<b>a\u0001b\nnext line")["findings"]
      assert f == "<b>a\\x01b"
    end

    test "at most 20 findings, true count, truncated, text order" do
      text = Enum.map_join(1..30, "\n", fn i -> "<b#{i}>" end)
      scan = TextScan.scan(text)
      assert scan["count"] == 30
      assert scan["truncated"] == true
      assert length(scan["findings"]) == 20
      assert Enum.map(scan["findings"], & &1["line"]) == Enum.to_list(1..20)
    end

    test "findings of different rules come back in text order" do
      text = "javascript:x\n<b>\n[[post:1]]"

      assert Enum.map(TextScan.scan(text)["findings"], & &1["kind"]) == [
               "scheme",
               "html",
               "post_link"
             ]
    end
  end

  describe "size and cost" do
    @size 262_144
    defp pad(unit),
      do: unit |> String.duplicate(div(@size, byte_size(unit)) + 1) |> binary_part(0, @size)

    defp timed(text) do
      {us, _} = :timer.tc(fn -> TextScan.scan(text) end)
      us
    end

    test "every worst-case 262,144-byte input scans in under 100 ms" do
      inputs = %{
        "all <" => pad("<"),
        "<a repeated" => pad("<a"),
        "[ repeated" => pad("["),
        "]( repeated" => pad("]("),
        "]( then a long run" => "](" <> String.duplicate("a", @size - 2),
        "]: repeated" => pad("]:"),
        "whitespace only" => pad(" "),
        "java then spaces" => "java" <> String.duplicate(" ", @size - 4),
        ": repeated" => pad(":"),
        "& and backslash" => pad("&\\"),
        "one long line" => pad("word "),
        "://  repeated" => pad("://"),
        "a:// repeated" => pad("a://"),
        "scheme chars then ://" => binary_part(pad("a1+.-"), 0, @size - 3) <> "://",
        "scheme chars only" => pad("a1+.-"),
        "xmpp: repeated" => pad("xmpp:")
      }

      for {name, text} <- inputs do
        assert byte_size(text) == @size, name
        assert timed(text) < 100_000, "#{name} took #{timed(text)} us"
      end
    end
  end

  test "max_body_bytes is 262,144" do
    assert TextScan.max_body_bytes() == 262_144
  end
end
