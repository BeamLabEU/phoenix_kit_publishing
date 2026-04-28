defmodule PhoenixKitPublishing.Test.Router do
  @moduledoc """
  Minimal router for controller integration tests.

  Routes match the public URL shapes Publishing's
  `Web.Controller.show/2` action handles — both the prefixed
  (`/:language/:group`) and prefixless (`/:group`) variants.

  Tests that need to simulate an authenticated parent-app pipeline set
  `Process.put(:test_phoenix_kit_current_scope, scope)` before issuing
  the request; the `:assign_test_scope` plug forwards it onto
  `conn.assigns[:phoenix_kit_current_scope]` — the same assign the
  real parent populates via `fetch_phoenix_kit_current_scope`.
  """

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_flash)
    plug(:put_root_layout, {PhoenixKitPublishing.Test.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:assign_test_scope)
  end

  # LiveView smoke-test routes. Each admin LV gets a route here so
  # `Phoenix.LiveViewTest.live(conn, "/admin/publishing/...")` can mount
  # without a parent app. The `:assign_scope` on_mount hook reads
  # `phoenix_kit_test_scope` from session so tests can pin a scope.
  scope "/admin/publishing", PhoenixKit.Modules.Publishing.Web do
    pipe_through(:browser)

    live_session :admin_publishing,
      on_mount: [{PhoenixKitPublishing.Test.Hooks, :assign_scope}] do
      live("/", Index, :index, as: :publishing_index)
      live("/new-group", New, :new, as: :publishing_new)
      live("/edit-group/:group", Edit, :edit, as: :publishing_edit_group)
      live("/:group", Listing, :group, as: :publishing_listing)
      live("/:group/edit", Editor, :edit, as: :publishing_editor_root)
      live("/:group/new", Editor, :new, as: :publishing_editor_new)
      live("/:group/preview", Preview, :preview, as: :publishing_preview_root)
      live("/:group/:post_uuid", PostShow, :show, as: :publishing_post_show)
      live("/:group/:post_uuid/edit", Editor, :edit, as: :publishing_editor)
      live("/:group/:post_uuid/preview", Preview, :preview, as: :publishing_preview)
    end
  end

  scope "/admin/settings", PhoenixKit.Modules.Publishing.Web do
    pipe_through(:browser)

    live_session :admin_publishing_settings,
      on_mount: [{PhoenixKitPublishing.Test.Hooks, :assign_scope}] do
      live("/publishing", Settings, :index, as: :publishing_settings)
    end
  end

  # Public controller routes (the original test surface).
  scope "/" do
    pipe_through(:browser)

    get("/:language/:group", PhoenixKit.Modules.Publishing.Web.Controller, :show)
    get("/:language/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show)
    get("/:group", PhoenixKit.Modules.Publishing.Web.Controller, :show)
    get("/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show)
  end

  # Pulls a test-configured scope out of the calling test process's
  # dictionary and mirrors the parent app's `fetch_phoenix_kit_current_scope`.
  defp assign_test_scope(conn, _opts) do
    case Process.get(:test_phoenix_kit_current_scope) do
      nil -> conn
      scope -> assign(conn, :phoenix_kit_current_scope, scope)
    end
  end
end
