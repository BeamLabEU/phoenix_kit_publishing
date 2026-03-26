defmodule PhoenixKit.Modules.Publishing.PubSubBroadcastIdTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub

  # ============================================================================
  # broadcast_id/1
  # ============================================================================

  describe "broadcast_id/1" do
    test "always returns uuid" do
      post = %{slug: "my-post", uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      assert PublishingPubSub.broadcast_id(post) == "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"
    end

    test "returns uuid when slug is nil" do
      post = %{slug: nil, uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      assert PublishingPubSub.broadcast_id(post) == "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"
    end

    test "returns uuid when slug key is missing" do
      post = %{uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      assert PublishingPubSub.broadcast_id(post) == "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"
    end

    test "returns nil when uuid is nil" do
      post = %{slug: "my-post", uuid: nil}
      assert PublishingPubSub.broadcast_id(post) == nil
    end

    test "returns nil for nil post" do
      assert PublishingPubSub.broadcast_id(nil) == nil
    end
  end

  # ============================================================================
  # Topic consistency
  # ============================================================================

  describe "topic consistency" do
    test "subscription and broadcast use uuid-based topics" do
      post = %{slug: "my-post", uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      broadcast_id = PublishingPubSub.broadcast_id(post)

      topic = PublishingPubSub.post_translations_topic("blog", broadcast_id)
      assert topic == "publishing:blog:post:019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18:translations"
    end

    test "timestamp-mode posts use same topic pattern" do
      post = %{slug: nil, uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      broadcast_id = PublishingPubSub.broadcast_id(post)

      topic = PublishingPubSub.post_translations_topic("news", broadcast_id)
      assert topic == "publishing:news:post:019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18:translations"
    end

    test "version topic uses same uuid pattern" do
      post = %{slug: nil, uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      broadcast_id = PublishingPubSub.broadcast_id(post)

      topic = PublishingPubSub.post_versions_topic("news", broadcast_id)
      assert topic == "publishing:news:post:019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18:versions"
    end
  end
end
