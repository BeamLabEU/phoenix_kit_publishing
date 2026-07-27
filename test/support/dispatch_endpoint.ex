defmodule PhoenixKitPublishing.Test.DispatchEndpoint do
  @moduledoc """
  Endpoint for `Test.DispatchRouter` — the real-macro routing harness.
  Separate from `Test.Endpoint` because a router is baked into its
  endpoint; the hand-rolled router keeps serving the (fast, focused)
  controller/LV suites while this one exercises the dispatch seam.
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_publishing

  @session_options [
    store: :cookie,
    key: "_phoenix_kit_publishing_dispatch_test_key",
    signing_salt: "publishing-dispatch-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Session, @session_options)
  plug(PhoenixKitPublishing.Test.DispatchRouter)
end
