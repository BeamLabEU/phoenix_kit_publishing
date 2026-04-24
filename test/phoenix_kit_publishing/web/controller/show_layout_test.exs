defmodule PhoenixKit.Modules.Publishing.Web.Controller.ShowLayoutTest do
  @moduledoc """
  Regression test for Issue #8: public Publishing templates must forward
  `phoenix_kit_current_scope` into `LayoutWrapper.app_layout` so the
  parent layout sees the authenticated user. Before the fix, the layout
  attr defaulted to nil on `index/1` and the header rendered as
  logged-out even when the controller knew the user was authenticated.

  The test drives the controller through a real Plug pipeline via
  `PhoenixKitPublishing.Test.Endpoint`. The test router's
  `:assign_test_scope` plug mirrors the parent-app's
  `fetch_phoenix_kit_current_scope` plug by forwarding a scope stored
  in the calling process's dictionary onto `conn.assigns`.
  """

  use PhoenixKitPublishing.ConnCase

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User

  defp unique_name, do: "layout-group-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    group_name = unique_name()
    {:ok, group} = Groups.add_group(group_name, mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{title: "Hello World", slug: "hello-world"})

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    {:ok, group_slug: group["slug"]}
  end

  defp authenticated_scope(email) do
    %Scope{
      user: %User{uuid: Ecto.UUID.generate(), email: email},
      authenticated?: true
    }
  end

  test "forwards phoenix_kit_current_scope to the public layout", %{
    conn: conn,
    group_slug: group_slug
  } do
    email = "scope-#{System.unique_integer([:positive])}@example.com"
    with_scope(authenticated_scope(email))

    response = get(conn, "/" <> group_slug) |> html_response(200)

    assert response =~ ~s(data-current-user-email="#{email}"),
           "expected layout to receive the scoped user via phoenix_kit_current_scope"
  end

  test "layout receives no user when no scope is assigned", %{conn: conn, group_slug: group_slug} do
    response = get(conn, "/" <> group_slug) |> html_response(200)

    assert response =~ ~s(data-current-user-email=""),
           "expected layout to render empty user marker when scope is nil"
  end
end
