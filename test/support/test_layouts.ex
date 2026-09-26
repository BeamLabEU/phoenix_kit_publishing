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
  #
  # Also surfaces `:phoenix_kit_publishing_translations` via a
  # `data-testid="host-publishing-translations"` marker so the
  # boundary-audit test (see `LanguageSwitcherExposureTest`) can pin
  # that publishing's exposed conn assign actually crosses the
  # function-component layout boundary into the host's `Layouts.app`.
  #
  # Note: this layout is called via `Phoenix.Controller.template_render`
  # (controller render path), NOT as a HEEx `<.app>` component, so
  # `attr` declarations would break it — the assigns map is read
  # directly with `assigns[...]` instead.
  def app(assigns) do
    email = (assigns[:current_user] && assigns[:current_user].email) || ""
    translations = assigns[:phoenix_kit_publishing_translations] || []
    og_title = assigns[:og] && assigns[:og][:title]

    assigns =
      Map.merge(assigns, %{
        current_user_email: email,
        translations: translations,
        og_title: og_title
      })

    ~H"""
    <main data-current-user-email={@current_user_email}>
      <div :if={msg = Phoenix.Flash.get(@flash || %{}, :info)} id="flash-info">{msg}</div>
      <div :if={msg = Phoenix.Flash.get(@flash || %{}, :error)} id="flash-error">{msg}</div>
      <div :if={msg = Phoenix.Flash.get(@flash || %{}, :warning)} id="flash-warning">{msg}</div>
      <nav
        data-testid="host-publishing-translations"
        data-count={length(@translations)}
        data-og-title={@og_title}
      >
        <a :for={t <- @translations} href={t.url} data-lang={t.code}>{t.name}</a>
      </nav>
      {@inner_content}
    </main>
    """
  end

  # Live layout for the admin LiveView smoke tests (see `Test.Router`'s
  # `live_session ... layout:` options). In production the module's admin
  # LVs mount inside core's `live_session :phoenix_kit_admin`, whose layout
  # renders `flash_group` — core >= 1.7.173 made the default LV layout a
  # pure `{@inner_content}` passthrough, so without this wrapper the flash
  # from `put_flash/3` never appears in `render_click/3` output and the
  # flash-asserting tests can't observe it.
  def live(assigns) do
    ~H"""
    <main>
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
