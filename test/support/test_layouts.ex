defmodule PhoenixKitPublishing.Test.Layouts do
  @moduledoc """
  Minimal root layout for the controller test endpoint.

  `phoenix_kit_publishing` is a library — in production it borrows the
  host app's endpoint, router, and root layout. For tests we ship a tiny
  root layout so `Phoenix.ConnTest` can render the public controller
  without a parent app.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>{assigns[:page_title] || "Test"}</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  # Parent layout stand-in for controller tests. `LayoutWrapper.app_layout`
  # calls this via `config :phoenix_kit, :layout, {__MODULE__, :app}` and
  # passes the full assigns set — including `:current_user`, which is
  # `Scope.user/1` when `phoenix_kit_current_scope` is forwarded.
  #
  # Embeds `data-current-user-email={email}` so the scope-forwarding
  # regression test can assert the scope reached the parent layout
  # without depending on what the real PhoenixKitWeb layout renders.
  def app(assigns) do
    email = (assigns[:current_user] && assigns[:current_user].email) || ""
    assigns = Map.put(assigns, :current_user_email, email)

    ~H"""
    <main data-current-user-email={@current_user_email}>
      <div :if={msg = Phoenix.Flash.get(@flash || %{}, :info)} id="flash-info">{msg}</div>
      <div :if={msg = Phoenix.Flash.get(@flash || %{}, :error)} id="flash-error">{msg}</div>
      <div :if={msg = Phoenix.Flash.get(@flash || %{}, :warning)} id="flash-warning">{msg}</div>
      {@inner_content}
    </main>
    """
  end

  def render(_template, assigns) do
    ~H"""
    <html>
      <body>
        <h1>Error</h1>
        <pre>{inspect(assigns[:reason] || assigns[:conn])}</pre>
      </body>
    </html>
    """
  end
end
