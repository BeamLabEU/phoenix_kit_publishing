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
  #
  # The `layout:` option mirrors core's admin live_session, whose layout
  # renders the flash — core's own default LV layout is a passthrough, so
  # without it `put_flash/3` output would be invisible to LV tests.
  scope "/admin/publishing", PhoenixKit.Modules.Publishing.Web do
    pipe_through(:browser)

    live_session :admin_publishing,
      on_mount: [{PhoenixKitPublishing.Test.Hooks, :assign_scope}],
      layout: {PhoenixKitPublishing.Test.Layouts, :live} do
      live("/", Index, :index, as: :publishing_index)
      live("/new-group", New, :new, as: :publishing_new)
      live("/edit-group/:group", Edit, :edit, as: :publishing_edit_group)
      live("/categories/:group", CategoriesLive, :index, as: :publishing_categories)
      live("/:group", Listing, :group, as: :publishing_listing)
      live("/:group/edit", Editor, :edit, as: :publishing_editor_root)
      live("/:group/new", Editor, :new, as: :publishing_editor_new)
      live("/:group/preview", Preview, :preview, as: :publishing_preview_root)
      live("/:group/:post_uuid", PostShow, :show, as: :publishing_post_show)
      live("/:group/:post_uuid/edit", Editor, :edit, as: :publishing_editor)
      live("/:group/:post_uuid/preview", Preview, :preview, as: :publishing_preview)
    end
  end

  # One live_session with both the bare and the locale-prefixed shape, the
  # way production's `admin_routes/0` + `admin_locale_routes/0` register it.
  # `Routes.path/1` emits `/en/admin/…` under the test scope, so a `patch`
  # link rendered by the Settings LV must resolve to the SAME LiveView here
  # or the LiveViewTest proxy never delivers the patch to handle_params.
  # Declared before the public catch-all scope below, which would otherwise
  # claim `/:language/:group/*path` for the controller.
  live_session :admin_publishing_settings,
    on_mount: [{PhoenixKitPublishing.Test.Hooks, :assign_scope}],
    layout: {PhoenixKitPublishing.Test.Layouts, :live} do
    scope "/admin/settings", PhoenixKit.Modules.Publishing.Web do
      pipe_through(:browser)

      live("/publishing", Settings, :index, as: :publishing_settings)
    end

    scope "/:locale/admin/settings", PhoenixKit.Modules.Publishing.Web do
      pipe_through(:browser)

      live("/publishing", Settings, :index, as: :publishing_settings_localized)
    end
  end

  # Public controller routes (the original test surface).
  scope "/" do
    pipe_through(:browser)

    get("/:language/:group", PhoenixKit.Modules.Publishing.Web.Controller, :show)
    get("/:language/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show)
    get("/:group", PhoenixKit.Modules.Publishing.Web.Controller, :show)
    get("/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show)
    # Root-form only: production's RouterDispatch discriminator decides
    # localized-vs-root per request; this flat router can't, and a
    # "/:language/:group/*path" POST here would swallow 2-segment root
    # posts as language+group. Tests submit prefixless.
    post("/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :create_comment)
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
