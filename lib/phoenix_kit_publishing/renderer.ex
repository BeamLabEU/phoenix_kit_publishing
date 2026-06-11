defmodule PhoenixKit.Modules.Publishing.Renderer do
  @moduledoc """
  Renders publishing post markdown to HTML with caching support.

  Uses PhoenixKit.Cache for performance optimization of markdown rendering.
  Cache keys include content hashes for automatic invalidation.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Modules.Publishing.PageBuilder
  alias PhoenixKit.Modules.Shared.Components.Image
  alias PhoenixKit.Modules.Shared.Components.Video
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  # Optional dependency — available when phoenix_kit_entities is installed
  @entity_form_mod PhoenixKitEntities.Components.EntityForm
  @compile {:no_warn_undefined, @entity_form_mod}

  @cache_name :publishing_posts
  # Bump whenever render OUTPUT changes for unchanged source content, so already
  # cached HTML is dropped instead of served stale.
  # v3: heal legacy signed-file URLs against the current url_prefix/secret.
  # v4: escape PHK component tags inside code regions (```/~~~/inline) so they
  #     render as literal text — without the bump, posts cached under v3 keep
  #     rendering the component live from inside the code block.
  @cache_version "v4"

  # Matches the internal signed-file route — `<prefix>/file/<uuid>/<variant>/<token>`
  # — embedded as an `<img src>`. The prefix is bounded to plain path segments
  # (`(?:/[A-Za-z0-9_-]+)*`), so this only fires on genuine root-relative app
  # URLs: a `url_prefix` is always simple path segments. That deliberately
  # excludes absolute (`https://…`) and protocol-relative (`//cdn…`) external
  # URLs, and paths carrying a query string / `/file/` inside a query
  # (`/proxy?next=/file/…`). The UUID group is a strict UUID shape so arbitrary
  # hex-ish strings don't get re-signed into fresh 404s.
  @signed_file_url_regex ~r|src="(?:/[A-Za-z0-9_-]+)*/file/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/([a-z0-9_]+)/[0-9a-fA-F]{4}"|

  @global_cache_key "publishing_render_cache_enabled"
  @per_group_cache_prefix "publishing_render_cache_enabled_"

  @component_regex ~r/<(Image|CTA|Headline|Subheadline|Video|EntityForm)\s+([^>]*?)\/>/s
  @component_block_regex ~r/<(CTA|Headline|Subheadline|Video|EntityForm)\s*([^>]*)>(.*?)<\/\1>/s

  # Fenced (```…``` or ~~~…~~~) and inline (`…`) code spans — masked out before
  # the component scan so a literal component example inside a code block isn't
  # rendered as a real component. Fenced first so it wins at a fence boundary.
  # Known limitation: 4+ backtick fences and backslash-escaped backticks (rare
  # CommonMark corners) aren't matched and would still be scanned for components.
  @code_region_regex ~r/```.*?```|~~~.*?~~~|`[^`\n]*`/s

  # Tailwind/daisyUI classes for post-processing Earmark HTML output.
  # Code blocks (pre, code) are handled separately in style_code_blocks/1.
  @pre_classes "bg-base-300 p-4 rounded-lg overflow-x-auto my-4"
  @inline_code_classes "bg-base-200 px-1.5 py-0.5 rounded text-sm font-mono"

  @tag_classes [
    {"h1", "text-4xl font-bold mt-6 mb-4 pb-2 border-b border-base-content/10"},
    {"h2", "text-3xl font-semibold mt-6 mb-3"},
    {"h3", "text-2xl font-semibold mt-5 mb-2"},
    {"h4", "text-xl font-semibold mt-4 mb-2"},
    {"h5", "text-lg font-semibold mt-4 mb-2"},
    {"h6", "text-base font-semibold mt-4 mb-2"},
    {"p", "my-4 leading-relaxed"},
    {"a", "link link-primary"},
    {"blockquote", "border-l-4 border-primary pl-4 my-4 text-base-content/70 italic"},
    {"table", "table w-full my-4"},
    {"thead", "bg-base-200"},
    {"th", "font-semibold text-left p-2"},
    {"td", "border-t border-base-content/10 p-2"},
    {"img", "max-w-full h-auto rounded-lg my-4"},
    {"ul", "list-disc pl-8 my-4"},
    {"ol", "list-decimal pl-8 my-4"},
    {"li", "my-1"},
    {"hr", "my-8 border-0 border-t-2 border-base-content/10"}
  ]

  # Build {regex_source, tag, classes} tuples at compile time.
  # Regex structs can't be stored in module attributes, so we store the source
  # strings and compile them once at runtime via a persistent cache.
  @tag_patterns Enum.map(@tag_classes, fn {tag, classes} ->
                  {"<#{Regex.escape(tag)}(?=[\\s>\\/])([^>]*)>", tag, classes}
                end)

  @doc """
  Renders a post's markdown content to HTML.

  Caches the result for published posts using content-hash-based keys.
  Lazy-loads cache (only caches after first render).

  Respects `publishing_render_cache_enabled` (global) and
  `publishing_render_cache_enabled_{group_slug}` (per-group) settings.

  ## Examples

      {:ok, html} = Renderer.render_post(post)

  """
  @spec render_post(map()) :: {:ok, String.t()} | {:error, any()}
  def render_post(post) do
    if post.metadata.status == "published" and render_cache_enabled?(post.group) do
      cache_key = build_cache_key(post)

      case get_cached(cache_key) do
        {:ok, html} ->
          {:ok, html}

        :miss ->
          render_and_cache(post, cache_key)
      end
    else
      # Don't cache drafts, archived posts, or when cache is disabled
      {:ok, render_markdown(post.content)}
    end
  end

  @doc """
  Returns whether render caching is enabled for a group.

  Checks both the global setting and per-group setting.
  Both must be enabled (or default to enabled) for caching to work.
  """
  @spec render_cache_enabled?(String.t()) :: boolean()
  def render_cache_enabled?(group_slug) do
    global_enabled = global_render_cache_enabled?()
    per_group_enabled = group_render_cache_enabled?(group_slug)

    global_enabled and per_group_enabled
  end

  @doc """
  Returns whether the global render cache is enabled.
  """
  @spec global_render_cache_enabled?() :: boolean()
  def global_render_cache_enabled? do
    Settings.get_setting_cached(@global_cache_key, "true") == "true"
  end

  @doc """
  Returns whether render cache is enabled for a specific group.
  Does not check the global setting.
  """
  @spec group_render_cache_enabled?(String.t()) :: boolean()
  def group_render_cache_enabled?(group_slug) do
    key = @per_group_cache_prefix <> group_slug
    Settings.get_setting_cached(key, "true") == "true"
  end

  @doc """
  Returns the settings key for per-group render cache.
  Used by other modules that need to write to the setting.
  """
  @spec per_group_cache_key(String.t()) :: String.t()
  def per_group_cache_key(group_slug), do: @per_group_cache_prefix <> group_slug

  @doc """
  Renders markdown or PHK content directly without caching.

  Automatically detects PHK XML format and routes to PageBuilder.
  Falls back to Earmark markdown rendering for non-XML content.

  ## Examples

      html = Renderer.render_markdown(content)

  """
  @spec render_markdown(String.t() | any()) :: String.t()
  def render_markdown(content) when is_binary(content) do
    {time, result} =
      :timer.tc(fn ->
        if has_embedded_components?(content) do
          render_mixed_content(content)
        else
          # Escape code regions on the plain path too, so raw HTML inside a
          # ```fence``` (e.g. <script>) renders as literal text instead of
          # executing — matching the mixed path. escape: false makes this the
          # only thing standing between a fenced <script> and live HTML.
          render_earmark_markdown(escape_code_regions(content))
        end
      end)

    # credo:disable-for-lines:2 Credo.Check.Warning.MissingMetadataKeyInLoggerConfig
    Logger.debug("Content render time: #{time}μs", content_size: byte_size(content))
    heal_signed_file_urls(result)
  end

  def render_markdown(_), do: ""

  # Re-resolves embedded signed-file URLs against the CURRENT url_prefix and
  # secret. Legacy inline images stored a fully-resolved `<old-prefix>/file/...`
  # string in the markdown body; when the host later changes its url_prefix
  # (e.g. "/phoenix_kit" -> "/") or rotates `secret_key_base`, those frozen URLs
  # 404. The file UUID + variant are recoverable from the path, so we re-sign at
  # render time — healing old content with no data migration. Idempotent for
  # content already carrying the current prefix/token. `<Image file_uuid>`
  # components (the current format) resolve correctly on their own; this only
  # matters for the legacy frozen-URL markdown.
  defp heal_signed_file_urls(html) when is_binary(html) do
    Regex.replace(@signed_file_url_regex, html, fn _full, file_uuid, variant ->
      ~s(src="#{URLSigner.signed_url(file_uuid, variant)}")
    end)
  end

  defp heal_signed_file_urls(other), do: other

  # Detect if markdown content has embedded XML components
  defp has_embedded_components?(content) do
    # `<Image` may be followed by a space OR a newline (the format spec's own
    # examples put the attributes on the next line); match either so multi-line
    # tags route through the component path instead of being smartypants-mangled.
    Regex.match?(~r/<Image[\s>]/, content) ||
      String.contains?(content, "<CTA") ||
      String.contains?(content, "<Headline") ||
      String.contains?(content, "<Subheadline") ||
      String.contains?(content, "<Video") ||
      String.contains?(content, "<EntityForm")
  end

  # Render markdown using Earmark, then inject Tailwind/daisyUI classes on each tag.
  defp render_earmark_markdown(content) do
    content = normalize_markdown(content)

    # Trust model: admin-authored Markdown can include inline HTML
    # (`<div class="grid">…</div>` is a common authoring affordance).
    # Earmark's `escape: true` would only cover literal-text HTML, not
    # block-level passthrough — true XSS protection requires a sanitiser
    # like html_sanitize_ex on the output. We keep `escape: false`
    # explicitly so an admin who pastes a `<script>` tag would see it
    # render as live HTML; this is the documented trust boundary.
    # Re-evaluate if any non-admin-authored input reaches this path
    # (API import, AI-translation prompt-injection on rotating roles).
    case Earmark.as_html(content, %Earmark.Options{
           code_class_prefix: "language-",
           smartypants: true,
           gfm: true,
           escape: false
         }) do
      {:ok, html, _warnings} ->
        add_tailwind_classes(html)

      {:error, _html, _errors} ->
        escaped =
          gettext("Error rendering markdown")
          |> Phoenix.HTML.html_escape()
          |> Phoenix.HTML.safe_to_string()

        ~s(<p class="text-error">) <> escaped <> ~s(</p>)
    end
  end

  defp normalize_markdown(content) when is_binary(content) do
    # Apply the prose normalizers ONLY outside code regions. Run over the whole
    # document they corrupt code samples: the heading-indent strip deletes the
    # indentation from `  ## comment` lines inside a fence, and the blank-line
    # spacer injects literal &nbsp; into runs of blank lines in code. Split on
    # code regions (delimiters included) — even segments are prose, odd are code
    # left verbatim — then rejoin.
    @code_region_regex
    |> Regex.split(content, include_captures: true)
    |> Enum.with_index()
    |> Enum.map_join("", fn
      {segment, index} when rem(index, 2) == 0 -> normalize_prose(segment)
      {code_region, _index} -> code_region
    end)
  end

  defp normalize_prose(segment) do
    segment
    # Remove leading indentation before Markdown headings (e.g., "  ## Title")
    |> then(&Regex.replace(~r/^[ \t]+(?=#)/m, &1, ""))
    # Preserve intentional blank lines: convert runs of 2+ blank lines into
    # visible spacing so the rendered output matches what the author typed.
    # A single blank line remains a normal paragraph break (standard Markdown).
    |> preserve_blank_lines()
  end

  # Converts sequences of 2+ consecutive blank lines into paragraph breaks
  # with <br> spacers. Each extra blank line beyond the first becomes one <br>.
  defp preserve_blank_lines(content) do
    Regex.replace(~r/\n{3,}/, content, fn match ->
      # Number of extra blank lines beyond the standard paragraph break
      # \n\n = 1 blank line (normal paragraph break), \n\n\n = 2 blank lines, etc.
      extra_lines = String.length(match) - 2
      br_tags = String.duplicate("&nbsp;\n\n", extra_lines)
      "\n\n#{br_tags}"
    end)
  end

  # ============================================================================
  # Tailwind Class Injection
  # ============================================================================

  # Adds Tailwind/daisyUI classes to rendered HTML tags so markdown content
  # is styled without requiring a prose plugin or inline <style> blocks.
  defp add_tailwind_classes(html) when is_binary(html) do
    html
    |> style_code_blocks()
    |> style_html_tags()
  end

  # Handles <pre><code> blocks separately from inline <code> tags.
  # Uses a marker to protect block code from getting inline code classes.
  defp style_code_blocks(html) do
    html
    |> String.replace("<pre><code", "<!--pkcode-->")
    |> then(fn h ->
      Regex.replace(~r/<code([^>]*)>/, h, fn _, attrs ->
        merge_class("code", attrs, @inline_code_classes)
      end)
    end)
    |> String.replace(
      "<!--pkcode-->",
      ~s(<pre class="#{@pre_classes}"><code)
    )
  end

  # Applies Tailwind classes to all mapped HTML tags.
  defp style_html_tags(html) do
    compiled = compiled_tag_patterns()

    Enum.reduce(compiled, html, fn {regex, tag, classes}, acc ->
      Regex.replace(regex, acc, fn _, attrs ->
        merge_class(tag, attrs, classes)
      end)
    end)
  end

  # Compiles and caches tag regex patterns. Compiled once per process via
  # the process dictionary to avoid recompiling on every render call.
  defp compiled_tag_patterns do
    case Process.get(:pk_tag_patterns) do
      nil ->
        patterns =
          Enum.map(@tag_patterns, fn {source, tag, classes} ->
            {Regex.compile!(source), tag, classes}
          end)

        Process.put(:pk_tag_patterns, patterns)
        patterns

      patterns ->
        patterns
    end
  end

  # Adds a class attribute or merges into an existing one.
  defp merge_class(tag, attrs, new_classes) do
    if String.contains?(attrs, ~s(class=")) do
      new_attrs =
        String.replace(attrs, ~r/class="([^"]*)"/, ~s(class="#{new_classes} \\1"))

      "<#{tag}#{new_attrs}>"
    else
      "<#{tag} class=\"#{new_classes}\"#{attrs}>"
    end
  end

  # Render mixed content: markdown with embedded XML components
  defp render_mixed_content(content) when content == "" or is_nil(content), do: ""

  defp render_mixed_content(content) do
    # Escape HTML inside fenced/inline code spans BEFORE scanning for components,
    # so a `<Image>`/`<CTA>`/… shown literally inside a code block (a docs post
    # demonstrating the PHK syntax) (a) no longer matches the component regex
    # (it's now `&lt;Image`) and (b) renders as visible code text — `escape:
    # false` would otherwise leave the raw tag in `<code>`, where the browser
    # swallows it. Components OUTSIDE code blocks are untouched and still render.
    content
    |> escape_code_regions()
    |> render_mixed_segments([])
    |> Enum.reverse()
    |> Enum.join()
  end

  # Escape <, >, & inside ```fenced``` and `inline` code spans, leaving the
  # fence/backtick delimiters intact so the markdown still parses as code.
  defp escape_code_regions(content) do
    Regex.replace(@code_region_regex, content, fn match ->
      match
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
    end)
  end

  defp render_mixed_segments("", acc), do: acc

  defp render_mixed_segments(content, acc) do
    case next_component_match(content) do
      nil ->
        [render_earmark_markdown(content) | acc]

      {:self_closing, [{match_start, match_len}, {tag_start, tag_len}, {attrs_start, attrs_len}]} ->
        before = binary_part(content, 0, match_start)
        after_index = match_start + match_len
        rest_content = binary_part(content, after_index, byte_size(content) - after_index)
        tag = binary_part(content, tag_start, tag_len)
        attrs = binary_part(content, attrs_start, attrs_len)

        acc =
          acc
          |> maybe_add_markdown(before)
          |> add_component(tag, attrs)

        render_mixed_segments(rest_content, acc)

      {:block, indexes} ->
        [{match_start, match_len} | _rest] = indexes
        before = binary_part(content, 0, match_start)
        after_index = match_start + match_len
        rest_content = binary_part(content, after_index, byte_size(content) - after_index)
        fragment = binary_part(content, match_start, match_len)

        acc =
          acc
          |> maybe_add_markdown(before)
          |> add_block_component(fragment)

        render_mixed_segments(rest_content, acc)
    end
  end

  defp next_component_match(content) do
    self_match = Regex.run(@component_regex, content, return: :index)
    block_match = Regex.run(@component_block_regex, content, return: :index)

    case {self_match, block_match} do
      {nil, nil} ->
        nil

      {nil, block} ->
        {:block, block}

      {self, nil} ->
        {:self_closing, self}

      {self, block} ->
        self_start = self |> hd() |> elem(0)
        block_start = block |> hd() |> elem(0)

        if self_start <= block_start do
          {:self_closing, self}
        else
          {:block, block}
        end
    end
  end

  defp maybe_add_markdown(acc, ""), do: acc

  defp maybe_add_markdown(acc, text) do
    [render_earmark_markdown(text) | acc]
  end

  defp add_component(acc, tag, attrs) do
    [render_inline_component(tag, attrs) | acc]
  end

  defp add_block_component(acc, fragment) do
    [render_block_component(fragment) | acc]
  end

  # Render individual inline component
  defp render_inline_component("Image", attrs) do
    # Parse attributes
    attr_map = parse_xml_attributes(attrs)

    assigns = %{
      __changed__: nil,
      attributes: attr_map,
      variant: "default",
      content: nil,
      children: []
    }

    Image.render(assigns)
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  rescue
    error ->
      Logger.warning("Error rendering Image component: #{inspect(error)}")
      "<div class='error'>Error rendering image</div>"
  end

  defp render_inline_component("Video", attrs) do
    attr_map = parse_xml_attributes(attrs)

    assigns = %{
      __changed__: nil,
      attributes: attr_map,
      variant: Map.get(attr_map, "variant", "default"),
      content: Map.get(attr_map, "caption"),
      children: []
    }

    Video.render(assigns)
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  rescue
    error ->
      Logger.warning("Error rendering Video component: #{inspect(error)}")
      "<div class='error'>Error rendering video</div>"
  end

  defp render_inline_component("EntityForm", attrs) do
    attr_map = parse_xml_attributes(attrs)

    assigns = %{
      __changed__: nil,
      attributes: attr_map,
      variant: Map.get(attr_map, "variant", "default"),
      content: nil,
      children: []
    }

    mod = @entity_form_mod

    mod.render(assigns)
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  rescue
    error ->
      Logger.warning("Error rendering EntityForm component: #{inspect(error)}")
      "<div class='error'>Error rendering entity form</div>"
  end

  defp render_inline_component(tag, _attrs) do
    # Fallback for other components
    Logger.warning("Inline component not supported yet: #{tag}")
    ""
  end

  defp render_block_component(fragment) do
    fragment
    |> PageBuilder.render_content()
    |> case do
      {:ok, html} ->
        html
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      {:error, reason} ->
        Logger.warning("Error rendering block component: #{inspect(reason)}")
        "<div class='error'>Error rendering component</div>"
    end
  end

  # Parse XML attribute string into a map
  defp parse_xml_attributes(attrs_string) do
    # Match key="value" or key='value' patterns
    attr_regex = ~r/(\w+)=["']([^"']+)["']/

    Regex.scan(attr_regex, attrs_string)
    |> Enum.map(fn [_, key, value] -> {key, value} end)
    |> Enum.into(%{})
  end

  @doc """
  Invalidates cache for a specific post.

  Called when a post is updated in the admin editor.

  ## Examples

      Renderer.invalidate_cache("docs", "getting-started", "en")

  """
  @spec invalidate_cache(String.t(), String.t(), String.t()) :: :ok
  def invalidate_cache(group_slug, identifier, language) do
    # Build pattern to match all cache keys for this post
    # We don't know the content hash, so we invalidate by prefix
    pattern = "#{@cache_version}:publishing_post:#{group_slug}:#{identifier}:#{language}:"

    # Since PhoenixKit.Cache doesn't support pattern matching,
    # we'll just log this for now and rely on content hash changes
    # credo:disable-for-lines:6 Credo.Check.Warning.MissingMetadataKeyInLoggerConfig
    Logger.info("Cache invalidation requested",
      group: group_slug,
      identifier: identifier,
      language: language,
      pattern: pattern
    )

    # The content hash in the key will change automatically when content changes
    # So we don't need to explicitly delete old entries
    :ok
  end

  @doc """
  Clears all publishing post caches.

  Useful for testing or when doing bulk updates.
  """
  @spec clear_all_cache() :: :ok
  def clear_all_cache do
    PhoenixKit.Cache.clear(@cache_name)
    Logger.info("Cleared all publishing post caches")
    :ok
  rescue
    _ ->
      Logger.warning("Publishing cache not available for clearing")
      :ok
  end

  @doc """
  Clears the render cache for a specific group.

  Returns `{:ok, count}` with the number of entries cleared.

  ## Examples

      Renderer.clear_group_cache("my-group")
      # => {:ok, 15}

  """
  @spec clear_group_cache(String.t()) :: {:ok, non_neg_integer()} | {:error, any()}
  def clear_group_cache(group_slug) do
    prefix = "#{@cache_version}:publishing_post:#{group_slug}:"

    case PhoenixKit.Cache.clear_by_prefix(@cache_name, prefix) do
      {:ok, count} = result ->
        Logger.info("Cleared #{count} cached posts for group: #{group_slug}")
        result

      {:error, _} = error ->
        error
    end
  rescue
    _ ->
      Logger.warning("Group cache not available for clearing")
      {:ok, 0}
  end

  # Private Functions

  defp render_and_cache(post, cache_key) do
    html = render_markdown(post.content)

    # Cache the rendered HTML
    put_cached(cache_key, html)

    {:ok, html}
  end

  defp build_cache_key(post) do
    # Build content hash from content + metadata + the two inputs that
    # heal_signed_file_urls/1 re-signs against: the active url_prefix and a
    # secret-derived marker. Both participate so a prefix change OR a
    # secret_key_base rotation invalidates cached HTML automatically — otherwise
    # a cache hit would keep serving stale (now-404) image URLs until the
    # content itself changed.
    content_to_hash =
      post.content <> inspect(post.metadata) <> url_prefix_marker() <> signer_marker()

    content_hash =
      :crypto.hash(:md5, content_to_hash)
      |> Base.encode16(case: :lower)
      |> String.slice(0..7)

    identifier = post[:uuid] || post.slug

    "#{@cache_version}:publishing_post:#{post.group}:#{identifier}:#{post.language}:#{content_hash}"
  end

  defp url_prefix_marker do
    PhoenixKit.Config.get_url_prefix()
  rescue
    _ -> ""
  end

  # A stable 4-char token over a fixed probe UUID — changes only when
  # secret_key_base changes, so it lets the render cache key track secret
  # rotation without exposing the secret itself.
  @cache_signer_probe "00000000-0000-0000-0000-000000000000"
  defp signer_marker do
    URLSigner.generate_token(@cache_signer_probe, "cache")
  rescue
    _ -> ""
  end

  defp get_cached(key) do
    case PhoenixKit.Cache.get(@cache_name, key) do
      nil -> :miss
      html -> {:ok, html}
    end
  rescue
    _ ->
      # Cache not available (tests, compilation)
      :miss
  end

  defp put_cached(key, value) do
    PhoenixKit.Cache.put(@cache_name, key, value)
  rescue
    error ->
      Logger.debug("Cache unavailable, skipping: #{inspect(error)}")
      :ok
  end
end
