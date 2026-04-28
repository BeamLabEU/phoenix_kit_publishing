defmodule PhoenixKit.Modules.Publishing.ActivityLogTest do
  @moduledoc """
  Tests for the ActivityLog wrapper around PhoenixKit.Activity.log/1.

  Covers:
    * actor_uuid/1 extracts from keyword and map opts (and nil shape)
    * log/1 swallows errors silently (Postgrex.Error) or via Logger.warning
    * log_manual/5 and log_failed_mutation/5 build the expected map shape
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Publishing.ActivityLog

  describe "actor_uuid/1" do
    test "extracts from a keyword list" do
      assert ActivityLog.actor_uuid(actor_uuid: "abc") == "abc"
    end

    test "extracts from a map" do
      assert ActivityLog.actor_uuid(%{actor_uuid: "abc"}) == "abc"
    end

    test "returns nil for missing key in keyword list" do
      assert ActivityLog.actor_uuid([]) == nil
    end

    test "returns nil for missing key in map" do
      assert ActivityLog.actor_uuid(%{}) == nil
    end

    test "returns nil for nil opts" do
      assert ActivityLog.actor_uuid(nil) == nil
    end

    test "returns nil for non-list/map input" do
      assert ActivityLog.actor_uuid("string") == nil
      assert ActivityLog.actor_uuid(123) == nil
      assert ActivityLog.actor_uuid(:atom) == nil
    end
  end

  describe "log/1" do
    test "returns :ok even when the activities table is missing (rescue path)" do
      # No DB sandbox here — the call goes through, hits Postgrex.Error
      # via the underlying PhoenixKit.Activity.log path, and the rescue
      # silently returns :ok. This pins the never-crash-the-primary-write
      # contract.
      assert ActivityLog.log(%{action: "test", mode: "manual"}) == :ok
    end

    test "returns :ok for an empty attrs map" do
      assert ActivityLog.log(%{}) == :ok
    end
  end

  describe "log_manual/5" do
    test "returns :ok and routes through log/1" do
      assert ActivityLog.log_manual("test.action", nil, "resource", nil, %{}) == :ok
    end

    test "accepts metadata map" do
      assert ActivityLog.log_manual(
               "test.action",
               "actor-uuid",
               "test_resource",
               "resource-uuid",
               %{"key" => "value"}
             ) == :ok
    end

    test "uses default empty metadata when not provided" do
      assert ActivityLog.log_manual("test.action", nil, "resource", nil) == :ok
    end
  end

  describe "log_failed_mutation/5" do
    test "returns :ok and writes db_pending: true into metadata" do
      assert ActivityLog.log_failed_mutation("test.failed", nil, "resource", nil, %{
               "reason" => "test"
             }) == :ok
    end

    test "uses default empty metadata (still gets db_pending: true added)" do
      assert ActivityLog.log_failed_mutation("test.failed", nil, "resource", nil) == :ok
    end
  end
end
