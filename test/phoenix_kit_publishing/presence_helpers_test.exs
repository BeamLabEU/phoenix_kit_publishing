defmodule PhoenixKit.Modules.Publishing.PresenceHelpersTest do
  @moduledoc """
  Tests for PresenceHelpers — the topic-name builder and the
  owner/spectator role-resolution logic.

  Most of the module wraps Phoenix.Presence/PubSub and is exercised by
  integration tests; the pure helpers below pin behaviour without
  needing a Presence/PubSub server. Anything that does need one is
  tested via Presence.list-mocked behavior.
  """

  # Role-resolution tests use real Presence.track calls, so they
  # must run sequentially (Presence is global state per topic).
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Publishing.Presence
  alias PhoenixKit.Modules.Publishing.PresenceHelpers

  defp unique_form_key, do: "test:role-#{System.unique_integer([:positive])}:en"

  defp track_user(form_key, socket_id, user_uuid, joined_at_ms \\ nil) do
    topic = PresenceHelpers.editing_topic(form_key)
    joined_at = joined_at_ms || System.system_time(:millisecond)

    Presence.track(self(), topic, socket_id, %{
      user_uuid: user_uuid,
      user_email: "#{user_uuid}@example.com",
      joined_at: joined_at,
      phx_ref: socket_id,
      pid: self(),
      transport_pid: self()
    })
  end

  describe "editing_topic/1" do
    test "prefixes 'publishing_edit:' to the form key" do
      assert PresenceHelpers.editing_topic("blog:hello:en") ==
               "publishing_edit:blog:hello:en"
    end

    test "handles slug-mode form keys" do
      assert PresenceHelpers.editing_topic("docs:my-doc:fr") ==
               "publishing_edit:docs:my-doc:fr"
    end

    test "handles new-mode form keys" do
      assert PresenceHelpers.editing_topic("blog:new:en") ==
               "publishing_edit:blog:new:en"
    end

    test "handles empty suffix" do
      assert PresenceHelpers.editing_topic("") == "publishing_edit:"
    end
  end

  describe "get_sorted_presences/1" do
    test "returns empty list when no one is editing" do
      assert PresenceHelpers.get_sorted_presences(unique_form_key()) == []
    end

    test "returns a single presence for one tracked user" do
      key = unique_form_key()
      {:ok, _} = track_user(key, "socket-1", "user-1")

      assert [{"socket-1", meta}] = PresenceHelpers.get_sorted_presences(key)
      assert meta.user_uuid == "user-1"
    end

    test "sorts presences by joined_at (FIFO)" do
      key = unique_form_key()
      {:ok, _} = track_user(key, "socket-2", "user-second", 2000)
      {:ok, _} = track_user(key, "socket-1", "user-first", 1000)

      presences = PresenceHelpers.get_sorted_presences(key)
      assert [{first_id, _}, {second_id, _}] = presences
      assert first_id == "socket-1"
      assert second_id == "socket-2"
    end
  end

  describe "get_editing_role/3" do
    test "returns {:owner, []} when topic is empty" do
      assert {:owner, []} =
               PresenceHelpers.get_editing_role(unique_form_key(), "any-socket", "any-user")
    end

    test "returns :owner when calling socket is first in FIFO order" do
      key = unique_form_key()
      {:ok, _} = track_user(key, "socket-1", "user-1", 1000)
      {:ok, _} = track_user(key, "socket-2", "user-2", 2000)

      assert {:owner, presences} =
               PresenceHelpers.get_editing_role(key, "socket-1", "user-1")

      assert length(presences) == 2
    end

    test "returns :spectator when a different user owns the topic" do
      key = unique_form_key()
      {:ok, _} = track_user(key, "socket-1", "user-first", 1000)
      {:ok, _} = track_user(key, "socket-2", "user-spectator", 2000)

      assert {:spectator, owner_meta, presences} =
               PresenceHelpers.get_editing_role(key, "socket-2", "user-spectator")

      assert owner_meta.user_uuid == "user-first"
      assert length(presences) == 2
    end

    test "same user from a second tab is treated as :owner (multi-tab tolerance)" do
      key = unique_form_key()
      {:ok, _} = track_user(key, "socket-1", "user-1", 1000)
      {:ok, _} = track_user(key, "socket-2", "user-1", 2000)

      assert {:owner, _} = PresenceHelpers.get_editing_role(key, "socket-2", "user-1")
    end
  end

  describe "get_lock_owner/1" do
    test "returns nil when no one is editing" do
      assert PresenceHelpers.get_lock_owner(unique_form_key()) == nil
    end

    test "returns the first-tracked user's metadata" do
      key = unique_form_key()
      {:ok, _} = track_user(key, "socket-1", "user-first", 1000)
      {:ok, _} = track_user(key, "socket-2", "user-second", 2000)

      meta = PresenceHelpers.get_lock_owner(key)
      assert meta.user_uuid == "user-first"
    end
  end

  describe "get_spectators/1" do
    test "returns empty list when only the owner is present" do
      key = unique_form_key()
      {:ok, _} = track_user(key, "socket-1", "user-1")
      assert PresenceHelpers.get_spectators(key) == []
    end

    test "returns metadata for everyone except the owner" do
      key = unique_form_key()
      {:ok, _} = track_user(key, "socket-1", "user-owner", 1000)
      {:ok, _} = track_user(key, "socket-2", "user-spec1", 2000)
      {:ok, _} = track_user(key, "socket-3", "user-spec2", 3000)

      spectators = PresenceHelpers.get_spectators(key)
      assert length(spectators) == 2
      assert Enum.all?(spectators, &(&1.user_uuid != "user-owner"))
    end

    test "returns empty list when no one is editing" do
      assert PresenceHelpers.get_spectators(unique_form_key()) == []
    end
  end

  describe "count_editors/1" do
    test "returns 0 when no one is editing" do
      assert PresenceHelpers.count_editors(unique_form_key()) == 0
    end

    test "counts owner + spectators" do
      key = unique_form_key()
      {:ok, _} = track_user(key, "socket-1", "user-1", 1000)
      {:ok, _} = track_user(key, "socket-2", "user-2", 2000)
      {:ok, _} = track_user(key, "socket-3", "user-3", 3000)

      assert PresenceHelpers.count_editors(key) == 3
    end
  end

  describe "track_editing_session/3 + untrack_editing_session/2" do
    test "track adds a presence; untrack removes it" do
      key = unique_form_key()

      socket_stub = %{id: "test-socket", transport_pid: self()}
      user_stub = %{uuid: "test-user", email: "test@example.com"}

      {:ok, _} = PresenceHelpers.track_editing_session(key, socket_stub, user_stub)
      assert PresenceHelpers.count_editors(key) == 1

      :ok = PresenceHelpers.untrack_editing_session(key, socket_stub)
      assert PresenceHelpers.count_editors(key) == 0
    end
  end

  describe "subscribe_to_editing/1 + unsubscribe_from_editing/1" do
    test "subscribe enables receiving presence_diff broadcasts; unsubscribe stops them" do
      key = unique_form_key()
      assert :ok = PresenceHelpers.subscribe_to_editing(key)

      # Joining triggers presence_diff
      {:ok, _} = track_user(key, "diff-socket", "diff-user")
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}, 500

      assert :ok = PresenceHelpers.unsubscribe_from_editing(key)
    end
  end
end
