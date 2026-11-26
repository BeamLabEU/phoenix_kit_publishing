defmodule PhoenixKit.Modules.Publishing.Web.CSP do
  @moduledoc """
  The host's Content-Security-Policy nonce for the inline `<script>` and `<style>` tags this
  module renders, read from core's `PhoenixKitWeb.CSP` when the installed core
  has it.

  Core gained `PhoenixKitWeb.CSP` after this module's core floor, so every
  call here is feature-detected: on an older core `nonce/1` is `nil` (HEEx
  renders no attribute), `attr/1` is `""`, a nested session is handed on
  unchanged and the `on_mount` does nothing. Nothing else in this module
  calls `PhoenixKitWeb.CSP` directly.

      <style nonce={PhoenixKit.Modules.Publishing.Web.CSP.nonce(:style)}>
      "<style\#{PhoenixKit.Modules.Publishing.Web.CSP.attr(:style)}>…</style>"

  A nested LiveView (`live_render/3`) is a process of its own: its parent
  passes the session through `nested_session/1`, and the child restores the
  nonce with core's `on_mount` (`use PhoenixKitWeb, :live_view` has it) or,
  for a view on bare `Phoenix.LiveView`, `on_mount(PhoenixKit.Modules.Publishing.Web.CSP)`.

  Inline event handlers (`onclick="…"`) cannot take a nonce: the module
  renders none. `test/phoenix_kit_publishing/web/csp_inline_tags_test.exs`
  enforces both rules.
  """

  @core PhoenixKitWeb.CSP

  @type kind :: :script | :style

  @doc "The page's nonce for `kind`, or `nil` (none set, or a core without CSP support)."
  @spec nonce(kind) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style], do: core(:nonce, [kind], nil)

  @doc ~S' nonce="…" (with the leading space) for a tag written as a string, or "".'
  @spec attr(kind) :: String.t()
  def attr(kind) when kind in [:script, :style] do
    case nonce(kind) do
      value when is_binary(value) and value != "" -> ~s( nonce="#{Plug.HTML.html_escape(value)}")
      _ -> ""
    end
  end

  @doc "The session of a nested LiveView with the page's nonces added."
  @spec nested_session(map) :: map
  def nested_session(session) when is_map(session) do
    core(:nested_session, [session], session)
  end

  @doc "The `session:` of a live session of this module: the page's nonces."
  @spec live_session(Plug.Conn.t()) :: map
  def live_session(%Plug.Conn{} = conn), do: core(:live_session, [conn], %{})

  @doc false
  def on_mount(_arg, params, session, socket) do
    core(:on_mount, [:default, params, session, socket], {:cont, socket})
  end

  # The one call into core: `apply/3`, because the published core has no such
  # module and a direct call would not pass the compiler or dialyzer there.
  defp core(function, args, default) do
    if Code.ensure_loaded?(@core) and function_exported?(@core, function, length(args)) do
      apply(@core, function, args)
    else
      default
    end
  end
end
