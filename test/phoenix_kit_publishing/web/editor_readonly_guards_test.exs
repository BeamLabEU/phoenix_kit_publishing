defmodule PhoenixKit.Modules.Publishing.Web.EditorReadonlyGuardsTest do
  @moduledoc """
  Regression tests for H6 — read-only collaborative spectators must not be able
  to drive any write path. Each handler below short-circuits on `readonly?: true`
  and returns `{:noreply, socket}` without touching the DB. If a guard were
  removed, the handler would fall through into its mutation path (perform_save /
  enqueue_translation / create_version_from_source), which needs assigns + a DB
  this bare socket doesn't have — so it would crash here rather than silently
  letting a spectator clobber the lock owner's work.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Editor

  defp readonly_socket(extra \\ %{}) do
    %Phoenix.LiveView.Socket{
      id: "test-socket-#{System.unique_integer([:positive])}",
      assigns: Map.merge(%{__changed__: %{}, readonly?: true}, extra)
    }
  end

  test "autosave is a no-op for a read-only spectator with pending changes" do
    socket =
      readonly_socket(%{
        has_pending_changes: true,
        translation_locked?: false,
        is_autosaving: false,
        autosave_timer: nil
      })

    assert {:noreply, result} = Editor.handle_info(:autosave, socket)
    # The save branch sets is_autosaving: true; the guarded path must not.
    refute result.assigns[:is_autosaving]
  end

  test "editor_content_changed is ignored for a read-only spectator" do
    socket = readonly_socket(%{has_pending_changes: false})

    assert {:noreply, result} =
             Editor.handle_info({:editor_content_changed, %{content: "spectator edit"}}, socket)

    # No dirty-tracking / autosave scheduling happened.
    refute result.assigns[:has_pending_changes]
  end

  test "translate_to_all_languages is a no-op for a read-only spectator" do
    assert {:noreply, _} =
             Editor.handle_event("translate_to_all_languages", %{}, readonly_socket())
  end

  test "translate_missing_languages is a no-op for a read-only spectator" do
    assert {:noreply, _} =
             Editor.handle_event("translate_missing_languages", %{}, readonly_socket())
  end

  test "confirm_translation is a no-op for a read-only spectator" do
    assert {:noreply, _} = Editor.handle_event("confirm_translation", %{}, readonly_socket())
  end

  test "create_version_from_source is a no-op for a read-only spectator" do
    assert {:noreply, _} =
             Editor.handle_event("create_version_from_source", %{}, readonly_socket())
  end
end
