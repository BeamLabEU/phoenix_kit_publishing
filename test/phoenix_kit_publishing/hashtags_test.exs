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

  describe "extract and linkify agree (no dead links)" do
    # A tag that renders as a link but was never stored points at an archive
    # that can't find the post. Every case below is one where the two passes
    # could disagree.
    test "the 21st tag is neither stored nor linked" do
      body = 1..21 |> Enum.map_join(" ", &"#tag#{&1}")

      assert length(Hashtags.extract(body)) == 20
      refute "tag21" in Hashtags.extract(body)

      html = Renderer.render_markdown(body, tag_links: {"blog", "en"})
      assert html =~ ~s(/blog/tag/tag20")
      refute html =~ "/blog/tag/tag21"
      assert html =~ "#tag21"
    end

    test "a hashtag butted against a code span or link is neither" do
      for body <- ["`code`#tag", "[link](/x)#tag"] do
        assert Hashtags.extract(body) == []
        refute Renderer.render_markdown(body, tag_links: {"blog", "en"}) =~ "/blog/tag/tag"
      end
    end

    test "a colour in a raw HTML attribute is not a tag" do
      body = ~s(<span style="color: #fff">Text</span> and #real.)

      assert Hashtags.extract(body) == ["real"]

      html = Renderer.render_markdown(body, tag_links: {"blog", "en"})
      # The style declaration survives intact — no markdown link inside it.
      assert html =~ ~s(style="color: #fff")
      refute html =~ "/blog/tag/fff"
      assert html =~ ~s(/blog/tag/real")
    end

    test "a hashtag in a Showcase body IS a tag (its body is markdown)" do
      body = ~s(<Showcase src="/a.jpg">Read about #elixir</Showcase>)

      assert Hashtags.extract(body) == ["elixir"]
      assert Renderer.render_markdown(body, tag_links: {"blog", "en"}) =~ ~s(/blog/tag/elixir")
    end

    test "a hashtag in a raw-HTML component body is left alone" do
      # <Video>'s body is emitted as raw HTML, so a markdown link would show
      # up literally as [#tag](...) to the reader.
      body = ~s(<Video url="https://y.tube">Caption #nottag</Video>)

      assert Hashtags.extract(body) == []
      refute Renderer.render_markdown(body, tag_links: {"blog", "en"}) =~ "/blog/tag/nottag"
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

    test "creating a post WITH content derives its tags immediately", %{slug: slug} do
      # The import/API shape: one call carrying the body. Without derivation
      # here the post rendered its #hashtags as archive links while being
      # absent from those archives until someone happened to re-save it.
      {:ok, fresh} =
        Posts.create_post(slug, %{
          title: "Born Tagged",
          slug: "born-tagged",
          content: "Ships with #otp and #ecto."
        })

      :ok = Versions.publish_version(slug, fresh.uuid, 1)

      {:ok, read} = Publishing.read_post_by_uuid(fresh.uuid, "en", 1)
      assert read.metadata.tags == ["otp", "ecto"]
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

    test "a caller-supplied tags list is ignored — the body is the only source", %{
      slug: slug,
      post: post
    } do
      {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)

      # Without content, nothing re-derives: the tags derived at create stand.
      {:ok, updated} = Posts.update_post(slug, read, %{"tags" => ["manual"]}, %{})
      assert updated.metadata.tags == ["elixir", "phoenix"]

      # And a list sent alongside content loses to the content.
      {:ok, read2} = Publishing.read_post_by_uuid(post.uuid, "en", 1)

      {:ok, updated2} =
        Posts.update_post(slug, read2, %{"content" => "Only #otp.", "tags" => ["manual"]}, %{})

      assert updated2.metadata.tags == ["otp"]
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
