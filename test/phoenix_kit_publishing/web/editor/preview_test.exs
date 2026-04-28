defmodule PhoenixKit.Modules.Publishing.Web.Editor.PreviewTest do
  @moduledoc """
  Direct unit tests for `Editor.Preview` — pure helpers around preview
  payload construction and URL building. No DB or LV required for the
  basic shape; only `apply_preview_payload/2` reaches the DB and is
  exercised through the integration-style tests in editor_live_test.

  These cover `build_preview_payload/1`, `build_preview_query_params/2`,
  and `preview_editor_path/4`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Editor.Preview

  defp fake_socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  describe "build_preview_payload/1" do
    test "produces the canonical payload shape from socket assigns" do
      socket =
        fake_socket(%{
          group_slug: "blog",
          current_language: "en",
          content: "Body markdown",
          form: %{
            "title" => "Hello",
            "status" => "draft",
            "published_at" => "",
            "slug" => "hello-world",
            "featured_image_uuid" => "img-1",
            "url_slug" => "hello"
          },
          post: %{
            uuid: "post-uuid-1",
            slug: "hello-world",
            mode: :slug,
            available_languages: ["en", "fr"],
            metadata: %{title: "Hello", status: "draft"}
          },
          is_new_post: false,
          group_mode: "slug"
        })

      payload = Preview.build_preview_payload(socket)

      assert payload.group_slug == "blog"
      assert payload.language == "en"
      assert payload.content == "Body markdown"
      assert payload.metadata.slug == "hello-world"
      assert payload.metadata.featured_image_uuid == "img-1"
      assert payload.metadata.url_slug == "hello"
      assert payload.metadata.status == "draft"
      assert "en" in payload.available_languages
      assert "fr" in payload.available_languages
      assert payload.mode == :slug
      refute payload.is_new_post
    end

    test "marks payload as new when post has no uuid" do
      socket =
        fake_socket(%{
          group_slug: "blog",
          current_language: "en",
          content: "",
          form: %{},
          post: %{slug: "", available_languages: [], metadata: %{}},
          group_mode: "slug"
        })

      payload = Preview.build_preview_payload(socket)
      assert payload.is_new_post == true
    end

    test "infers timestamp mode from group_mode when post has no mode" do
      socket =
        fake_socket(%{
          group_slug: "blog",
          current_language: "en",
          content: "",
          form: %{},
          post: %{available_languages: [], metadata: %{}},
          group_mode: "timestamp",
          is_new_post: true
        })

      payload = Preview.build_preview_payload(socket)
      assert payload.mode == :timestamp
    end

    test "falls back to default 'draft' status when none is set" do
      socket =
        fake_socket(%{
          group_slug: "blog",
          current_language: "en",
          content: "",
          form: %{},
          post: %{available_languages: [], metadata: %{}},
          group_mode: "slug",
          is_new_post: true
        })

      payload = Preview.build_preview_payload(socket)
      assert payload.metadata.status == "draft"
    end
  end

  describe "build_preview_query_params/2" do
    test "wraps the token in the canonical map" do
      assert Preview.build_preview_query_params(%{}, "abc123") ==
               %{"preview_token" => "abc123"}
    end
  end

  describe "preview_editor_path/4" do
    test "builds the editor path with the preview_token query param" do
      socket = fake_socket(%{group_slug: "blog"})
      data = %{group_slug: "blog"}
      path = Preview.preview_editor_path(socket, data, "tok-1", %{})

      assert path =~ "/admin/publishing/blog/edit"
      assert path =~ "preview_token=tok-1"
    end

    test "appends ?new=true when data marks the payload as new" do
      socket = fake_socket(%{group_slug: "blog"})
      data = %{group_slug: "blog", is_new_post: true}
      path = Preview.preview_editor_path(socket, data, "tok-1", %{})

      assert path =~ "new=true"
    end

    test "uses socket's group_slug when data has none" do
      socket = fake_socket(%{group_slug: "fallback"})
      data = %{}
      path = Preview.preview_editor_path(socket, data, "t", %{})

      assert path =~ "/admin/publishing/fallback/edit"
    end
  end
end
