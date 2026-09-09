defmodule PhoenixKit.Modules.Publishing.PageBuilder.Components.Embed do
  @moduledoc """
  The `<Embed>` PHK component — a live, interactive demo inside a post body:

      <Embed src="/demos/leaf" height="520" title="Try the editor" />
      <Embed src="https://example.com/widget" caption="Pan and zoom the sample" />

  Renders a sandboxed, lazy-loaded `<iframe>`. The point is prose-then-play:
  a post introduces a tool and the reader tries the real thing right under
  the paragraph — an editor, an image viewer, any page that can stand on its
  own. The demo is just a page (same host or external); this component adds
  the rails around it:

    * `loading="lazy"` — a post with several demos doesn't stampede page load;
      each iframe loads as it scrolls into view.
    * a sandbox that still permits scripts, forms and same-origin — a
      same-origin LiveView demo needs its session cookie and websocket.
      For an EXTERNAL src the sandbox is real defense-in-depth; the src
      posture itself is `<Audio>`'s: http(s) or root-relative only.
    * `height` clamped to 160–1200 (default 480) so a typo can't produce a
      zero-height or viewport-swallowing frame.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitPublishing.Gettext

  @default_height 480
  @min_height 160
  @max_height 1200

  def render(assigns) do
    attributes = assigns[:attributes] || %{}

    assigns =
      assigns
      |> assign(:src, resolve_src(attributes))
      |> assign(:height, resolve_height(attributes))
      |> assign(:title, Map.get(attributes, "title"))
      |> assign(:caption, Map.get(attributes, "caption"))

    ~H"""
    <figure :if={@src} class="my-6">
      <figcaption :if={@title} class="mb-1 text-sm font-semibold">{@title}</figcaption>
      <iframe
        src={@src}
        title={@title || gettext("Interactive demo")}
        loading="lazy"
        sandbox="allow-scripts allow-same-origin allow-forms allow-popups"
        class="w-full rounded-lg border border-base-300 bg-base-100"
        style={"height: #{@height}px;"}
      >
      </iframe>
      <figcaption :if={@caption} class="mt-1 text-xs text-base-content/60">{@caption}</figcaption>
    </figure>
    """
  end

  defp resolve_src(attributes) do
    src = Map.get(attributes, "src")
    if is_binary(src) and safe_src?(src), do: src
  end

  defp resolve_height(attributes) do
    case Integer.parse(to_string(Map.get(attributes, "height", ""))) do
      {h, _} -> h |> max(@min_height) |> min(@max_height)
      :error -> @default_height
    end
  end

  defp safe_src?("/" <> _), do: true
  defp safe_src?("http://" <> _), do: true
  defp safe_src?("https://" <> _), do: true
  defp safe_src?(_), do: false
end
