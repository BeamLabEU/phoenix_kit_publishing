defmodule PhoenixKit.Modules.Publishing.Web.Controller.AudioTest do
  @moduledoc """
  Pins the audio contract: the `<Audio>` inline component (uuid + src forms,
  unsafe schemes dropped), the post-level audio version (editor field →
  version.data → top-of-post player), and the feed enclosure.
  """

  # async: false — mutates the global publishing settings rows.
  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  defp unique_name, do: "audio-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    %{slug: group["slug"]}
  end

  describe "<Audio> inline component" do
    test "renders a native player from a src URL with title and caption" do
      html =
        Renderer.render_markdown(
          ~s(Intro\n\n<Audio src="https://cdn.example.com/ep.mp3" title="Ep 1" caption="42 min" />\n\nOutro)
        )

      assert html =~ ~s(<audio controls preload="none")
      assert html =~ ~s(src="https://cdn.example.com/ep.mp3")
      assert html =~ "Ep 1"
      assert html =~ "42 min"
    end

    test "resolves file_uuid through signed storage URLs" do
      uuid = "018e3c4a-9f6b-7890-abcd-ef1234567890"
      html = Renderer.render_markdown(~s(<Audio file_uuid="#{uuid}" />))

      assert html =~ "<audio"
      assert html =~ "/file/#{uuid}/original/"
    end

    test "self-closing components honor stretch (the inline path wraps too)" do
      html =
        Renderer.render_markdown(~s(<Audio src="https://cdn.example.com/e.mp3" stretch="20" />))

      assert html =~ "pk-stretch"
      assert html =~ "min(10.0%,"
    end

    test "unsafe src schemes render nothing" do
      for bad <- ["javascript:alert(1)", "data:audio/mp3;x", "ftp://x/y.mp3"] do
        html = Renderer.render_markdown(~s(<Audio src="#{bad}" />))
        refute html =~ "<audio"
      end
    end
  end

  describe "post audio version" do
    test "player renders above the content and the feed carries an enclosure", %{
      conn: conn,
      slug: slug
    } do
      uuid = "018e3c4a-9f6b-7890-abcd-ef1234567890"

      {:ok, post} =
        Posts.create_post(slug, %{title: "Narrated", slug: "narrated", content: "Body."})

      :ok = Versions.publish_version(slug, post.uuid, 1)
      {:ok, _} = Posts.update_post(slug, post, %{"audio_uuid" => uuid}, %{})

      html = get(conn, "/#{slug}/narrated") |> html_response(200)
      assert html =~ ~s(<audio)
      assert html =~ "/file/#{uuid}/original/"
      assert html =~ "Listen to this post"

      feed = get(conn, "/#{slug}/feed.xml") |> response(200)
      assert feed =~ "<enclosure url="
      assert feed =~ "/file/#{uuid}/original/"
      assert feed =~ ~s(type="audio/mpeg")
    end

    test "no audio → no player, no enclosure", %{conn: conn, slug: slug} do
      {:ok, post} = Posts.create_post(slug, %{title: "Silent", slug: "silent", content: "x"})
      :ok = Versions.publish_version(slug, post.uuid, 1)

      refute get(conn, "/#{slug}/silent") |> html_response(200) =~ "<audio"
      refute get(conn, "/#{slug}/feed.xml") |> response(200) =~ "<enclosure"
    end

    test "a BLANK stored audio_uuid renders no player (legacy rows)", %{
      conn: conn,
      slug: slug
    } do
      {:ok, post} = Posts.create_post(slug, %{title: "Blank", slug: "blank", content: "x"})
      :ok = Versions.publish_version(slug, post.uuid, 1)

      # Simulate what older saves stored when the picker was left empty: the
      # key present with "". An empty string is truthy in Elixir, so the
      # player used to render with an empty uuid segment in its src —
      # /file//original/<token>, a dead request (reported on a live post).
      version = DBStorage.get_version(post.uuid, 1)

      {:ok, _} =
        DBStorage.update_version(version, %{data: Map.put(version.data, "audio_uuid", "")})

      html = get(conn, "/#{slug}/blank") |> html_response(200)
      refute html =~ "<audio"
      refute html =~ "/file//"
      refute get(conn, "/#{slug}/feed.xml") |> response(200) =~ "<enclosure"
    end

    test "clearing the picker removes the player and the stored key", %{conn: conn, slug: slug} do
      uuid = "018e3c4a-9f6b-7890-abcd-ef1234567891"

      {:ok, post} = Posts.create_post(slug, %{title: "Cleared", slug: "cleared", content: "x"})
      :ok = Versions.publish_version(slug, post.uuid, 1)
      {:ok, _} = Posts.update_post(slug, post, %{"audio_uuid" => uuid}, %{})

      assert get(conn, "/#{slug}/cleared") |> html_response(200) =~ "<audio"

      {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)
      {:ok, _} = Posts.update_post(slug, read, %{"audio_uuid" => ""}, %{})

      refute get(conn, "/#{slug}/cleared") |> html_response(200) =~ "<audio"
      # Cleared means gone, not stored blank.
      refute Map.has_key?(DBStorage.get_version(post.uuid, 1).data, "audio_uuid")
    end
  end
end
