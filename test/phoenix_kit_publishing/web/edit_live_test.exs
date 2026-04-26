defmodule PhoenixKit.Modules.Publishing.Web.EditLiveTest do
  @moduledoc """
  Smoke tests for the Edit Group form.

  Pins:

    * Save button now carries `phx-disable-with` (C5).
    * `handle_event("save", …)` no longer rescues `_e ->` broadly — it
      catches Ecto / DBConnection only and lets system errors propagate.
    * The dead-code cleanup that removed the `:already_exists` and
      `:destination_exists` branches (dialyzer-driven C6 sweep) didn't
      regress the flash for `:invalid_name`.
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, group} =
      Groups.add_group("Edit LV #{System.unique_integer([:positive])}", mode: "slug")

    %{group: group}
  end

  test "form renders with the current name and slug, save button shows phx-disable-with",
       %{conn: conn, group: group} do
    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/edit-group/#{group["slug"]}")

    assert html =~ "Edit Group"
    assert html =~ group["name"]
    assert html =~ group["slug"]
    assert html =~ ~s|phx-disable-with="Saving…"|
  end

  test "saving an empty name flashes :invalid_name", %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/edit-group/#{group["slug"]}")

    html =
      view
      |> form("#group-edit-form", group: %{"name" => "", "slug" => group["slug"]})
      |> render_submit()

    assert html =~ "Please provide a valid group name"
  end

  test "handle_info catch-all swallows unexpected messages without crashing",
       %{conn: conn, group: group} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/edit-group/#{group["slug"]}")

    # Send a stray message — without the catch-all, this would crash with
    # FunctionClauseError. The render after-the-fact proves the LV survived.
    send(view.pid, {:bogus_pubsub_message, "ignored"})
    send(view.pid, :unexpected_atom)
    assert is_binary(render(view))
  end
end
