defmodule PhoenixKit.Integration.Publishing.OgOverrideTest do
  @moduledoc """
  Round-trip tests for the per-post, per-language OpenGraph override:
  editor form fields (og_title/og_description/og_image_uuid) → content.data["og"]
  → surfaced back as post.metadata.og by the mapper.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  defp create_group do
    {:ok, group} =
      Groups.add_group("OG Group #{System.unique_integer([:positive])}", mode: "slug")

    group
  end

  describe "OG override round-trip" do
    test "saving og_* fields persists them under metadata.og" do
      group = create_group()
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Base Title"})

      {:ok, updated} =
        Posts.update_post(
          group["slug"],
          post,
          %{
            "og_title" => "Social Title",
            "og_description" => "Social Desc",
            "og_image_uuid" => "018e3c4a-9f6b-7890-abcd-ef1234567890"
          },
          %{}
        )

      assert updated[:metadata][:og] == %{
               "title" => "Social Title",
               "description" => "Social Desc",
               "image_uuid" => "018e3c4a-9f6b-7890-abcd-ef1234567890"
             }

      # Persisted, not just echoed: survives a fresh read.
      {:ok, reread} = Posts.read_post(group["slug"], post[:uuid], nil, nil)
      assert reread[:metadata][:og]["title"] == "Social Title"
    end

    test "a partial override only stores the filled field" do
      group = create_group()
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Base"})

      {:ok, updated} =
        Posts.update_post(group["slug"], post, %{"og_title" => "Only Title"}, %{})

      assert updated[:metadata][:og] == %{"title" => "Only Title"}
    end

    test "blanking all og fields clears the override" do
      group = create_group()
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Base"})
      {:ok, set} = Posts.update_post(group["slug"], post, %{"og_title" => "X"}, %{})
      assert set[:metadata][:og]["title"] == "X"

      {:ok, cleared} =
        Posts.update_post(
          group["slug"],
          set,
          %{"og_title" => "", "og_description" => "", "og_image_uuid" => ""},
          %{}
        )

      assert cleared[:metadata][:og] == nil
    end

    test "a save that carries no og_* fields preserves the existing override" do
      group = create_group()
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Base"})
      {:ok, _} = Posts.update_post(group["slug"], post, %{"og_title" => "Keep Me"}, %{})
      {:ok, reloaded} = Posts.read_post(group["slug"], post[:uuid], nil, nil)

      {:ok, after_unrelated} =
        Posts.update_post(group["slug"], reloaded, %{"title" => "New Title"}, %{})

      assert after_unrelated[:metadata][:og]["title"] == "Keep Me"
    end
  end
end
