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
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Shared.Components.Image, as: CoreImage
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.ThemeConfig
  alias PhoenixKit.Utils.Multilang

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
      nil -> render_single(assigns, attributes)
      dark -> render_pair(assigns, attributes, dark)
    end
  end

  # One image: core's markup, with the file's width and height on the <img>
  # when they are known, so the page does not shift while it loads.
  defp render_single(assigns, attributes) do
    attributes = signed_src(attributes)

    html =
      assigns
      |> Map.put(:attributes, attributes)
      |> CoreImage.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    if image?(html),
      do: Phoenix.HTML.raw(put_dimensions(html, attributes)),
      else: Phoenix.HTML.raw(html)
  end

  @doc """
  The width and height an `<img>` of `attributes` gets: the author's own
  `width` and `height` (positive integers), else the stored dimensions of
  the copy of `file_uuid` core serves (the `file_variant` instance when it
  exists, else the original, whose dimensions fall back to the file's); nil when neither is known (a `src` image, a file without them).
  """
  @spec dimensions(map()) :: {pos_integer(), pos_integer()} | nil
  def dimensions(attributes) do
    author_dimensions(attributes) || stored_dimensions(attributes)
  end

  defp author_dimensions(attributes) do
    with {:ok, w} <- positive_integer(Map.get(attributes, "width")),
         {:ok, h} <- positive_integer(Map.get(attributes, "height")) do
      {w, h}
    else
      _ -> nil
    end
  end

  defp positive_integer(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp positive_integer(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp positive_integer(_), do: :error

  defp stored_dimensions(%{"file_uuid" => uuid} = attributes)
       when is_binary(uuid) and uuid != "" do
    variant = Map.get(attributes, "file_variant") || "original"

    # Only the copy core serves: the variant when it exists, else the
    # original. A variant without stored dimensions gets none, never the
    # original's (a cropped thumbnail has another ratio); the original falls
    # back to the file row, which describes it.
    case variant != "original" && Storage.get_file_instance_by_name(uuid, variant) do
      %{} = instance -> positive_dimensions(instance)
      _ -> original_dimensions(uuid)
    end
  rescue
    # a uuid that is not one, storage unavailable: no dimensions, never a
    # failed render
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp stored_dimensions(_attributes), do: nil

  defp original_dimensions(uuid) do
    with nil <- positive_dimensions(Storage.get_file_instance_by_name(uuid, "original")) do
      positive_dimensions(Storage.get_file(uuid))
    end
  end

  defp positive_dimensions(%{width: w, height: h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: {w, h}

  defp positive_dimensions(_), do: nil

  # width/height go on the <img> that has none yet; core's h-auto keeps the
  # ratio while the attributes reserve the box.
  defp put_dimensions(html, attributes) do
    case dimensions(attributes) do
      {w, h} ->
        # the first <img> tag; quoted values are blanked before looking for
        # an attribute, so an alt reading "width=640" is not one
        Regex.replace(~r/<img\s[^>]*>/, html, &size_tag(&1, w, h), global: false)

      nil ->
        html
    end
  end

  defp size_tag(tag, w, h) do
    unquoted = Regex.replace(~r/"[^"]*"|'[^']*'/, tag, "\"\"")

    if Regex.match?(~r/\s(?:width|height)\s*=/i, unquoted),
      do: tag,
      else: String.replace_prefix(tag, "<img", ~s(<img width="#{w}" height="#{h}"))
  end

  @doc """
  Whether the attributes ask for a light/dark pair.
  """
  @spec dark_variant?(map()) :: boolean()
  def dark_variant?(attributes) when is_map(attributes), do: dark_attributes(attributes) != nil
  def dark_variant?(_), do: false

  # The dark image's own source attributes, or nil when none is given.
  # `dark_src` wins over `dark_file_uuid`, as `src` does over `file_uuid`.
  # Inside `Renderer.with_signed_files/2` (a protected post's body) a stored
  # file is given a signed kit URL as its `src`, so the browser loads it
  # through the file route core's access guard watches, never from a public
  # bucket's own URL. The Storage alt core would have looked up comes along;
  # `file_uuid` stays for the dimensions. An unknown file is left alone (core
  # renders its placeholder).
  @doc false
  @spec signed_src(map()) :: map()
  def signed_src(attributes) do
    uuid = present(Map.get(attributes, "file_uuid"))

    if (Renderer.signed_files?() and uuid) && is_nil(present(Map.get(attributes, "src"))) do
      sign(attributes, uuid)
    else
      attributes
    end
  end

  defp sign(attributes, uuid) do
    case Storage.get_file(uuid) do
      nil ->
        attributes

      _file ->
        wanted = Map.get(attributes, "file_variant") || "original"

        variant =
          if wanted != "original" and is_nil(Storage.get_file_instance_by_name(uuid, wanted)),
            do: "original",
            else: wanted

        attributes
        |> Map.put("src", URLSigner.signed_url(uuid, variant))
        |> Map.put_new_lazy("alt", fn -> storage_alt(uuid) end)
    end
  rescue
    _ -> attributes
  end

  defp storage_alt(uuid) do
    Storage.translated_alt_by_uuid(uuid, Multilang.current_locale()) || ""
  rescue
    _ -> ""
  end

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
      {false, true} -> render_single(Map.put(assigns, :attributes, dark_attrs), dark_attrs)
      _ -> render_single(Map.put(assigns, :attributes, light_attrs), light_attrs)
    end
  end

  defp render_core(assigns, attrs, marker) do
    attrs = signed_src(attrs)

    class =
      case Map.get(attrs, "class") do
        value when is_binary(value) and value != "" -> marker <> " " <> value
        _ -> marker
      end

    html =
      assigns
      |> Map.put(:attributes, Map.put(attrs, "class", class))
      |> CoreImage.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    if image?(html), do: put_dimensions(html, attrs), else: html
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
      try do
        for {name, "dark"} <- ThemeConfig.base_map(), do: name
      rescue
        _ -> @fallback_dark_themes
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
