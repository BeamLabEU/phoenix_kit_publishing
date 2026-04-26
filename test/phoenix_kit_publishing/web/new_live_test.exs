defmodule PhoenixKit.Modules.Publishing.Web.NewLiveTest do
  @moduledoc """
  Smoke tests for the New (Create) Group form.

  Pins the C5 `phx-disable-with` addition on the submit button.
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    :ok
  end

  test "create form renders with phx-disable-with on submit", %{conn: conn} do
    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/new-group")

    assert html =~ "Create a New Publishing Group"
    assert html =~ ~s|phx-disable-with="Creating…"|
  end

  test "handle_info catch-all swallows unexpected messages without crashing",
       %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/new-group")

    send(view.pid, {:bogus_pubsub_message, "ignored"})
    send(view.pid, :unexpected_atom)
    assert is_binary(render(view))
  end
end
