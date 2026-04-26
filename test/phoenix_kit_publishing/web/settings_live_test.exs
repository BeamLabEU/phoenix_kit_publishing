defmodule PhoenixKit.Modules.Publishing.Web.SettingsLiveTest do
  @moduledoc """
  LiveView smoke tests for the Settings admin page.

  Pins the C5 + PR #9 follow-up changes:

    * Mount no longer reads from the DB (handle_params does). Two
      mount/handle_params cycles per page load went from ~14 round-trips
      down to ~7.
    * Cache management buttons now have `phx-disable-with` so users
      don't double-click during async cache work.
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English (United States)",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          }
        ]
      })

    :ok
  end

  test "settings page mounts and renders the cache table", %{conn: conn} do
    {:ok, _group} =
      Groups.add_group("Settings LV #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/settings/publishing")

    assert html =~ "Publishing Settings"
    assert html =~ "Listing Cache"
    assert html =~ "Render Cache"
    assert html =~ "Default Language Without Prefix"
  end

  test "regenerate cache buttons carry phx-disable-with", %{conn: conn} do
    {:ok, _group} =
      Groups.add_group("Settings PXDisable #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, _view, html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/settings/publishing")

    # The "Regenerate All" button is the highest-leverage one.
    assert html =~ ~s|phx-click="regenerate_all_caches"|
    assert html =~ ~s|phx-disable-with="Regenerating…"|

    # Clear render cache (destructive, takes time)
    assert html =~ ~s|phx-click="clear_render_cache"|
    assert html =~ ~s|phx-disable-with="Clearing…"|
  end

  test "default-language-no-prefix toggle is wired up", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> put_test_scope(fake_scope())
      |> live("/admin/settings/publishing")

    initial = Settings.get_boolean_setting("publishing_default_language_no_prefix", false)

    render_click(view, "toggle_default_language_no_prefix")

    final = Settings.get_boolean_setting("publishing_default_language_no_prefix", false)
    assert final != initial
  end
end
