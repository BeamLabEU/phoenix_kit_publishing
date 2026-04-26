defmodule PhoenixKitPublishing.Test.Endpoint do
  @moduledoc """
  Minimal Phoenix.Endpoint used by integration tests.

  `phoenix_kit_publishing` has no endpoint of its own in production —
  the host app provides one. This test endpoint exists so:

    * `Phoenix.ConnTest.get/2` can drive `Web.Controller.show/2` through
      a real Plug pipeline (session → router → controller → layout).
    * `Phoenix.LiveViewTest.live/2` can mount the admin LiveViews
      (Index / Listing / Editor / Edit / New / Preview / PostShow /
      Settings) end-to-end through the test router.

  The endpoint also serves the LiveView socket required for the LV
  smoke tests; without it `live/2` errors with "no socket configured".
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_publishing

  @session_options [
    store: :cookie,
    key: "_phoenix_kit_publishing_test_key",
    signing_salt: "publishing-test-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Session, @session_options)
  plug(PhoenixKitPublishing.Test.Router)
end
