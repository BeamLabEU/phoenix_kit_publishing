defmodule PhoenixKit.Modules.Publishing.ActivityLogOptsTest do
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.ActivityLog

  @uuid "00000000-0000-7000-8000-000000000001"
  @meta %{
    "via" => "api",
    "key_prefix" => "abcd1234",
    "request_id" => "r1",
    "tool" => "publishing.update_post"
  }

  test "without opts the row is unchanged: manual mode, no extra keys" do
    ActivityLog.log_manual("publishing.post.updated", @uuid, "publishing_post", @uuid, %{"a" => 1})

    row = assert_activity_logged("publishing.post.updated", resource_uuid: @uuid)
    assert row.mode == "manual"
    assert row.metadata == %{"a" => 1}
  end

  test "activity_mode and log_metadata are applied (keyword and map opts)" do
    for opts <- [
          [activity_mode: "auto", log_metadata: @meta],
          %{activity_mode: "auto", log_metadata: @meta}
        ] do
      uuid = Ecto.UUID.generate()

      ActivityLog.log_manual(
        "publishing.post.updated",
        @uuid,
        "publishing_post",
        uuid,
        %{"a" => 1},
        opts
      )

      row = assert_activity_logged("publishing.post.updated", resource_uuid: uuid)
      assert row.mode == "auto"
      assert row.metadata == Map.put(@meta, "a", 1)
    end
  end

  test "the entry's own keys win a clash and atom keys of log_metadata are ignored" do
    ActivityLog.log_manual(
      "publishing.post.updated",
      @uuid,
      "publishing_post",
      @uuid,
      %{"via" => "entry"},
      activity_mode: "auto",
      log_metadata: %{"via" => "api", :atom_key => "x", "extra" => "y"}
    )

    row = assert_activity_logged("publishing.post.updated", resource_uuid: @uuid)
    assert row.metadata == %{"via" => "entry", "extra" => "y"}
  end

  test "a failed mutation keeps db_pending and takes the same mode and metadata" do
    ActivityLog.log_failed_mutation(
      "publishing.post.updated",
      @uuid,
      "publishing_post",
      @uuid,
      %{"a" => 1},
      activity_mode: "auto",
      log_metadata: @meta
    )

    row = assert_activity_logged("publishing.post.updated", resource_uuid: @uuid)
    assert row.mode == "auto"
    assert row.metadata["db_pending"] == true
    assert row.metadata["via"] == "api"
  end

  test "a blank or non-binary activity_mode falls back to manual; `:mode` is never read" do
    ActivityLog.log_manual(
      "publishing.post.updated",
      @uuid,
      "publishing_post",
      @uuid,
      %{},
      activity_mode: "",
      mode: "auto"
    )

    row = assert_activity_logged("publishing.post.updated", resource_uuid: @uuid)
    assert row.mode == "manual"
  end
end
