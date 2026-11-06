defmodule PhoenixKit.Modules.Publishing.Web.EditorComponentPreviewsTest do
  @moduledoc """
  What the editor hands Leaf to draw PHK components as previews.

  Runs through the real `leaf_editor` on a mounted page, because the failure is
  silent on both sides of the seam: Leaf drops a `tag_previews` kind it does not
  know and turns a raising `media_url` into no picture, so a typo here leaves a
  working editor with plain boxes and no warning.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers

  @file_uuid "019a6f96-e895-74e2-a745-1b596ee235af"

  @body """
  <Headline stretch="30">Big words</Headline>

  <Showcase file_uuid="#{@file_uuid}" side="right" alt="The room">
  Beside the picture.
  </Showcase>

  <CTA action="/signup">Sign up</CTA>

  <Embed src="/demos/leaf" height="520" title="Try it" />

  <Audio file_uuid="#{@file_uuid}" title="Episode 12" />

  <Image file_uuid="#{@file_uuid}" alt="Lone"/>

  <Gallery>
  <Image file_uuid="#{@file_uuid}" alt="In a gallery"/>
  </Gallery>
  """

  defp mount_editor(content) do
    slug = "previews-#{System.unique_integer([:positive])}"
    {:ok, _} = Groups.add_group(slug, mode: "slug")
    {:ok, post} = Posts.create_post(slug, %{title: "P", slug: "p", content: content})

    {:ok, _view, html} =
      build_conn()
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/#{slug}/#{post[:uuid]}/edit")

    html
  end

  test "each previewed component reaches the page as its kind" do
    html = mount_editor(@body)

    for kind <- Helpers.component_tag_previews() |> Map.values() do
      assert html =~ "leaf-atomic-kind-#{kind}", "Leaf did not draw the #{kind} kind"
    end
  end

  test "a file_uuid is drawn as a signed picture on the block and inside a gallery" do
    html = mount_editor(@body)

    assert html =~ ~r/class="leaf-kind-picture" src="[^"]*\/file\/#{@file_uuid}\/medium\//
    assert html =~ ~r/class="leaf-atomic-media" src="[^"]*\/file\/#{@file_uuid}\/medium\//
    assert html =~ ~r/class="leaf-atomic-thumb" src="[^"]*\/file\/#{@file_uuid}\/medium\//
  end

  test "the signed URL stays out of the source Leaf writes back" do
    # A chip serializes from data-leaf-raw. A URL in there would put a signed
    # path in the body on the next save, in place of the file_uuid.
    raws =
      ~r/data-leaf-raw="([^"]*)"/
      |> Regex.scan(mount_editor(@body), capture: :all_but_first)
      |> List.flatten()

    assert raws != []
    refute Enum.any?(raws, &(&1 =~ "/file/"))
  end

  test "every previewed tag is one the renderer knows" do
    for tag <- Map.keys(Helpers.component_tag_previews()) do
      assert tag in Renderer.component_tags()
    end
  end
end
