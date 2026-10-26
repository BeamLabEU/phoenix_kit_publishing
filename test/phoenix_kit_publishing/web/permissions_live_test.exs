defmodule PhoenixKit.Modules.Publishing.Web.PermissionsLiveTest do
  @moduledoc """
  `publishing.manage` (create, edit, trash, restore, delete groups) and
  `publishing.settings` (the settings page), on top of the base key.

  Each refusal is asserted at mount AND on a crafted event the UI would not
  offer, so removing either check fails a test. Pages that refuse at mount
  are driven by calling `handle_event/3` directly with a socket carrying the
  narrower scope — the only way to send an event to a page that never
  mounted.
  """

  use PhoenixKitPublishing.LiveCase

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.PermissionBackfill
  alias PhoenixKit.Modules.Publishing.Web
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}

  @base_only ["publishing"]

  defp group! do
    {:ok, group} =
      Groups.add_group("Perm #{System.unique_integer([:positive])}", mode: "slug")

    group
  end

  defp slugs(status), do: Publishing.list_groups(status) |> Enum.map(& &1["slug"])

  defp socket(scope, extra \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            phoenix_kit_current_scope: scope,
            phoenix_kit_current_user: scope.user
          },
          extra
        )
    }
  end

  defp error_flash(%Phoenix.LiveView.Socket{assigns: %{flash: flash}}), do: flash["error"]

  describe "Index: group trash / restore / delete" do
    test "the base key alone is refused on every group event and sees no group buttons",
         %{conn: conn} do
      active = group!()
      trashed = group!()
      {:ok, _} = Groups.trash_group(trashed["slug"])

      {:ok, view, html} =
        conn
        |> put_test_scope(fake_scope(permissions: @base_only))
        |> live("/admin/publishing")

      refute html =~ ~s|phx-click="trash_group"|
      refute html =~ "/admin/publishing/new-group"

      assert render_click(view, "trash_group", %{"slug" => active["slug"]}) =~
               "permission to manage publishing groups"

      render_click(view, "restore_group", %{"slug" => trashed["slug"]})
      render_click(view, "delete_group", %{"slug" => trashed["slug"]})

      assert active["slug"] in slugs("active")
      assert trashed["slug"] in slugs("trashed")
    end

    test "publishing.manage may trash and permanently delete", %{conn: conn} do
      group = group!()

      {:ok, view, html} =
        conn
        |> put_test_scope(fake_scope(permissions: ["publishing", "publishing.manage"]))
        |> live("/admin/publishing")

      assert html =~ ~s|phx-click="trash_group"|

      render_click(view, "trash_group", %{"slug" => group["slug"]})
      assert group["slug"] in slugs("trashed")

      render_click(view, "delete_group", %{"slug" => group["slug"]})
      refute group["slug"] in slugs("trashed")
    end
  end

  describe "New group" do
    test "the base key alone is redirected away at mount", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               conn
               |> put_test_scope(fake_scope(permissions: @base_only))
               |> live("/admin/publishing/new-group")

      assert to =~ "/admin/publishing"
    end

    test "a crafted add_group without publishing.manage creates nothing" do
      name = "Crafted #{System.unique_integer([:positive])}"
      slug = "crafted-#{System.unique_integer([:positive])}"
      params = %{"name" => name, "slug" => slug, "mode" => "slug", "type" => "blog"}

      {:noreply, s} =
        Web.New.handle_event(
          "add_group",
          %{"group" => params},
          socket(fake_scope(permissions: @base_only))
        )

      assert error_flash(s) =~ "permission"
      refute slug in slugs("active")
    end

    test "publishing.manage mounts the form", %{conn: conn} do
      assert {:ok, _view, _html} =
               conn
               |> put_test_scope(fake_scope(permissions: ["publishing", "publishing.manage"]))
               |> live("/admin/publishing/new-group")
    end
  end

  describe "Edit group" do
    test "the base key alone is redirected away at mount", %{conn: conn} do
      group = group!()

      assert {:error, {:live_redirect, _}} =
               conn
               |> put_test_scope(fake_scope(permissions: @base_only))
               |> live("/admin/publishing/edit-group/#{group["slug"]}")
    end

    test "a crafted save without publishing.manage changes nothing" do
      group = group!()

      {:noreply, s} =
        Web.Edit.handle_event(
          "save",
          %{"group" => %{"name" => "Renamed", "slug" => group["slug"]}},
          socket(fake_scope(permissions: @base_only), %{group: group})
        )

      assert error_flash(s) =~ "permission"

      assert Enum.find(Publishing.list_groups("active"), &(&1["slug"] == group["slug"]))["name"] ==
               group["name"]
    end
  end

  describe "Settings" do
    test "the base key alone is redirected away at mount", %{conn: conn} do
      assert {:error, {:live_redirect, _}} =
               conn
               |> put_test_scope(fake_scope(permissions: @base_only))
               |> live("/admin/settings/publishing")
    end

    test "a crafted settings event without publishing.settings writes nothing" do
      {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)

      {:noreply, s} =
        Web.Settings.handle_event(
          "toggle_feeds_enabled",
          %{},
          socket(fake_scope(permissions: ["publishing", "publishing.manage"]))
        )

      assert error_flash(s) =~ "permission"
      assert Settings.get_boolean_setting("publishing_feeds_enabled", true)
    end

    test "publishing.settings mounts the page", %{conn: conn} do
      assert {:ok, _view, _html} =
               conn
               |> put_test_scope(fake_scope(permissions: ["publishing", "publishing.settings"]))
               |> live("/admin/settings/publishing")
    end
  end

  describe "migrate_legacy/0 backfill" do
    defp role_with(keys) do
      {:ok, role} =
        Roles.create_role(%{name: "Role-#{System.unique_integer([:positive])}", description: "t"})

      for key <- keys, do: {:ok, _} = Permissions.grant_permission(role.uuid, key, nil)
      role
    end

    defp keys(role), do: Permissions.get_permissions_for_role(role.uuid)

    test "grants both keys once to roles holding publishing, and sets each flag" do
      holder = role_with(["publishing"])
      outsider = role_with([])

      assert :ok = Publishing.migrate_legacy()

      for key <- ~w(publishing.manage publishing.settings) do
        assert key in keys(holder)
        refute key in keys(outsider)
      end

      assert Settings.get_setting("publishing_manage_backfilled") == "true"
      assert Settings.get_setting("publishing_settings_backfilled") == "true"

      # A role given the base key after the backfill gets the narrow meaning.
      late = role_with(["publishing"])
      assert :ok = Publishing.migrate_legacy()
      assert keys(late) == ["publishing"]
    end

    test "a failed grant leaves the flag unset, so the next boot retries" do
      holder = role_with(["publishing"])
      failing = fn _role, _key, _by -> {:error, :boom} end

      assert {:error, _} =
               PermissionBackfill.run(
                 "publishing",
                 "publishing.manage",
                 "publishing_manage_backfilled",
                 failing
               )

      refute Settings.get_setting("publishing_manage_backfilled") == "true"
      refute "publishing.manage" in keys(holder)

      assert :ok =
               PermissionBackfill.run(
                 "publishing",
                 "publishing.manage",
                 "publishing_manage_backfilled"
               )

      assert "publishing.manage" in keys(holder)
    end
  end
end
