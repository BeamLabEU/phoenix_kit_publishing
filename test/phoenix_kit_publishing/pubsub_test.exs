defmodule PhoenixKit.Modules.Publishing.PubSubTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub

  # ============================================================================
  # Topic Generation
  # ============================================================================

  describe "topic generation" do
    test "groups_topic returns consistent topic" do
      assert PublishingPubSub.groups_topic() == "publishing:groups"
    end

    test "posts_topic includes blog slug" do
      assert PublishingPubSub.posts_topic("blog") == "publishing:blog:posts"
      assert PublishingPubSub.posts_topic("faq") == "publishing:faq:posts"
    end

    test "post_versions_topic includes blog and post slugs" do
      topic = PublishingPubSub.post_versions_topic("blog", "hello-world")
      assert topic == "publishing:blog:post:hello-world:versions"
    end

    test "post_translations_topic includes blog and post slugs" do
      topic = PublishingPubSub.post_translations_topic("blog", "hello-world")
      assert topic == "publishing:blog:post:hello-world:translations"
    end

    test "editor_form_topic includes form key" do
      topic = PublishingPubSub.editor_form_topic("blog:hello-world:en")
      assert topic == "publishing:editor_forms:blog:hello-world:en"
    end

    test "editor_presence_topic includes form key" do
      topic = PublishingPubSub.editor_presence_topic("blog:hello-world:en")
      assert topic == "publishing:presence:editor:blog:hello-world:en"
    end

    test "cache_topic includes blog slug" do
      assert PublishingPubSub.cache_topic("blog") == "publishing:blog:cache"
    end

    test "group_editors_topic includes group slug" do
      assert PublishingPubSub.group_editors_topic("blog") == "publishing:blog:editors"
    end
  end

  # ============================================================================
  # Form Key Generation
  # ============================================================================

  describe "generate_form_key/3" do
    test "generates key from uuid and language" do
      key = PublishingPubSub.generate_form_key("blog", %{uuid: "abc-123", language: "en"}, :edit)
      assert key == "blog:abc-123:en"
    end

    test "generates key from slug and language" do
      key =
        PublishingPubSub.generate_form_key(
          "blog",
          %{slug: "hello-world", language: "en"},
          :edit
        )

      assert key == "blog:hello-world:en"
    end

    test "generates key for new post mode" do
      key = PublishingPubSub.generate_form_key("blog", %{language: "en"}, :new)
      assert key == "blog:new:en"
    end

    test "generates fallback key for new mode without language" do
      key = PublishingPubSub.generate_form_key("blog", %{}, :new)
      assert key == "blog:new"
    end
  end

  # ============================================================================
  # Minimal-payload broadcasts — pinning that broadcast_post_status_changed and
  # broadcast_version_created strip post maps to %{uuid:, slug:} so post titles,
  # body content, and version metadata don't leak into PubSub trace logs.
  # ============================================================================

  describe "minimal payload broadcasts" do
    setup do
      group_slug = "test-group-#{System.unique_integer([:positive])}"
      :ok = PublishingPubSub.subscribe_to_posts(group_slug)
      on_exit(fn -> PublishingPubSub.unsubscribe_from_posts(group_slug) end)
      %{group_slug: group_slug}
    end

    test "broadcast_post_status_changed sends only :uuid and :slug",
         %{group_slug: group_slug} do
      full_post = %{
        uuid: "post-uuid",
        slug: "my-post",
        title: "secret title",
        content: "<script>alert('xss')</script>",
        author_email: "leak@example.com"
      }

      :ok = PublishingPubSub.broadcast_post_status_changed(group_slug, full_post)

      assert_receive {:post_status_changed, %{uuid: "post-uuid", slug: "my-post"} = payload},
                     500

      refute Map.has_key?(payload, :title)
      refute Map.has_key?(payload, :content)
      refute Map.has_key?(payload, :author_email)
    end

    test "broadcast_version_created sends only :uuid and :slug",
         %{group_slug: group_slug} do
      full_post = %{
        uuid: "post-uuid",
        slug: "my-post",
        version_data: %{notes: "private build notes"},
        decrypted_token: "secret"
      }

      :ok = PublishingPubSub.broadcast_version_created(group_slug, full_post)

      assert_receive {:version_created, %{uuid: "post-uuid", slug: "my-post"} = payload},
                     500

      refute Map.has_key?(payload, :version_data)
      refute Map.has_key?(payload, :decrypted_token)
    end

    test "broadcast_post_created strips full record",
         %{group_slug: group_slug} do
      :ok =
        PublishingPubSub.broadcast_post_created(group_slug, %{
          uuid: "u",
          slug: "s",
          email: "leak@x.com"
        })

      assert_receive {:post_created, %{uuid: "u", slug: "s"} = payload}, 500
      refute Map.has_key?(payload, :email)
    end

    test "broadcast_post_updated strips full record",
         %{group_slug: group_slug} do
      :ok =
        PublishingPubSub.broadcast_post_updated(group_slug, %{
          uuid: "u",
          slug: "s",
          body: "private"
        })

      assert_receive {:post_updated, %{uuid: "u", slug: "s"} = payload}, 500
      refute Map.has_key?(payload, :body)
    end
  end
end
