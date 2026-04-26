defmodule PhoenixKitPublishing.Test.Hooks do
  @moduledoc """
  `on_mount` hooks for the LiveView test endpoint.

  Production runs LiveViews inside `live_session :phoenix_kit_admin`,
  which the parent app configures to populate
  `socket.assigns[:phoenix_kit_current_scope]` from the host app's
  authentication. Our test endpoint doesn't load core's hooks, so this
  module replicates the same effect by pulling scope data from the
  test session.

  Tests set scope via `PhoenixKitPublishing.LiveCase.put_test_scope/2`
  (which calls `Plug.Test.init_test_session/2`); the `:assign_scope`
  hook below reads it back and mirrors it onto socket assigns.
  """

  import Phoenix.Component, only: [assign: 3]

  @doc """
  `on_mount` callback. Reads `"phoenix_kit_test_scope"` from session and
  assigns `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`
  onto the socket. No-op when session has no scope (LiveView mounts
  with the same nil-scope state production sees for logged-out users).
  """
  def on_mount(:assign_scope, _params, session, socket) do
    case Map.get(session, "phoenix_kit_test_scope") do
      nil ->
        {:cont, socket}

      %{user: user} = scope ->
        socket =
          socket
          |> assign(:phoenix_kit_current_scope, scope)
          |> assign(:phoenix_kit_current_user, user)

        {:cont, socket}
    end
  end
end
