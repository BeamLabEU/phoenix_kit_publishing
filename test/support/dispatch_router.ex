defmodule PhoenixKitPublishing.Test.DispatchRouter do
  @moduledoc """
  A router built with core's REAL `phoenix_kit_routes()` macro — the
  end-to-end harness for the publishing↔core routing seam that the
  hand-rolled `Test.Router` cannot cover: `RouterDispatch.maybe_rewrite`
  (the `call/2` override), the internal dispatch scope (localized/root
  discriminators, GET + POST routes), and `restore_path`'s pipeline
  position ahead of locale validation.

  Both live bugs of the 2026-07 wave lived exactly here and were invisible
  to the unit suites on either side: the locale plug leaking the internal
  prefix into redirects, and comment POSTs falling off the router because
  the rewrite only allowed GET/HEAD. `dispatch_e2e_test.exs` pins both.

  The macro reads the url_prefix at compile time; in the test build that
  resolves to the `"/phoenix_kit"` fallback — tests address routes under
  that prefix.
  """

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import PhoenixKitWeb.Integration

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_flash)
    plug(:put_root_layout, {PhoenixKitPublishing.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  phoenix_kit_routes()
end
