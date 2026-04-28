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

  # ============================================================================
  # broadcast_id / topic helpers — pure functions
  # ============================================================================

  describe "broadcast_id/1" do
    test "returns the post's :uuid as the broadcast id" do
      assert PublishingPubSub.broadcast_id(%{uuid: "abc-123"}) == "abc-123"
    end

    test "returns nil when uuid is missing" do
      assert PublishingPubSub.broadcast_id(%{}) == nil
    end
  end

  describe "topic helpers" do
    test "post_versions_topic includes group + post slug" do
      assert PublishingPubSub.post_versions_topic("blog", "hello") ==
               "publishing:blog:post:hello:versions"
    end

    test "post_translations_topic includes group + post slug" do
      assert PublishingPubSub.post_translations_topic("blog", "hello") ==
               "publishing:blog:post:hello:translations"
    end

    test "cache_topic includes group slug" do
      assert PublishingPubSub.cache_topic("blog") == "publishing:blog:cache"
    end

    test "group_editors_topic includes group slug" do
      assert PublishingPubSub.group_editors_topic("blog") == "publishing:blog:editors"
    end
  end

  # ============================================================================
  # Subscribe / broadcast / receive cycle for non-payload-trim broadcasts
  # ============================================================================

  describe "broadcast cycle — receivers" do
    test "broadcast_post_deleted delivers to subscribers" do
      group = "tg-#{System.unique_integer([:positive])}"
      :ok = PublishingPubSub.subscribe_to_posts(group)
      :ok = PublishingPubSub.broadcast_post_deleted(group, "post-uuid-123")
      assert_receive {:post_deleted, "post-uuid-123"}, 500
      PublishingPubSub.unsubscribe_from_posts(group)
    end

    test "broadcast_version_live_changed delivers post + version" do
      group = "tg-#{System.unique_integer([:positive])}"
      :ok = PublishingPubSub.subscribe_to_posts(group)
      :ok = PublishingPubSub.broadcast_version_live_changed(group, "post-uuid", 7)
      assert_receive {:version_live_changed, "post-uuid", 7}, 500
      PublishingPubSub.unsubscribe_from_posts(group)
    end

    test "broadcast_version_deleted delivers post + version" do
      group = "tg-#{System.unique_integer([:positive])}"
      :ok = PublishingPubSub.subscribe_to_posts(group)
      :ok = PublishingPubSub.broadcast_version_deleted(group, "post-uuid", 3)
      assert_receive {:version_deleted, "post-uuid", 3}, 500
      PublishingPubSub.unsubscribe_from_posts(group)
    end

    test "broadcast_group_created / _updated / _deleted" do
      :ok = PublishingPubSub.subscribe_to_groups()
      group_payload = %{"slug" => "g1", "name" => "Group One"}
      :ok = PublishingPubSub.broadcast_group_created(group_payload)
      assert_receive {:group_created, ^group_payload}, 500
      :ok = PublishingPubSub.broadcast_group_updated(group_payload)
      assert_receive {:group_updated, ^group_payload}, 500
      :ok = PublishingPubSub.broadcast_group_deleted("g1")
      assert_receive {:group_deleted, "g1"}, 500
      PublishingPubSub.unsubscribe_from_groups()
    end

    test "broadcast_translation_created / _deleted" do
      group = "tg-#{System.unique_integer([:positive])}"
      slug = "hello"
      :ok = PublishingPubSub.subscribe_to_post_translations(group, slug)
      :ok = PublishingPubSub.broadcast_translation_created(group, slug, "fr")
      assert_receive {:translation_created, ^group, ^slug, "fr"}, 500
      :ok = PublishingPubSub.broadcast_translation_deleted(group, slug, "fr")
      assert_receive {:translation_deleted, ^group, ^slug, "fr"}, 500
      PublishingPubSub.unsubscribe_from_post_translations(group, slug)
    end

    test "broadcast_cache_changed delivers cache event" do
      group = "tg-#{System.unique_integer([:positive])}"
      :ok = PublishingPubSub.subscribe_to_cache(group)
      :ok = PublishingPubSub.broadcast_cache_changed(group)
      assert_receive {:cache_changed, ^group}, 500
      PublishingPubSub.unsubscribe_from_cache(group)
    end

    test "broadcast_post_version_published with source_id forwards both" do
      group = "tg-#{System.unique_integer([:positive])}"
      slug = "hello"
      :ok = PublishingPubSub.subscribe_to_post_versions(group, slug)
      :ok = PublishingPubSub.broadcast_post_version_published(group, slug, 2, "lv-pid")
      assert_receive {:post_version_published, ^group, ^slug, 2, "lv-pid"}, 500
      PublishingPubSub.unsubscribe_from_post_versions(group, slug)
    end

    test "broadcast_post_version_deleted forwards version" do
      group = "tg-#{System.unique_integer([:positive])}"
      slug = "hello"
      :ok = PublishingPubSub.subscribe_to_post_versions(group, slug)
      :ok = PublishingPubSub.broadcast_post_version_deleted(group, slug, 5)
      assert_receive {:post_version_deleted, ^group, ^slug, 5}, 500
      PublishingPubSub.unsubscribe_from_post_versions(group, slug)
    end
  end
end
