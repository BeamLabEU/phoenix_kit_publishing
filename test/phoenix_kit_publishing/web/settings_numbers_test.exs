defmodule PhoenixKit.Modules.Publishing.Web.SettingsNumbersTest do
  @moduledoc """
  The three numbers that weren't settable.

  `publishing_posts_per_page` is the sharpest case: the reader was already
  there in the listing code, so the setting existed and simply had no control
  — changing it meant editing the settings table by hand. The reading speed
  and the editing-lock timeout were hardcoded constants, and both are claims
  about people rather than about software: how fast this site's readers read,
  and how long this team is willing to wait for a colleague's lock.
  """

  use PhoenixKitPublishing.LiveCase, async: false

  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    :ok
  end

  defp open do
    {:ok, view, html} =
      build_conn()
      |> put_test_scope(fake_scope())
      |> live("/admin/settings/publishing")

    {view, html}
  end

  defp set(view, field, value) do
    render_change(view, "change_number_setting", %{"field" => field, "value" => value})
  end

  test "all three have a control on the settings page" do
    {_view, html} = open()

    for field <- ~w(publishing_posts_per_page publishing_reading_wpm
                    publishing_editor_lock_minutes) do
      assert html =~ field, "#{field} has no control, so it can only be changed in the database"
    end
  end

  test "posts per page reaches the code that reads it" do
    {view, _} = open()
    set(view, "publishing_posts_per_page", "7")

    assert Listing.get_per_page_setting() == 7
  end

  test "values are clamped rather than refused" do
    {view, _} = open()

    # A number typed into a box is a preference; rejecting it outright over a
    # typo helps nobody, and zero posts per page is a blank site.
    set(view, "publishing_posts_per_page", "0")
    assert Settings.get_setting("publishing_posts_per_page", nil) == "1"

    set(view, "publishing_posts_per_page", "99999")
    assert Settings.get_setting("publishing_posts_per_page", nil) == "200"
  end

  test "nonsense falls back to the default instead of persisting garbage" do
    {view, _} = open()
    set(view, "publishing_reading_wpm", "fast")

    assert Settings.get_setting("publishing_reading_wpm", nil) == "200"
  end

  test "an unknown field is ignored" do
    {view, _} = open()

    # The handler is shared, so it must not become a general-purpose writer
    # for any settings key a crafted event names.
    render_change(view, "change_number_setting", %{
      "field" => "publishing_enabled",
      "value" => "0"
    })

    refute Settings.get_setting("publishing_enabled", nil) == "0"
  end
end
