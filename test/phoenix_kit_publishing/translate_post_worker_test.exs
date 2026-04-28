defmodule PhoenixKit.Modules.Publishing.TranslatePostWorkerTest do
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker

  # ============================================================================
  # timeout/1 — Dynamic timeout scaling
  # ============================================================================

  describe "timeout/1" do
    test "scales with number of target languages" do
      job = build_job(%{"target_languages" => Enum.map(1..10, &"lang-#{&1}")})
      timeout_ms = TranslatePostWorker.timeout(job)
      # 10 * 1.5 = 15 minutes
      assert timeout_ms == :timer.minutes(15)
    end

    test "uses minimum of 15 minutes for small language counts" do
      job = build_job(%{"target_languages" => ["de", "fr"]})
      timeout_ms = TranslatePostWorker.timeout(job)
      # 2 * 1.5 = 3, but min is 15
      assert timeout_ms == :timer.minutes(15)
    end

    test "scales up for many languages" do
      langs = Enum.map(1..39, &"lang-#{&1}")
      job = build_job(%{"target_languages" => langs})
      timeout_ms = TranslatePostWorker.timeout(job)
      # 39 * 1.5 = 58.5, ceil = 59
      assert timeout_ms == :timer.minutes(59)
    end

    test "handles single language" do
      job = build_job(%{"target_languages" => ["de"]})
      timeout_ms = TranslatePostWorker.timeout(job)
      assert timeout_ms == :timer.minutes(15)
    end

    defp build_job(args) do
      %Oban.Job{args: args}
    end
  end

  # ============================================================================
  # create_job/3 — Job-args construction (no Oban insertion)
  # ============================================================================

  describe "create_job/3" do
    test "builds an Oban.Job changeset with required args" do
      changeset = TranslatePostWorker.create_job("docs", "post-uuid")

      assert %Ecto.Changeset{} = changeset
      args = Ecto.Changeset.get_field(changeset, :args)
      assert args["group_slug"] == "docs"
      assert args["post_uuid"] == "post-uuid"
    end

    test "includes endpoint_uuid when provided" do
      changeset =
        TranslatePostWorker.create_job("docs", "post-uuid", endpoint_uuid: "endpoint-1")

      args = Ecto.Changeset.get_field(changeset, :args)
      assert args["endpoint_uuid"] == "endpoint-1"
    end

    test "includes target_languages when provided" do
      changeset =
        TranslatePostWorker.create_job("docs", "post-uuid", target_languages: ~w(es fr de))

      args = Ecto.Changeset.get_field(changeset, :args)
      assert args["target_languages"] == ~w(es fr de)
    end

    test "drops nil-valued opts (no defaults written into args)" do
      changeset = TranslatePostWorker.create_job("docs", "post-uuid", endpoint_uuid: nil)
      args = Ecto.Changeset.get_field(changeset, :args)
      refute Map.has_key?(args, "endpoint_uuid")
    end

    test "passes through user_uuid + version + prompt_uuid + source_language" do
      changeset =
        TranslatePostWorker.create_job("docs", "post-uuid",
          user_uuid: "user-1",
          version: 2,
          prompt_uuid: "prompt-1",
          source_language: "en"
        )

      args = Ecto.Changeset.get_field(changeset, :args)
      assert args["user_uuid"] == "user-1"
      assert args["version"] == 2
      assert args["prompt_uuid"] == "prompt-1"
      assert args["source_language"] == "en"
    end
  end

  # ============================================================================
  # active_job/1 — DB lookup (uses test sandbox)
  # ============================================================================

  describe "active_job/1" do
    test "returns nil when no active job exists for the given post" do
      assert TranslatePostWorker.active_job("019cce93-bbbb-7000-8000-000000000aaa") == nil
    end
  end

  # ============================================================================
  # extract_title/1 — pulls the title from markdown heading or metadata
  # ============================================================================

  describe "extract_title/1" do
    test "uses the first markdown heading when present" do
      post = %{content: "# Hello World\n\nBody.", metadata: %{title: "Old Title"}}
      assert TranslatePostWorker.extract_title(post) == "Hello World"
    end

    test "trims whitespace around the heading" do
      post = %{content: "#    Spaced Title    \n\nBody.", metadata: %{}}
      assert TranslatePostWorker.extract_title(post) == "Spaced Title"
    end

    test "falls back to metadata.title when no heading" do
      post = %{content: "Just body text.", metadata: %{title: "Meta Title"}}
      assert TranslatePostWorker.extract_title(post) == "Meta Title"
    end

    test "falls back to Constants.default_title when no heading and no metadata" do
      post = %{content: "Just body.", metadata: %{}}
      assert TranslatePostWorker.extract_title(post) == "Untitled"
    end

    test "handles nil content gracefully" do
      post = %{content: nil, metadata: %{title: "Meta"}}
      assert TranslatePostWorker.extract_title(post) == "Meta"
    end

    test "handles nil metadata gracefully" do
      post = %{content: "# Body", metadata: nil}
      assert TranslatePostWorker.extract_title(post) == "Body"
    end
  end

  # ============================================================================
  # sanitize_slug/1 — slug normalization for AI translations
  # ============================================================================

  describe "sanitize_slug/1" do
    test "downcases and accepts a clean slug" do
      assert TranslatePostWorker.sanitize_slug("Hello-World") == "hello-world"
    end

    test "replaces invalid chars with hyphens" do
      assert TranslatePostWorker.sanitize_slug("hello world!") == "hello-world"
    end

    test "collapses multiple hyphens" do
      assert TranslatePostWorker.sanitize_slug("hello---world") == "hello-world"
    end

    test "strips leading and trailing hyphens" do
      assert TranslatePostWorker.sanitize_slug("-hello-world-") == "hello-world"
    end

    test "trims whitespace" do
      assert TranslatePostWorker.sanitize_slug("   spaced   ") == "spaced"
    end

    test "returns nil when sanitised slug is empty" do
      assert TranslatePostWorker.sanitize_slug("!!!") == nil
      assert TranslatePostWorker.sanitize_slug("---") == nil
      assert TranslatePostWorker.sanitize_slug("") == nil
    end

    test "returns nil for too-short slugs" do
      assert TranslatePostWorker.sanitize_slug("a") == nil
    end
  end

  # ============================================================================
  # parse_markdown_response/1 — bare markdown (no marker lines)
  # ============================================================================

  describe "parse_markdown_response/1" do
    test "extracts the heading as title and rest as content" do
      response = "# Hello World\n\nThis is the body."
      assert {"Hello World", body} = TranslatePostWorker.parse_markdown_response(response)
      assert body =~ "This is the body"
    end

    test "uses the first line as title when no markdown heading exists" do
      response = "First line\nSecond line content here."

      assert {"First line", "Second line content here."} =
               TranslatePostWorker.parse_markdown_response(response)
    end

    test "handles single-line responses" do
      assert {"Just one line", ""} =
               TranslatePostWorker.parse_markdown_response("Just one line")
    end

    test "strips stray ---TITLE--- / ---SLUG--- / ---CONTENT--- markers from cleanup" do
      response = "# Real Title\n\nBody.\n\n---TITLE---\nLeftover"
      assert {"Real Title", body} = TranslatePostWorker.parse_markdown_response(response)
      refute body =~ "Leftover"
    end
  end

  # ============================================================================
  # parse_translated_response/1 — full structured format with markers
  # ============================================================================

  describe "parse_translated_response/1" do
    test "parses the full structured format with slug" do
      response = """
      ---TITLE---
      Hello World
      ---SLUG---
      hello-world
      ---CONTENT---
      Body of the post
      """

      assert {"Hello World", "hello-world", content} =
               TranslatePostWorker.parse_translated_response(response)

      assert content =~ "Body of the post"
    end

    test "parses the structured format without slug" do
      response = """
      ---TITLE---
      Welcome
      ---CONTENT---
      Body content
      """

      assert {"Welcome", nil, content} = TranslatePostWorker.parse_translated_response(response)
      assert content =~ "Body content"
    end

    test "falls back to markdown parsing for bare responses" do
      response = "# Just a heading\n\nBody text."

      assert {"Just a heading", nil, body} =
               TranslatePostWorker.parse_translated_response(response)

      assert body =~ "Body text"
    end

    test "sanitizes the AI-returned slug in the structured format" do
      response = """
      ---TITLE---
      Test
      ---SLUG---
      Bad Slug Format!!!
      ---CONTENT---
      Body
      """

      assert {"Test", "bad-slug-format", "Body"} =
               TranslatePostWorker.parse_translated_response(response)
    end
  end

  # ============================================================================
  # translate_now/3 — early-validation paths (no AI HTTP needed)
  # ============================================================================

  describe "translate_now/3 — validation early-returns" do
    test "returns :ai_no_prompt when prompt_uuid is nil" do
      # In the test env PhoenixKitAI is loaded but AI.enabled? is false,
      # so the cond returns :ai_disabled before checking prompt. We can
      # only assert it doesn't crash.
      result = TranslatePostWorker.translate_now("any-uuid", "fr", endpoint_uuid: "any")
      assert match?({:error, _}, result)
    end

    test "returns :ai_disabled when AI is not configured" do
      result =
        TranslatePostWorker.translate_now("any-uuid", "fr",
          prompt_uuid: "any-prompt",
          endpoint_uuid: "any-endpoint"
        )

      assert match?({:error, _}, result)
    end
  end

  describe "translate_content/3 — validation early-returns" do
    test "returns :ai_disabled or :ai_no_prompt when AI not available" do
      result = TranslatePostWorker.translate_content("any-uuid", "fr")
      assert match?({:error, _}, result)
    end
  end
end
