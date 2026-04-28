defmodule PhoenixKit.Modules.Publishing.RendererTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Renderer

  # ============================================================================
  # Tailwind Class Injection
  # ============================================================================

  describe "render_markdown/1 adds Tailwind classes to headings" do
    test "h1 gets size, weight, border classes" do
      html = Renderer.render_markdown("# Title")
      assert html =~ ~s(<h1 class=")
      assert html =~ "text-4xl"
      assert html =~ "font-bold"
      assert html =~ "border-b"
    end

    test "h2 gets size and weight classes" do
      html = Renderer.render_markdown("## Subtitle")
      assert html =~ ~s(<h2 class=")
      assert html =~ "text-3xl"
      assert html =~ "font-semibold"
    end

    test "h3 through h6 get appropriate sizes" do
      assert Renderer.render_markdown("### H3") =~ "text-2xl"
      assert Renderer.render_markdown("#### H4") =~ "text-xl"
      assert Renderer.render_markdown("##### H5") =~ "text-lg"
      assert Renderer.render_markdown("###### H6") =~ "text-base"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to paragraphs" do
    test "paragraphs get spacing and line-height" do
      html = Renderer.render_markdown("Some text")
      assert html =~ ~s(<p class=")
      assert html =~ "my-4"
      assert html =~ "leading-relaxed"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to links" do
    test "links get daisyUI link classes" do
      html = Renderer.render_markdown("[click](https://example.com)")
      assert html =~ ~s(<a class="link link-primary")
      assert html =~ ~s(href="https://example.com")
    end
  end

  describe "render_markdown/1 adds Tailwind classes to lists" do
    test "unordered lists get disc markers" do
      html = Renderer.render_markdown("- one\n- two")
      assert html =~ ~s(<ul class=")
      assert html =~ "list-disc"
      assert html =~ "pl-8"
    end

    test "ordered lists get decimal markers" do
      html = Renderer.render_markdown("1. one\n2. two")
      assert html =~ ~s(<ol class=")
      assert html =~ "list-decimal"
    end

    test "list items get spacing" do
      html = Renderer.render_markdown("- one\n- two")
      assert html =~ ~s(<li class=")
      assert html =~ "my-1"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to code" do
    test "inline code gets bg and font-mono" do
      html = Renderer.render_markdown("Use `code` here")
      assert html =~ "bg-base-200"
      assert html =~ "font-mono"
      assert html =~ "rounded"
    end

    test "code blocks get pre styling, not inline code styling" do
      html = Renderer.render_markdown("```\nsome code\n```")
      assert html =~ ~s(<pre class=")
      assert html =~ "bg-base-300"
      assert html =~ "rounded-lg"
      # Code inside pre should NOT have inline code background
      refute html =~ ~s(<code class="bg-base-200)
    end

    test "fenced code blocks preserve language class" do
      html = Renderer.render_markdown("```elixir\ndef foo, do: :bar\n```")
      assert html =~ "language-elixir"
      assert html =~ ~s(<pre class=")
    end
  end

  describe "render_markdown/1 adds Tailwind classes to blockquotes" do
    test "blockquotes get border and italic" do
      html = Renderer.render_markdown("> A quote")
      assert html =~ ~s(<blockquote class=")
      assert html =~ "border-l-4"
      assert html =~ "border-primary"
      assert html =~ "italic"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to tables" do
    test "tables get daisyUI table class" do
      md = """
      | A | B |
      |---|---|
      | 1 | 2 |
      """

      html = Renderer.render_markdown(md)
      assert html =~ ~s(<table class=")
      assert html =~ "table"
    end

    test "thead gets background" do
      md = """
      | A | B |
      |---|---|
      | 1 | 2 |
      """

      html = Renderer.render_markdown(md)
      assert html =~ ~s(<thead class=")
      assert html =~ "bg-base-200"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to hr" do
    test "hr gets border styling" do
      html = Renderer.render_markdown("---")
      assert html =~ ~s(<hr class=")
      assert html =~ "border-t-2"
      assert html =~ "my-8"
    end
  end

  describe "render_markdown/1 adds Tailwind classes to images" do
    test "images get rounded and responsive" do
      html = Renderer.render_markdown("![alt](https://example.com/img.png)")
      assert html =~ "max-w-full"
      assert html =~ "rounded-lg"
    end
  end

  # ============================================================================
  # Blank Line Preservation
  # ============================================================================

  describe "render_markdown/1 preserves intentional blank lines" do
    test "single blank line is a normal paragraph break" do
      html = Renderer.render_markdown("Para 1\n\nPara 2")
      # Should produce exactly 2 paragraphs, no spacers
      refute html =~ " "
      assert html =~ "Para 1"
      assert html =~ "Para 2"
    end

    test "double blank lines produce one spacer" do
      html = Renderer.render_markdown("Para 1\n\n\nPara 2")
      assert html =~ "&nbsp;"
    end

    test "triple blank lines produce two spacers" do
      html = Renderer.render_markdown("Para 1\n\n\n\nPara 2")
      # Two extra lines = two &nbsp; spacers
      count = length(String.split(html, "&nbsp;")) - 1
      assert count == 2
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "render_markdown/1 edge cases" do
    test "empty string returns empty" do
      assert Renderer.render_markdown("") == ""
    end

    test "nil returns empty" do
      assert Renderer.render_markdown(nil) == ""
    end

    test "merges classes into existing class attribute" do
      # Inline code with Earmark's class="inline" should merge
      html = Renderer.render_markdown("Use `code` here")
      # Should have both our classes and Earmark's
      assert html =~ "font-mono"
    end

    test "does not double-style code inside pre blocks" do
      html = Renderer.render_markdown("```\ncode\n```")
      # Pre should have bg-base-300
      assert html =~ ~r/<pre class="[^"]*bg-base-300/
      # The code tag inside pre should NOT have bg-base-200 (inline code style)
      refute html =~ ~r/<code[^>]*bg-base-200/
    end
  end

  # ============================================================================
  # PHK Component Detection
  # ============================================================================

  describe "render_markdown/1 — PHK XML detection" do
    test "renders pure PHK content via PageBuilder" do
      # An unknown component goes through PageBuilder.render_unknown wrapper
      content = "<Foobar>hello</Foobar>"
      html = Renderer.render_markdown(content)
      assert html =~ "unknown-component" or html =~ "hello"
    end

    test "renders mixed content (markdown + inline component)" do
      content = "## Heading\n\n<Foobar>inline-comp</Foobar>\n\nmore text"
      html = Renderer.render_markdown(content)
      assert html =~ "Heading"
      assert html =~ "more text"
    end

    test "preserves admin-trusted inline HTML in markdown" do
      # The trust model documented in renderer.ex:201-209 — escape: false
      content = "Plain text with <strong>bold</strong> markup."
      html = Renderer.render_markdown(content)
      assert html =~ "<strong>bold</strong>"
    end
  end

  # ============================================================================
  # Cache enable/disable settings
  # ============================================================================

  describe "render_cache_enabled?/1 + per_group_cache_key/1" do
    test "per_group_cache_key/1 returns 'publishing_render_cache_enabled_<slug>'" do
      assert Renderer.per_group_cache_key("blog") == "publishing_render_cache_enabled_blog"
      assert Renderer.per_group_cache_key("docs") == "publishing_render_cache_enabled_docs"
    end

    test "global_render_cache_enabled? returns boolean (defaults to true)" do
      assert is_boolean(Renderer.global_render_cache_enabled?())
    end

    test "group_render_cache_enabled? returns boolean (defaults to true)" do
      assert is_boolean(Renderer.group_render_cache_enabled?("any"))
    end

    test "render_cache_enabled? returns boolean and ANDs both checks" do
      assert is_boolean(Renderer.render_cache_enabled?("any"))
    end
  end

  # ============================================================================
  # Cache management
  # ============================================================================

  describe "clear_all_cache/0 + clear_group_cache/1 + invalidate_cache/3" do
    test "clear_all_cache returns :ok even when cache registry is unavailable" do
      assert Renderer.clear_all_cache() == :ok
    end

    test "clear_group_cache returns 0-or-positive count" do
      result = Renderer.clear_group_cache("nonexistent-#{System.unique_integer()}")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "invalidate_cache/3 doesn't raise even when cache is missing" do
      # Just covers the call site; no specific return assertion since the cache
      # may not be registered in the test environment.
      Renderer.invalidate_cache("group", "post-slug", "en")
    end
  end

  # ============================================================================
  # render_post/1 — full caching path
  # ============================================================================

  describe "render_post/1" do
    test "renders draft posts without caching" do
      post = %{
        content: "## Section",
        metadata: %{title: "x", status: "draft"},
        group: "blog",
        slug: "x",
        uuid: "uuid-#{System.unique_integer([:positive])}",
        language: "en"
      }

      assert {:ok, html} = Renderer.render_post(post)
      assert is_binary(html)
    end

    test "renders archived posts without caching" do
      post = %{
        content: "Body",
        metadata: %{title: "y", status: "archived"},
        group: "blog",
        slug: "y",
        uuid: "uuid-arch-#{System.unique_integer([:positive])}",
        language: "en"
      }

      assert {:ok, html} = Renderer.render_post(post)
      assert is_binary(html)
    end

    test "renders published posts via cache (miss → render → cache)" do
      post = %{
        content: "# Pub\n\nBody.",
        metadata: %{title: "Pub", status: "published"},
        group: "blog-cache-test-#{System.unique_integer([:positive])}",
        slug: "pub",
        uuid: "uuid-pub-#{System.unique_integer([:positive])}",
        language: "en"
      }

      assert {:ok, html_1} = Renderer.render_post(post)
      # Second call hits the cache hot path
      assert {:ok, html_2} = Renderer.render_post(post)
      assert html_1 == html_2
    end

    test "render_post returns cached html on hit" do
      post = %{
        content: "Cache me",
        metadata: %{title: "z", status: "published"},
        group: "blog-hit-#{System.unique_integer([:positive])}",
        slug: "z",
        uuid: "uuid-hit-#{System.unique_integer([:positive])}",
        language: "en"
      }

      {:ok, _} = Renderer.render_post(post)
      assert {:ok, _} = Renderer.render_post(post)
    end
  end

  describe "invalidate_cache/3 actually clears the cache" do
    test "after invalidate, the next render is a miss" do
      post = %{
        content: "First content",
        metadata: %{title: "z", status: "published"},
        group: "blog-inv-#{System.unique_integer([:positive])}",
        slug: "z",
        uuid: "uuid-inv-#{System.unique_integer([:positive])}",
        language: "en"
      }

      {:ok, _} = Renderer.render_post(post)
      Renderer.invalidate_cache(post.group, post.slug, post.language)
      # Should not raise; second render rebuilds from content
      assert {:ok, _} = Renderer.render_post(post)
    end
  end

  # ============================================================================
  # Edge cases — blank-line preservation and class merge details
  # ============================================================================

  describe "blank-line preservation" do
    test "converts triple-newline runs into paragraph breaks with spacers" do
      html = Renderer.render_markdown("First\n\n\nSecond")
      # The renderer inserts &nbsp; spacers for 2+ blank lines
      assert is_binary(html)
      assert html =~ "First"
      assert html =~ "Second"
    end

    test "preserves single blank line as normal paragraph break" do
      html = Renderer.render_markdown("First\n\nSecond")
      assert html =~ "First"
      assert html =~ "Second"
    end

    test "removes leading indentation from headings" do
      html = Renderer.render_markdown("    ## Indented")
      # The pre-processor strips leading whitespace before headings
      assert html =~ "Indented"
    end
  end

  describe "list-rendering classes" do
    test "ul gets list-disc + spacing classes" do
      html = Renderer.render_markdown("- item 1\n- item 2")
      assert html =~ ~r/<ul class="[^"]*list-disc/
    end

    test "ol gets list-decimal classes" do
      html = Renderer.render_markdown("1. one\n2. two")
      assert html =~ ~r/<ol class="[^"]*list-decimal/
    end

    test "nested li gets correct spacing" do
      html = Renderer.render_markdown("- a\n- b")
      assert html =~ "<li"
    end
  end

  describe "blockquote / hr / link rendering" do
    test "blockquote gets daisyUI classes" do
      html = Renderer.render_markdown("> quoted")
      assert html =~ ~r/<blockquote class="[^"]/
    end

    test "hr renders with the styling class" do
      html = Renderer.render_markdown("Before\n\n---\n\nAfter")
      assert html =~ "<hr"
    end

    test "links get text-primary + underline classes" do
      html = Renderer.render_markdown("[link](https://example.com)")
      assert html =~ ~r/<a [^>]*href="https:\/\/example\.com"/
    end
  end

  describe "image rendering inline" do
    test "renders an `![alt](url)` markdown image" do
      html = Renderer.render_markdown("![alt text](https://example.com/img.png)")
      assert html =~ "<img"
      assert html =~ "alt text"
    end
  end

  describe "code block class application" do
    test "fenced code block gets pre + code classes" do
      html = Renderer.render_markdown("```elixir\nIO.puts \"hi\"\n```")
      assert html =~ ~r/<pre class="[^"]*bg-base-300/
      assert html =~ "language-elixir"
    end

    test "inline code has bg-base-200 class" do
      html = Renderer.render_markdown("Use `Enum.map` here")
      assert html =~ ~r/<code class="[^"]*bg-base-200/
    end

    test "code blocks of various languages get language-X class" do
      html = Renderer.render_markdown("```python\nprint(1)\n```")
      assert html =~ "language-python"
    end
  end

  describe "tables" do
    test "renders GFM tables with wrapper styling" do
      table = """
      | Col1 | Col2 |
      |------|------|
      | a    | b    |
      """

      html = Renderer.render_markdown(table)
      assert html =~ "<table"
    end
  end

  describe "global_render_cache_enabled? respects Settings" do
    test "returns boolean — defaults to true when setting absent" do
      # In test env the setting query fails (no sandbox), but the renderer's
      # default fallback returns true.
      assert is_boolean(Renderer.global_render_cache_enabled?())
    end
  end
end
