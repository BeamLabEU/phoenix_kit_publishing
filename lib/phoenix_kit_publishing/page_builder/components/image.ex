defmodule PhoenixKit.Modules.Publishing.PageBuilder.Components.Image do
  @moduledoc """
  The `<Image>` PHK component as publishing renders it: core's
  `PhoenixKit.Modules.Shared.Components.Image`, plus an optional dark-theme
  counterpart.

      <Image file_uuid="0198…" dark_file_uuid="0199…" alt="The dashboard" />
      <Image src="/shots/light.png" dark_src="/shots/dark.png" alt="The dashboard" />

  Without `dark_src` / `dark_file_uuid` the tag goes to core's component
  untouched, so its output is exactly core's. With one, core renders BOTH
  images (each `loading="lazy"`, the same `alt`, `class` and `file_variant`)
  — an `alt` left out falls back, on each image, to its own file's Storage
  alt, as core does — and they carry a marker class, `pk-img-light` / `pk-img-dark`. The renderer
  appends `dark_image_css/0` once per document, which hides one of the two:

    * the site theme decides when `<html>` carries `data-theme` — a theme
      whose base is dark in `PhoenixKit.ThemeConfig.base_map/0` (core's
      daisyUI list plus the host's `:theme_definitions`) shows the dark
      image, any other theme the light one;
    * with no `data-theme` at all, the reader's OS preference
      (`prefers-color-scheme`) decides.

  A `<picture>` with a `prefers-color-scheme` source would follow only the OS
  and ignore a theme the reader picked on the site, so it is not used. No
  JavaScript: the switch is CSS, so it works on dead views and in sanitised
  HTML.

  Both images keep the alt text. The hidden one is `display: none`, which
  takes it out of the accessibility tree, so a screen reader announces only
  the visible one; `aria-hidden` on the dark copy would have left a dark-theme
  reader with no description at all.

  When one side does not resolve (no such file, an empty attribute) the other
  is rendered alone, as a plain core image.
  """

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Modules.Shared.Components.Image, as: CoreImage
  alias PhoenixKit.ThemeConfig

  @light_class "pk-img-light"
  @dark_class "pk-img-dark"

  # Theme names are put into a CSS selector, so only plain names are taken;
  # core validates `:theme_definitions` names the same way.
  @theme_name ~r/\A[A-Za-z0-9_-]{1,64}\z/

  # The dark daisyUI themes core ships, for a core without `base_map/0`.
  @fallback_dark_themes ~w(phoenix-dark dark synthwave halloween forest black luxury dracula
                           business night coffee dim nord sunset abyss)

  @spec render(map()) :: Phoenix.LiveView.Rendered.t() | Phoenix.HTML.safe()
  def render(assigns) do
    attributes = assigns[:attributes] || %{}

    case dark_attributes(attributes) do
      nil -> CoreImage.render(assigns)
      dark -> render_pair(assigns, attributes, dark)
    end
  end

  @doc """
  Whether the attributes ask for a light/dark pair.
  """
  @spec dark_variant?(map()) :: boolean()
  def dark_variant?(attributes) when is_map(attributes), do: dark_attributes(attributes) != nil
  def dark_variant?(_), do: false

  # The dark image's own source attributes, or nil when none is given.
  # `dark_src` wins over `dark_file_uuid`, as `src` does over `file_uuid`.
  defp dark_attributes(attributes) do
    src = present(Map.get(attributes, "dark_src"))
    uuid = present(Map.get(attributes, "dark_file_uuid"))

    cond do
      src -> %{"src" => src}
      uuid -> %{"file_uuid" => uuid}
      true -> nil
    end
  end

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_), do: nil

  defp render_pair(assigns, attributes, dark) do
    base = Map.drop(attributes, ~w(dark_src dark_file_uuid src file_uuid))
    light_attrs = Map.drop(attributes, ~w(dark_src dark_file_uuid))
    # The dark copy takes the alt the author wrote; without one, core gives it
    # the dark file's own Storage alt, as it gives the light one its own.
    dark_attrs = Map.merge(base, dark)

    light = render_core(assigns, light_attrs, @light_class)
    dark = render_core(assigns, dark_attrs, @dark_class)

    case {image?(light), image?(dark)} do
      {true, true} -> Phoenix.HTML.raw([light, dark])
      {false, true} -> CoreImage.render(Map.put(assigns, :attributes, dark_attrs))
      _ -> CoreImage.render(Map.put(assigns, :attributes, light_attrs))
    end
  end

  defp render_core(assigns, attrs, marker) do
    class =
      case Map.get(attrs, "class") do
        value when is_binary(value) and value != "" -> marker <> " " <> value
        _ -> marker
      end

    assigns
    |> Map.put(:attributes, Map.put(attrs, "class", class))
    |> CoreImage.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # Core renders a placeholder `<div>` when the source does not resolve.
  defp image?(html), do: String.contains?(html, "<img")

  @doc """
  The names of the themes whose base is dark: core's
  `ThemeConfig.base_map/0` (built-in daisyUI themes plus the host's
  `:theme_definitions`), restricted to names safe in a selector, sorted.
  """
  @spec dark_theme_names() :: [String.t()]
  def dark_theme_names do
    themes =
      if Code.ensure_loaded?(ThemeConfig) and function_exported?(ThemeConfig, :base_map, 0) do
        try do
          for {name, "dark"} <- ThemeConfig.base_map(), do: name
        rescue
          _ -> @fallback_dark_themes
        end
      else
        @fallback_dark_themes
      end

    themes
    |> Enum.filter(&(is_binary(&1) and Regex.match?(@theme_name, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The stylesheet that shows one image of each pair, for the current dark
  themes. See `dark_image_css/1`.
  """
  @spec dark_image_css() :: String.t()
  def dark_image_css, do: dark_image_css(dark_theme_names())

  @doc """
  The stylesheet for the given dark theme names (each must match
  `[A-Za-z0-9_-]+`). Every rule only HIDES one copy, so neither image's own
  `display` is ever overridden; the four conditions are disjoint:

    * `data-theme` is a dark theme → the light copy is hidden;
    * `data-theme` is any other theme → the dark copy is hidden;
    * no `data-theme`, OS prefers dark → the light copy is hidden;
    * no `data-theme`, OS prefers light → the dark copy is hidden.
  """
  @spec dark_image_css([String.t()]) :: String.t()
  def dark_image_css(names) when is_list(names) do
    dark = Enum.map_join(names, ",", &~s([data-theme="#{&1}"]))

    themed =
      case names do
        [] ->
          ":root[data-theme] .#{@dark_class}{display:none!important}"

        _ ->
          ":root:is(#{dark}) .#{@light_class}," <>
            ":root[data-theme]:not(#{dark}) .#{@dark_class}{display:none!important}"
      end

    "<style>" <>
      themed <>
      "@media (prefers-color-scheme:dark){:root:not([data-theme]) .#{@light_class}{display:none!important}}" <>
      "@media (prefers-color-scheme:light){:root:not([data-theme]) .#{@dark_class}{display:none!important}}" <>
      "</style>"
  end

  @doc """
  Whether `block` is exactly a stylesheet `dark_image_css/1` produces, for
  some list of theme names. The post-link pass uses it to recognise the sheet
  a cached render carries, whatever the theme list was when it was cached.
  """
  @spec dark_image_css?(String.t()) :: boolean()
  def dark_image_css?(block) when is_binary(block) do
    case Regex.run(~r/\A<style>:root:is\(((?:\[data-theme="[A-Za-z0-9_-]+"\],?)+)\) /, block) do
      [_, list] ->
        names = Regex.scan(~r/"([A-Za-z0-9_-]+)"/, list, capture: :all_but_first)
        block == dark_image_css(List.flatten(names))

      nil ->
        block == dark_image_css([])
    end
  end

  def dark_image_css?(_), do: false

  @doc false
  @spec marker_classes() :: {String.t(), String.t()}
  def marker_classes, do: {@light_class, @dark_class}
end
