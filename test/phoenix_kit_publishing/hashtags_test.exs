defmodule PhoenixKit.Modules.Publishing.HashtagsTest do
  @moduledoc """
  Pins the hashtag tag system (boss call 2026-07-28): tags live in the body
  as `#hashtags` — extraction rules, save-time derivation across languages,
  and public rendering as tag-archive links.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Hashtags
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Versions

  defp unique_name, do: "ht-#{System.unique_integer([:positive])}"

  describe "extract/1" do
    test "finds hashtags after whitespace, line start, and parens" do
      assert Hashtags.extract("#lead mid #two (#three)\n#four") ==
               ["lead", "two", "three", "four"]
    end

    test "ignores markdown headings, URL fragments, and code" do
      content = """
      # A Heading

      See https://example.com/page#section and `#not-a-tag` inline.

      ```
      #also-not-a-tag
      ```

      But #real counts.
      """

      assert Hashtags.extract(content) == ["real"]
    end

    test "unicode tags, case-insensitive dedup keeping the first spelling" do
      assert Hashtags.extract("#Uudised #uudised #новости") == ["Uudised", "новости"]
    end

    test "hyphens/underscores/digits continue a tag; punctuation ends it" do
      assert Hashtags.extract("#how-to_2 works, #tag. done") == ["how-to_2", "tag"]
    end

    test "words longer than 30 chars are not tags at all (no half-match)" do
      long = "#" <> String.duplicate("a", 31)
      assert Hashtags.extract("pre #{long} post #ok") == ["ok"]
    end

    test "markdown links are masked: anchors and link text don't tag" do
      content = "See [jump](#section) and [read about #elixir](https://x.com), then #real."
      assert Hashtags.extract(content) == ["real"]
    end

    test "PHK component attributes and block bodies are masked" do
      content = """
      <Image src="x.jpg" alt="see #elixir here" />

      <Video url="https://y.tube">Caption with #hidden inside</Video>

      Prose #real stays.
      """

      assert Hashtags.extract(content) == ["real"]
    end

    test "an unclosed code fence masks everything after it" do
      assert Hashtags.extract("#before\n```\n#inside never closes") == ["before"]
    end
  end

  describe "normalize/1" do
    test "trims, strips leading #, drops blanks/non-strings, dedups, caps" do
      assert Hashtags.normalize([" #Elixir ", "elixir", "", "  ", nil, 42, "otp"]) ==
               ["Elixir", "otp"]

      overlong = Enum.map(1..25, &"tag#{&1}")
      assert length(Hashtags.normalize(overlong)) == 20
    end

    test "non-list input normalizes to empty" do
      assert Hashtags.normalize("not-a-list") == []
    end
  end

  describe "save-time derivation" do
    setup do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      slug = group["slug"]

      {:ok, post} =
        Posts.create_post(slug, %{
          title: "Tagged",
          slug: "tagged",
          content: "Intro #elixir and #phoenix."
        })

      :ok = Versions.publish_version(slug, post.uuid, 1)
      %{slug: slug, post: post}
    end

    test "a content save re-derives tags from the body", %{slug: slug, post: post} do
      {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)

      {:ok, updated} =
        Posts.update_post(slug, read, %{"content" => "Now only #otp here."}, %{})

      assert updated.metadata.tags == ["otp"]
    end

    test "tags union across the version's languages", %{slug: slug, post: post} do
      {:ok, _} = Publishing.add_language_to_post(slug, post.uuid, "et", 1)
      {:ok, et_read} = Publishing.read_post_by_uuid(post.uuid, "et", 1)

      {:ok, updated} =
        Posts.update_post(
          slug,
          et_read,
          %{"title" => "Sildistatud", "content" => "Sisu #uudised ja #elixir."},
          %{}
        )

      # The et save re-derives the union over en (#elixir #phoenix) + et.
      assert Enum.sort(updated.metadata.tags) == ["elixir", "phoenix", "uudised"]
    end

    test "an explicit tags list without content is still honored and normalized", %{
      slug: slug,
      post: post
    } do
      {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)

      {:ok, updated} =
        Posts.update_post(slug, read, %{"tags" => [" #Manual ", "manual", ""]}, %{})

      assert updated.metadata.tags == ["Manual"]
    end
  end

  describe "rendering" do
    test "hashtags render as tag-archive links; code and notes stay plain" do
      html =
        Renderer.render_markdown(
          """
          Learn #elixir today. `#code` stays. <Note note="see #hidden">a phrase #inline</Note>

          ```
          #fenced
          ```
          """,
          tag_links: {"blog", "en"}
        )

      assert html =~ ~s(/blog/tag/elixir")
      assert html =~ ">#elixir</a>"
      refute html =~ ~s(/blog/tag/code)
      refute html =~ ~s(/blog/tag/fenced)
      # A tag mentioned inside a note (attribute or phrase) never becomes markup.
      refute html =~ ~s(/blog/tag/hidden)
      refute html =~ ~s(/blog/tag/inline)
    end

    test "without tag context, hashtags render as plain text" do
      html = Renderer.render_markdown("Just #plain here.")
      refute html =~ "/tag/"
      assert html =~ "#plain"
    end

    test "existing markdown links survive linkify unchanged" do
      html =
        Renderer.render_markdown(
          "Jump [to details](#details) or [read about #elixir](https://x.com). #real",
          tag_links: {"blog", "en"}
        )

      # The anchor link and the tag-in-link-text stay as the author wrote them.
      assert html =~ ~s(href="#details")
      assert html =~ ~s(href="https://x.com")
      refute html =~ ~s(/blog/tag/details)
      refute html =~ ~s(/blog/tag/elixir")
      # Prose hashtags still link.
      assert html =~ ~s(/blog/tag/real)
    end
  end
end
