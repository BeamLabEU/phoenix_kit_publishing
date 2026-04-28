defmodule PhoenixKit.Modules.Publishing.Web.Editor.CollaborativeTest do
  @moduledoc """
  Direct unit tests for the pure socket-state functions in
  `Editor.Collaborative` — `apply_remote_form_state/2`,
  `apply_remote_form_change/2`, `touch_activity/1`,
  `assign_default_editing_state/1`, `build_user_info/2`.
  These are pure assignment functions that don't require Presence or PubSub.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Editor.Collaborative

  defp fake_socket(assigns) do
    %Phoenix.LiveView.Socket{
      id: "test-socket-#{System.unique_integer([:positive])}",
      assigns: Map.merge(%{__changed__: %{}}, assigns)
    }
  end

  describe "assign_default_editing_state/1" do
    test "sets owner=true and readonly=false on a fresh socket" do
      result = Collaborative.assign_default_editing_state(fake_socket(%{}))

      assert result.assigns.lock_owner? == true
      assert result.assigns.readonly? == false
      assert result.assigns.lock_owner_user == nil
      assert result.assigns.spectators == []
      assert result.assigns.other_viewers == []
    end
  end

  describe "touch_activity/1" do
    test "updates last_activity_at and clears lock_warning_shown" do
      socket = fake_socket(%{lock_warning_shown: true})
      result = Collaborative.touch_activity(socket)

      assert is_integer(result.assigns.last_activity_at)
      assert result.assigns.lock_warning_shown == false
    end
  end

  describe "apply_remote_form_state/2" do
    test "merges form + content from remote sync state" do
      socket = fake_socket(%{form: %{}, content: "old"})

      result =
        Collaborative.apply_remote_form_state(socket, %{
          form: %{"title" => "Synced"},
          content: "new content"
        })

      assert result.assigns.form == %{"title" => "Synced"}
      assert result.assigns.content == "new content"
      assert result.assigns.has_pending_changes == true
    end

    test "accepts string-keyed form_state" do
      socket = fake_socket(%{form: %{}, content: "old"})

      result =
        Collaborative.apply_remote_form_state(socket, %{
          "form" => %{"title" => "S"},
          "content" => "C"
        })

      assert result.assigns.form == %{"title" => "S"}
      assert result.assigns.content == "C"
    end

    test "preserves socket form/content when remote keys are missing" do
      socket = fake_socket(%{form: %{"existing" => "value"}, content: "stay"})

      result = Collaborative.apply_remote_form_state(socket, %{})

      assert result.assigns.form == %{"existing" => "value"}
      assert result.assigns.content == "stay"
    end
  end

  describe "apply_remote_form_change/2 — meta type" do
    test "merges form and updates post status across all languages" do
      socket =
        fake_socket(%{
          form: %{},
          post: %{
            metadata: %{status: "draft"},
            available_languages: ["en", "fr"]
          }
        })

      new_form = %{"status" => "published", "title" => "Hello"}
      result = Collaborative.apply_remote_form_change(socket, %{type: :meta, data: new_form})

      assert result.assigns.form == new_form
      assert result.assigns.post.metadata.status == "published"
      assert result.assigns.post.language_statuses["en"] == "published"
      assert result.assigns.post.language_statuses["fr"] == "published"
    end
  end

  describe "apply_remote_form_change/2 — content type" do
    test "merges form + content from remote payload" do
      socket = fake_socket(%{form: %{}, content: ""})

      result =
        Collaborative.apply_remote_form_change(socket, %{
          type: :content,
          data: %{content: "new body", form: %{"title" => "Hi"}}
        })

      assert result.assigns.content == "new body"
      assert result.assigns.form == %{"title" => "Hi"}
    end
  end

  describe "apply_remote_form_change/2 — unrecognized payload" do
    test "ignores unknown types and returns socket unchanged" do
      socket = fake_socket(%{form: %{"existing" => "value"}, content: "stay"})
      result = Collaborative.apply_remote_form_change(socket, %{type: :bogus, data: %{}})

      assert result.assigns.form == %{"existing" => "value"}
      assert result.assigns.content == "stay"
    end

    test "ignores completely malformed payloads" do
      socket = fake_socket(%{form: %{}, content: ""})
      result = Collaborative.apply_remote_form_change(socket, "not a map")
      assert result == socket
    end
  end

  describe "build_user_info/2" do
    test "owner role with current user" do
      socket =
        fake_socket(%{
          lock_owner?: true,
          phoenix_kit_current_user: %{uuid: "u-1", email: "a@b.com"}
        })

      info = Collaborative.build_user_info(socket, nil)

      assert info.role == :owner
      assert info.id == "u-1"
      assert info.email == "a@b.com"
      assert info.socket_id == socket.id
    end

    test "spectator role with current user" do
      socket =
        fake_socket(%{
          lock_owner?: false,
          phoenix_kit_current_user: %{uuid: "u-2", email: "x@y.com"}
        })

      info = Collaborative.build_user_info(socket, nil)
      assert info.role == :spectator
    end

    test "explicit user override takes precedence over current_user" do
      socket =
        fake_socket(%{
          lock_owner?: true,
          phoenix_kit_current_user: %{uuid: "default", email: "d@d.com"}
        })

      override = %{uuid: "override", email: "o@o.com"}
      info = Collaborative.build_user_info(socket, override)

      assert info.id == "override"
      assert info.email == "o@o.com"
    end

    test "returns minimal info when no user is available" do
      socket = fake_socket(%{lock_owner?: false, phoenix_kit_current_user: nil})
      info = Collaborative.build_user_info(socket, nil)

      refute Map.has_key?(info, :id)
      refute Map.has_key?(info, :email)
      assert info.socket_id == socket.id
      assert info.role == :spectator
    end
  end

  describe "broadcast_editor_activity/3 — no group/post short-circuit" do
    test "no-op when group_slug is missing" do
      socket = fake_socket(%{group_slug: nil, post: %{uuid: "u"}})
      assert Collaborative.broadcast_editor_activity(socket, :joined) == nil
    end

    test "no-op when post is nil" do
      socket = fake_socket(%{group_slug: "blog", post: nil})
      assert Collaborative.broadcast_editor_activity(socket, :joined) == nil
    end

    test "no-op when post has no uuid" do
      socket = fake_socket(%{group_slug: "blog", post: %{slug: "s"}})
      assert Collaborative.broadcast_editor_activity(socket, :joined) == nil
    end
  end

  describe "broadcast_form_change/3 — gating" do
    test "no-op when form_key is missing" do
      socket = fake_socket(%{form_key: nil, lock_owner?: true})
      Collaborative.broadcast_form_change(socket, :meta, %{})
      # Shouldn't crash
    end

    test "no-op when not lock owner" do
      socket = fake_socket(%{form_key: "k", lock_owner?: false})
      Collaborative.broadcast_form_change(socket, :meta, %{})
      # Shouldn't crash
    end
  end
end
