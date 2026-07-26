defmodule PhoenixKit.Modules.Publishing.PageBuilder.Components.Audio do
  @moduledoc """
  The `<Audio>` PHK component — inline audio in a post body:

      <Audio file_uuid="0198…" title="Episode 12" />
      <Audio src="https://cdn.example.com/ep12.mp3" caption="Interview, 42 min" />

  Renders a native `<audio controls preload="none">` (no JS, streams on
  demand) with an optional caption. `file_uuid` resolves through core
  Storage's signed URLs — the same mechanism `<Image>` uses — so files
  served from local storage work too; `src` takes any URL. `file_uuid`
  wins when both are given. Lives in publishing (not core's shared
  components) because publishing owns the resolver wiring; promote to core
  when a sibling module needs it.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitPublishing.Gettext

  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Modules.Storage.URLSigner

  def render(assigns) do
    attributes = assigns[:attributes] || %{}

    src = resolve_src(attributes)

    assigns =
      assigns
      |> assign(:src, src)
      |> assign(:title, Map.get(attributes, "title"))
      |> assign(:caption, Map.get(attributes, "caption"))

    ~H"""
    <figure :if={@src} class="my-6">
      <figcaption :if={@title} class="mb-1 text-sm font-semibold">{@title}</figcaption>
      <audio controls preload="none" class="w-full" src={@src}>
        {gettext("Your browser does not support the audio element.")}
      </audio>
      <figcaption :if={@caption} class="mt-1 text-xs text-base-content/60">{@caption}</figcaption>
    </figure>
    """
  end

  defp resolve_src(attributes) do
    file_uuid = Map.get(attributes, "file_uuid")
    src = Map.get(attributes, "src")

    cond do
      is_binary(file_uuid) and Shared.uuid_format?(file_uuid) ->
        URLSigner.signed_url(file_uuid, "original")

      is_binary(src) and safe_src?(src) ->
        src

      true ->
        nil
    end
  end

  # http(s) or root-relative only — same posture as the sanitizer's URL
  # allowlist; a javascript:/data: src never reaches the element.
  defp safe_src?("/" <> _), do: true
  defp safe_src?("http://" <> _), do: true
  defp safe_src?("https://" <> _), do: true
  defp safe_src?(_), do: false
end
