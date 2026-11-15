defmodule PhoenixKit.Modules.Publishing.ImageDimensionsTest do
  # `<Image>` writes width and height on its <img> when they are known, so the
  # browser reserves the image's box before it loads (no layout shift).
  use PhoenixKitPublishing.DataCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Modules.Publishing.PageBuilder.Components.Image
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKitPublishing.Test.Repo

  defp render(attributes) do
    %{__changed__: nil, attributes: attributes, variant: "default", content: nil, children: []}
    |> Image.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # core serves a file only through a stored instance (its URL)
  defp stored!(file_attrs, instances \\ [{"original", nil, nil}]) do
    file = file!(file_attrs)

    for {variant, w, h} <- instances do
      Repo.insert!(%FileInstance{
        file_uuid: file.uuid,
        variant_name: variant,
        file_name: "#{file.uuid}_#{variant}.png",
        mime_type: "image/png",
        ext: "png",
        checksum: "c-#{System.unique_integer([:positive])}",
        size: 1,
        width: w,
        height: h,
        processing_status: "completed"
      })
    end

    file
  end

  defp imgs(html), do: Regex.scan(~r/<img [^>]*>/, html) |> List.flatten()

  test "the author's width and height win, on a src image" do
    assert [img] = imgs(render(%{"src" => "/l.png", "width" => "640", "height" => "360"}))
    assert img =~ ~s(width="640")
    assert img =~ ~s(height="360")
  end

  test "text in a quoted value is not an attribute, and a non-string size is ignored" do
    assert [img] =
             imgs(
               render(%{
                 "src" => "/l.png",
                 "alt" => "a width=1 shot",
                 "width" => "640",
                 "height" => "360"
               })
             )

    assert img =~ ~s(width="640")
    assert Image.dimensions(%{"src" => "/l.png", "width" => %{}, "height" => 3}) == nil
    assert Image.dimensions(%{"width" => 640, "height" => 480}) == {640, 480}
  end

  test "a src image without them, or with unusable ones, gets none" do
    for attrs <- [
          %{"src" => "/l.png"},
          %{"src" => "/l.png", "width" => "wide", "height" => "360"},
          %{"src" => "/l.png", "width" => "0", "height" => "360"},
          %{"src" => "/l.png", "width" => "640"}
        ] do
      assert [img] = imgs(render(attrs))
      refute img =~ "width=", inspect(attrs)
      refute img =~ "height=", inspect(attrs)
    end
  end

  test "a Storage file gives its stored dimensions; the author's still win" do
    file = stored!(%{width: 1200, height: 800})

    assert [img] = imgs(render(%{"file_uuid" => file.uuid}))
    assert img =~ ~s(width="1200")
    assert img =~ ~s(height="800")

    assert [img] = imgs(render(%{"file_uuid" => file.uuid, "width" => "300", "height" => "200"}))
    assert img =~ ~s(width="300")
    refute img =~ ~s(width="1200")
  end

  test "a file without stored dimensions, or a uuid that is none, renders as before" do
    file = stored!(%{})
    assert [img] = imgs(render(%{"file_uuid" => file.uuid}))
    refute img =~ "width="

    assert Image.dimensions(%{"file_uuid" => "not-a-uuid"}) == nil
    assert Image.dimensions(%{"file_uuid" => Ecto.UUID.generate()}) == nil
  end

  test "both copies of a light/dark pair carry their own file's dimensions" do
    light = stored!(%{width: 1200, height: 800})
    dark = stored!(%{width: 1000, height: 500})

    html = render(%{"file_uuid" => light.uuid, "dark_file_uuid" => dark.uuid})

    assert [light_img, dark_img] = imgs(html)
    assert light_img =~ ~s(width="1200") and light_img =~ ~s(height="800")
    assert dark_img =~ ~s(width="1000") and dark_img =~ ~s(height="500")
  end

  test "the served copy's dimensions: the variant's, else the original's, else the file's" do
    file =
      stored!(%{width: 4000, height: 3000}, [
        {"original", 2000, 1500},
        {"thumbnail", 200, 150}
      ])

    assert Image.dimensions(%{"file_uuid" => file.uuid, "file_variant" => "thumbnail"}) ==
             {200, 150}

    assert Image.dimensions(%{"file_uuid" => file.uuid, "file_variant" => "large"}) ==
             {2000, 1500}

    assert Image.dimensions(%{"file_uuid" => file.uuid}) == {2000, 1500}

    # a stored variant without dimensions: none, never the original's ratio
    cropped =
      stored!(%{width: 4000, height: 3000}, [{"original", 2000, 1500}, {"square", nil, nil}])

    assert Image.dimensions(%{"file_uuid" => cropped.uuid, "file_variant" => "square"}) == nil

    bare = stored!(%{width: 4000, height: 3000})

    assert Image.dimensions(%{"file_uuid" => bare.uuid, "file_variant" => "thumbnail"}) ==
             {4000, 3000}
  end

  test "the page sanitiser keeps the attributes" do
    html = Renderer.render_markdown(~s(<Image src="/l.png" width="640" height="360" />))
    assert [img] = imgs(html)
    assert img =~ ~s(width="640")
    assert img =~ ~s(height="360")
  end
end
