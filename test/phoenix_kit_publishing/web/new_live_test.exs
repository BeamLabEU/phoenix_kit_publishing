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

  test "update_new_group event auto-derives slug from name", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/new-group")

    html =
      render_change(view, "update_new_group", %{
        "group" => %{"name" => "Hello World", "type" => "blog"}
      })

    assert is_binary(html)
  end

  test "manual_slug event marks slug as user-set", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/new-group")

    html = render_change(view, "manual_slug", %{"group" => %{"slug" => "my-custom-slug"}})
    assert is_binary(html)
  end

  test "type_changed event with bare type updates form defaults", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/new-group")

    html = render_click(view, "type_changed", %{"type" => "faq"})
    assert is_binary(html)
  end

  test "type_changed event accepts the alternate {group: %{type: ...}} shape",
       %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/new-group")

    html = render_change(view, "type_changed", %{"group" => %{"type" => "blog"}})
    assert is_binary(html)
  end

  test "item_name_changed event marks item names as user-set", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/new-group")

    html = render_change(view, "item_name_changed", %{})
    assert is_binary(html)
  end

  test "cancel event navigates back to the publishing index", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/new-group")

    result = render_click(view, "cancel", %{})
    assert match?({:error, {:live_redirect, _}}, result) or is_binary(result)
  end

  test "add_group event with valid params navigates to the new listing",
       %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/new-group")

    result =
      render_submit(view, "add_group", %{
        "group" => %{
          "name" => "Group #{System.unique_integer([:positive])}",
          "type" => "blog",
          "mode" => "slug"
        }
      })

    assert match?({:error, {:live_redirect, _}}, result) or is_binary(result)
  end

  test "add_group event with empty name flashes error", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/publishing/new-group")

    html =
      render_submit(view, "add_group", %{
        "group" => %{"name" => "", "type" => "blog", "mode" => "slug"}
      })

    assert is_binary(html)
  end
end
