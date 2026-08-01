defmodule PhoenixKit.Modules.Publishing.PageBuilder.Renderer do
  @moduledoc """
  Renders AST nodes to HTML by delegating to component modules.
  """

  alias Phoenix.HTML.Safe

  @doc """
  Renders an AST node to HTML.
  """
  def render(ast, assigns) when is_map(ast) do
    case resolve_component(ast.type) do
      {:ok, component_module} ->
        render_component(component_module, ast, assigns)

      {:error, :not_found} ->
        # Fallback for unknown components
        render_unknown(ast, assigns)
    end
  end

  def render(ast, _assigns) when is_list(ast) do
    {:ok,
     Phoenix.HTML.raw(
       Enum.map_join(ast, fn node ->
         case render(node, %{}) do
           {:ok, html} -> Phoenix.HTML.safe_to_string(html)
           {:error, _} -> ""
         end
       end)
     )}
  end

  def render(content, _assigns) when is_binary(content) do
    {:ok, Phoenix.HTML.raw(content)}
  end

  # Resolve component type to module. Page/Hero were removed with the Pages module
  # (see core 0fc3de09); their tags now fall through to the catch-all.
  defp resolve_component(:headline), do: {:ok, PhoenixKit.Modules.Shared.Components.Headline}

  defp resolve_component(:subheadline),
    do: {:ok, PhoenixKit.Modules.Shared.Components.Subheadline}

  defp resolve_component(:cta), do: {:ok, PhoenixKit.Modules.Shared.Components.CTA}
  defp resolve_component(:image), do: {:ok, PhoenixKit.Modules.Shared.Components.Image}
  defp resolve_component(:video), do: {:ok, PhoenixKit.Modules.Shared.Components.Video}

  defp resolve_component(:audio),
    do: {:ok, PhoenixKit.Modules.Publishing.PageBuilder.Components.Audio}

  defp resolve_component(:entityform),
    do: {:ok, PhoenixKitEntities.Components.EntityForm}

  defp resolve_component(_), do: {:error, :not_found}

  # Render using the component module
  defp render_component(component_module, ast, assigns) do
    component_assigns = build_component_assigns(ast, assigns)

    try do
      html = component_module.render(component_assigns)
      {:ok, wrap_stretch(html, ast.attributes)}
    rescue
      e ->
        {:error, {:render_error, e}}
    end
  end

  # ===========================================================================
  # Stretch / align lanes
  #
  # Any PHK component can break out of the prose column via two attributes,
  # applied here at the renderer level so every component (Image, Headline,
  # Video, …) gets them without per-component changes:
  #
  #   <Image stretch="20" …/>   → 20% wider than the column, centered
  #   <Image align="wide" …/>   → the +30% preset
  #   <Image align="full" …/>   → full-bleed to the viewport (1rem gutter)
  #
  # Mechanism: negative inline margins on a block wrapper (width:auto widens
  # with them). The min()/max() guards clamp to the space actually available
  # between the column and the viewport — on phones, where the column ≈
  # viewport, the margins collapse to 0 and the element stays in the column.
  # Works without JS; the style is built only from validated values.
  # ===========================================================================

  @max_stretch 100
  @wide_preset 30

  @doc false
  # Public for the inline (self-closing) component path in
  # Publishing.Renderer, which bypasses this module's render_component/3.
  def wrap_stretch(html, attributes) do
    case stretch_style(attributes) do
      nil ->
        html

      style ->
        # Components return %Phoenix.LiveView.Rendered{} — Safe.to_iodata/1
        # handles that; safe_to_string/1 would not.
        Phoenix.HTML.raw([
          ~s(<div class="pk-stretch" style="),
          style,
          ~s(">),
          Safe.to_iodata(html),
          "</div>"
        ])
    end
  end

  # An explicit stretch percent wins over an align preset. `align="none"` (and
  # `stretch="0"`) mean "stay inside the text column" — worth naming, because
  # a component whose DEFAULT is full-bleed (e.g. <Showcase>) otherwise has no
  # way to opt back in to the column.
  defp stretch_style(attributes) do
    stretch = parse_stretch(Map.get(attributes, "stretch"))
    align = Map.get(attributes, "align")

    cond do
      align == "none" -> nil
      stretch -> stretch_margin(stretch)
      align == "wide" -> stretch_margin(@wide_preset)
      align == "full" -> full_bleed_margin()
      true -> nil
    end
  end

  # `stretch` is the TOTAL extra width in percent of the column ("20" = the
  # boss's "20% more than the column"), so half hangs out each side.
  defp stretch_margin(percent) do
    half = percent / 2

    "margin-inline: calc(-1 * min(#{half}%, max(0px, (100vw - 100%) / 2 - 1rem)))"
  end

  defp full_bleed_margin do
    "margin-inline: calc(-1 * max(0px, (100vw - 100%) / 2 - 1rem))"
  end

  defp parse_stretch(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 and n <= @max_stretch -> n
      _ -> nil
    end
  end

  defp parse_stretch(_), do: nil

  # Build assigns map for component
  defp build_component_assigns(ast, parent_assigns) do
    base_assigns = %{
      __changed__: nil,
      variant: Map.get(ast.attributes, "variant", "default"),
      attributes: ast.attributes,
      content: ast[:content],
      children: ast[:children] || []
    }

    Map.merge(parent_assigns, base_assigns)
  end

  # Fallback renderer for unknown components. Builds the wrapper `<div>` as
  # a safe iolist so the literal class attribute never gets interpolated
  # from data — only the AST-derived `content` (admin-trusted) is raw'd.
  defp render_unknown(ast, assigns) do
    content =
      cond do
        ast[:content] ->
          ast.content

        ast[:children] ->
          Enum.map_join(ast.children, &render_child_to_string(&1, assigns))

        true ->
          ""
      end

    {:ok,
     Phoenix.HTML.raw([
       ~s(<div class="unknown-component">),
       content,
       "</div>"
     ])}
  end

  defp render_child_to_string(child, assigns) do
    case render(child, assigns) do
      {:ok, html} -> Phoenix.HTML.safe_to_string(html)
      _ -> ""
    end
  end
end
