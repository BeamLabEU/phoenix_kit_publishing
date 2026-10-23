defmodule PhoenixKit.Modules.Publishing.Renderer.Sanitizer do
  @moduledoc """
  Allow-list HTML sanitiser for rendered post bodies (issue #60).

  Built on `MDEx.safe_html/2` (ammonia, an html5ever-based cleaner that
  re-serialises the document, so its output is always balanced): the markdown
  renderer keeps `unsafe: true` — admins author inline HTML — and the HTML
  that comes out is cleaned here before it is cached or served. A body that
  ends inside an open tag, attribute or comment cannot leak into the markup
  that is appended after it, because every piece is closed by the cleaner
  first.

  Two profiles share one base allow-list:

    * `author/1` — HTML that came out of an author's Markdown. Layout, text,
      tables, `details`, images, links, task-list checkboxes, classes, ids,
      `data-*` / `aria-*`. No `iframe`/`form`/`object`/`embed`/media elements.
    * `page/1` — the assembled page: `author/1` plus what the renderer's own
      components emit (`section` for notes, `iframe` for `<Embed>`,
      `audio`/`video`/`source`, the `<EntityForm>` form controls).

  `<style>` is in neither list: the cleaner removes every `<style>` element
  with its content, in both profiles. The renderer's own stylesheets are
  static text it appends AFTER cleaning, so nothing is lifted out of a
  document and put back.

  Common to both: only `http`, `https`, `mailto` and `tel` URLs plus relative
  ones; no `on*` attributes; a `style` attribute is kept or dropped as a
  whole (`style_value_safe?/1`): it is dropped when any declaration could
  execute or fetch something.
  """

  @tags ~w(a abbr acronym area article aside b bdi bdo blockquote br caption center cite
           code col colgroup data dd del details dfn div dl dt em figcaption figure footer
           h1 h2 h3 h4 h5 h6 header hgroup hr i img input ins kbd li map mark nav ol p pre q rp rt
           rtc ruby s samp small span strike strong sub summary sup table tbody td tfoot th
           thead time tr tt u ul var wbr)

  @page_tags ~w(section audio video source iframe form label select option optgroup
                textarea button fieldset legend picture)

  @generic_attributes ~w(class id lang title dir role style)
  @generic_prefixes ["data-", "aria-"]

  @tag_attributes %{
    "a" => ~w(href hreflang rel target download),
    "img" => ~w(align alt height src srcset sizes width loading decoding),
    "input" => ~w(type checked disabled),
    "ol" => ~w(start type reversed),
    "details" => ~w(open),
    "td" => ~w(align colspan rowspan headers valign),
    "th" => ~w(align colspan rowspan headers scope valign),
    "table" => ~w(align summary),
    "code" => ~w(translate tabindex),
    "time" => ~w(datetime),
    "blockquote" => ~w(cite),
    "q" => ~w(cite),
    "del" => ~w(cite datetime),
    "ins" => ~w(cite datetime),
    "col" => ~w(span),
    "colgroup" => ~w(span)
  }

  @page_tag_attributes %{
    "iframe" =>
      ~w(src title loading sandbox allow allowfullscreen referrerpolicy frameborder width height),
    "audio" => ~w(src controls preload loop muted autoplay),
    "video" => ~w(src controls preload loop muted autoplay poster playsinline width height),
    "source" => ~w(src srcset type media sizes),
    "form" => ~w(action method enctype novalidate autocomplete name),
    "input" =>
      ~w(name value placeholder required readonly min max step pattern minlength maxlength autocomplete multiple accept),
    "label" => ~w(for),
    "select" => ~w(name required disabled multiple size),
    "option" => ~w(value selected disabled label),
    "optgroup" => ~w(label disabled),
    "textarea" => ~w(name placeholder required readonly disabled rows cols minlength maxlength),
    "button" => ~w(type name value disabled),
    "fieldset" => ~w(disabled name)
  }

  @url_schemes ~w(http https mailto tel)

  @doc """
  Cleans HTML produced from author Markdown (strict profile).
  """
  @spec author(String.t()) :: String.t()
  def author(html) when is_binary(html), do: clean(html, :author)

  @doc """
  Cleans an assembled page (author profile plus the renderer's own components).
  """
  @spec page(String.t()) :: String.t()
  def page(html) when is_binary(html), do: clean(html, :page)

  @style_denied_fragments [
    "expression",
    "javascript",
    "vbscript",
    "@import",
    "url(",
    "image-set(",
    "image(",
    "cross-fade(",
    "paint(",
    "attr(",
    "\\",
    "&#",
    "&lt;",
    "&gt;",
    "<",
    "/*"
  ]

  # Exact property names, so `scroll-behavior` and `overscroll-behavior` stay.
  @style_denied_properties ~w(behavior -moz-binding -webkit-binding binding)

  @doc """
  Whether a `style` attribute value is plain declarations: no `expression()`,
  scripts, `@import`, backslash escapes, entities, markup, or a function that
  can fetch or run something (`url()`, `image-set()`, `image()`,
  `cross-fade()`, `paint()`, `attr()`), and no `behavior` / `binding`
  property. The attribute is kept or dropped as a whole.
  """
  @spec style_value_safe?(String.t()) :: boolean()
  def style_value_safe?(value) when is_binary(value) do
    down = value |> String.downcase() |> String.replace(~r/\s+/, "")

    not String.contains?(down, @style_denied_fragments) and
      not Enum.any?(String.split(down, ";"), &denied_property?/1)
  end

  defp denied_property?(declaration) do
    [property | _] = String.split(declaration, ":", parts: 2)
    property in @style_denied_properties
  end

  # ---------------------------------------------------------------------------

  defp clean(html, profile) do
    html
    |> safe_html(
      sanitize: sanitize_options(profile),
      escape: [content: false, curly_braces_in_code: false]
    )
    |> restore_nbsp()
    |> filter_tags()
  end

  # `MDEx.safe_html/2` types `:escape` as `[atom()]`, yet the option is a keyword list: its docs
  # and its implementation read `escape: [content: false]`. Called directly, dialyzer takes the
  # call for one that can never succeed and reports every caller up to the renderer as having no
  # return. `apply/3` with a non-literal argument list keeps the spec out of the analysis.
  defp safe_html(html, options) do
    args = [html, options]
    apply(MDEx, :safe_html, args)
  end

  defp sanitize_options(profile) do
    page? = profile == :page

    [
      tags: if(page?, do: @tags ++ @page_tags, else: @tags),
      tag_attributes:
        if(page?,
          do: Map.merge(@tag_attributes, @page_tag_attributes, &merge_attrs/3),
          else: @tag_attributes
        ),
      generic_attributes: @generic_attributes,
      generic_attribute_prefixes: @generic_prefixes,
      url_schemes: @url_schemes,
      url_relative: :passthrough,
      link_rel: nil,
      strip_comments: true
    ]
  end

  defp merge_attrs(_tag, a, b), do: Enum.uniq(a ++ b)

  # The cleaner writes U+00A0 back as `&nbsp;`. comrak (and the blank-line
  # spacers) emit the character itself; keep the output byte-identical.
  defp restore_nbsp(html), do: String.replace(html, "&nbsp;", "\u00A0")

  # Per-tag fix-ups on the cleaner's own output, where attribute values are
  # always double-quoted and `<`, `>` are escaped, so a tag-shaped match cannot
  # span two elements and the scan is linear. Text (code blocks, prose) is
  # never touched, only the inside of tags:
  #   * a `style` attribute is dropped when its value is not plain declarations
  #     (the cleaner cannot check values);
  #   * the valueless media attributes are written bare again — the cleaner
  #     writes `controls=""`, the components emit `controls`.
  @bare_media_attribute ~r/ (?:controls|autoplay|loop|muted|playsinline|allowfullscreen)=""(?=[\s>])/

  defp filter_tags(html) do
    if String.contains?(html, [~s( style="), ~s(="")]) do
      Regex.replace(~r/<[a-zA-Z][^<>]*>/, html, &filter_tag/1)
    else
      html
    end
  end

  defp filter_tag(tag) do
    tag
    |> drop_unsafe_style()
    |> bare_media_attributes()
  end

  defp drop_unsafe_style(tag) do
    if String.contains?(tag, ~s( style=")),
      do: Regex.replace(~r/ style="([^"]*)"/, tag, &keep_safe_style/2),
      else: tag
  end

  defp keep_safe_style(full, value), do: if(style_value_safe?(value), do: full, else: "")

  defp bare_media_attributes(tag) do
    if String.contains?(tag, ~s(="")),
      do: Regex.replace(@bare_media_attribute, tag, &String.replace(&1, ~s(=""), "")),
      else: tag
  end
end
