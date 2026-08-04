defmodule PhoenixKit.Modules.Publishing.Renderer do
  @moduledoc """
  Renders publishing post markdown to HTML with caching support.

  Uses PhoenixKit.Cache for performance optimization of markdown rendering.
  Cache keys include content hashes for automatic invalidation.
  """

  use Gettext, backend: PhoenixKitPublishing.Gettext

  require Logger

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Hashtags
  alias PhoenixKit.Modules.Publishing.PageBuilder
  alias PhoenixKit.Modules.Publishing.PageBuilder.Components.Audio, as: AudioComponent
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
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
  # v5: markdown engine swapped Earmark -> MDEx (comrak). Output HTML differs
  #     (whitespace, `<img />`, entity normalization, …) for unchanged source,
  #     so v4 entries must be dropped and re-rendered.
  # v6: body hashtags render as tag-archive links — any cached post containing
  #     a #word would keep rendering it as plain text without the bump.
  # v7: <Showcase> renders as a band instead of falling through to the unknown-
  #     component fallback, and its stylesheet is appended per document.
  # v8: <Gallery> renders as a helix instead of falling through to the unknown-
  #     component fallback, and its stylesheet is appended per document.
  @cache_version "v8"

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

  @component_regex ~r/<(Image|CTA|Headline|Subheadline|Video|Audio|EntityForm)\s+([^>]*?)\/>/s
  @component_block_regex ~r/<(CTA|Headline|Subheadline|Video|Audio|EntityForm|Showcase|Gallery)\s*([^>]*)>(.*?)<\/\1>/s

  # Every tag this module knows how to render. The editor hands this list to
  # Leaf as `preserve_tags` so the visual mode treats each one as a single
  # opaque object instead of markup it is free to normalise.
  #
  # This is not a nicety. A WYSIWYG surface round-trips through HTML, and a
  # tag it does not recognise does not survive the return trip — open a post
  # containing `<Showcase>`, touch anything, and the autosave writes back a
  # body with the bands flattened to loose paragraphs. It is silent, it looks
  # like nothing happened, and the only copy of the original is gone.
  @component_tags ~w(Image CTA Headline Subheadline Video Audio EntityForm Showcase Gallery Note)

  @doc """
  The PHK component tags the renderer understands, for editors that must keep
  them intact. See `@component_tags`.
  """
  @spec component_tags() :: [String.t()]
  def component_tags, do: @component_tags

  @showcase_regex ~r/^<Showcase\s*([^>]*)>(.*)<\/Showcase>$/s
  @gallery_regex ~r/^<Gallery\s*([^>]*)>(.*)<\/Gallery>$/s
  @showcase_default_overlap 15
  @showcase_max_overlap 40
  @showcase_min_height 120
  @showcase_max_height 1200

  # <Gallery> — images on a slowly turning double helix.
  #
  # No JavaScript. The reference implementations of this effect run a
  # requestAnimationFrame loop that writes `transform` and `filter` onto every
  # card each frame; that can't work here, because public post pages are dead
  # views where JS is progressive enhancement only, and a gallery whose entire
  # layout comes from a script renders as a pile of cards stacked at the
  # centre when the script doesn't run.
  #
  # Two observations make CSS sufficient. First, every card follows the SAME
  # path — they differ only in how far along it they are — so one keyframe
  # animation plus a negative `animation-delay` per card spreads them along
  # the strand. Second, the path is a loop: with a whole number of turns the
  # rotation wraps seamlessly, and the vertical jump from bottom back to top
  # is invisible because `--pk-hx-span` runs the strand off both edges of the
  # frame. That is why the reference uses an integer turn count and a span
  # factor above 1; here those choices are what make the animation loopable
  # rather than merely tidy.
  #
  # Depth (far cards dimmer and blurrier) is a SECOND animation on the same
  # element, animating `filter` while the first animates `transform`. It runs
  # on the rotation period rather than the strand period, so a single shared
  # keyframe block serves every card and every configuration — the card's own
  # angle is expressed entirely as its delay. Emitting per-instance keyframes
  # would otherwise be unavoidable, since brightness depends on the absolute
  # angle, not on progress along the strand.
  #
  # `prefers-reduced-motion` pauses both animations. Because each card's delay
  # already places it correctly, pausing yields a static, properly-posed helix
  # rather than the collapsed pile that stopping a script would leave.
  @helix_css """
  <style>
  /* ---- Floor: a plain responsive image grid. -------------------------------
     Everything starts here, and anything that can't do the helix STAYS here.
     A grid of pictures is a perfectly good gallery, which is the point: the
     fallback is a real design, not a broken one. */
  .pk-helix{margin:2.5rem 0;position:relative}
  .pk-helix__world{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:.75rem}
  .pk-helix__card{border-radius:10px;overflow:hidden;aspect-ratio:3/2}
  .pk-helix__card img{width:100%;height:100%;object-fit:cover;display:block}
  .pk-helix__vignette{display:none}

  /* ---- Enhancement: the helix. ---------------------------------------------
     Gated on BOTH the 3D presentation and custom properties, because the
     whole layout is expressed in `var()`s — a browser with `preserve-3d` but
     without custom properties would position every card at the centre with no
     radius and no span, i.e. a heap. Failing that test drops cleanly to the
     grid above rather than to a pile. */
  @supports (transform-style: preserve-3d) and (--probe: 0) {
    .pk-helix__scene{display:block;position:relative;height:var(--pk-hx-height,520px);perspective:var(--pk-hx-perspective,1200px);perspective-origin:50% 50%;overflow:hidden;background:var(--pk-hx-bg,var(--color-base-100,#fff));border-radius:12px}
    .pk-helix__world{display:block;position:absolute;inset:0;transform-style:preserve-3d}
    .pk-helix__card{position:absolute;left:50%;top:50%;width:var(--pk-hx-card-w,225px);height:var(--pk-hx-card-h,155px);aspect-ratio:auto;will-change:transform,filter;transform:var(--pk-hx-rest);animation:pk-hx-move var(--pk-hx-dur,80s) linear infinite var(--pk-hx-d1,0s),pk-hx-blur var(--pk-hx-rot,40s) linear infinite var(--pk-hx-d2,0s)}
    /* The card itself stays OPAQUE — a photograph you can see through reads as
       a rendering fault, not as distance. Depth is a scrim painted OVER it in
       the backdrop colour, so a far card recedes into the page while remaining
       a solid object. (Fading the card's own opacity, which is what the first
       theme-aware version did, let cards show through one another.) */
    .pk-helix__card::after{content:"";position:absolute;inset:0;pointer-events:none;background:var(--pk-hx-bg,var(--color-base-100,#fff));opacity:0;animation:pk-hx-scrim var(--pk-hx-rot,40s) linear infinite var(--pk-hx-d2,0s)}
    /* Fades the strand into the backdrop on all four sides.
       Top and bottom hide the wrap, where a card jumps from the end of the
       strand back to the start. Left and right exist for a different reason:
       the cylinder is wider than the frame, so without them the rotation is
       sliced by two hard vertical edges — a box cutting through the middle of
       a turn, which reads as a mistake rather than a boundary. */
    .pk-helix__vignette{display:block;position:absolute;inset:0;pointer-events:none;background:linear-gradient(to bottom,var(--pk-hx-bg,var(--color-base-100,#fff)) 0%,transparent 18%,transparent 82%,var(--pk-hx-bg,var(--color-base-100,#fff)) 100%),linear-gradient(to right,var(--pk-hx-bg,var(--color-base-100,#fff)) 0%,transparent 12%,transparent 88%,var(--pk-hx-bg,var(--color-base-100,#fff)) 100%)}
  }

  @keyframes pk-hx-move{
    from{transform:translate(-50%,-50%) rotateY(var(--pk-hx-phase,0turn)) translateZ(var(--pk-hx-radius,420px)) translateY(calc(var(--pk-hx-span,780px) * -0.5))}
    to{transform:translate(-50%,-50%) rotateY(calc(var(--pk-hx-phase,0turn) + var(--pk-hx-turns,2) * 1turn)) translateZ(var(--pk-hx-radius,420px)) translateY(calc(var(--pk-hx-span,780px) * 0.5))}
  }
  /* One full rotation, sampled every eighth of a turn — dense enough that the
     interpolation between stops is imperceptible.

     Distance is a scrim in the BACKDROP colour rather than a brightness cut.
     Darkening only reads as distance over a dark page: on a light theme a
     dimmed card goes dark against white and jumps forward instead of
     receding. Fading toward whatever is actually behind works on any theme.

     scrim = 0.85·(1−depth²), blur = (1−depth)²·max, depth = (cos θ + 1)/2. */
  @keyframes pk-hx-scrim{
    0%{opacity:0}
    12.5%{opacity:0.231}
    25%{opacity:0.638}
    37.5%{opacity:0.832}
    50%{opacity:0.85}
    62.5%{opacity:0.832}
    75%{opacity:0.638}
    87.5%{opacity:0.231}
    100%{opacity:0}
  }
  @keyframes pk-hx-blur{
    0%{filter:blur(0)}
    12.5%{filter:blur(calc(var(--pk-hx-blur,5px) * 0.021))}
    25%{filter:blur(calc(var(--pk-hx-blur,5px) * 0.25))}
    37.5%{filter:blur(calc(var(--pk-hx-blur,5px) * 0.729))}
    50%{filter:blur(var(--pk-hx-blur,5px))}
    62.5%{filter:blur(calc(var(--pk-hx-blur,5px) * 0.729))}
    75%{filter:blur(calc(var(--pk-hx-blur,5px) * 0.25))}
    87.5%{filter:blur(calc(var(--pk-hx-blur,5px) * 0.021))}
    100%{filter:blur(0)}
  }

  /* motion="scroll": the helix turns as the reader scrolls past it instead of
     drifting on its own — the behaviour of the gallery this is modelled on.
     Still no JavaScript: `animation-timeline: view()` ties progress to the
     element's own passage through the viewport.

     Gated, because support is narrower than the rest of this. Where it is
     missing the drift animation above simply stays in effect, which is a
     working gallery rather than a still one — so `motion="scroll"` degrades
     to `motion="drift"` rather than to nothing.

     Drift mode spreads its cards with a negative `animation-delay`, and
     neither that nor `animation-range` can do the job here: delays are
     ignored on a non-time timeline, and a range offset moves WHEN a card
     animates rather than where it starts — negative values there are invalid
     outright and get dropped, landing every card in lockstep.

     So scroll mode bakes each card's starting angle into keyframes of its
     own, emitted next to the gallery. Every card then plays the same single
     pass over the same range, from wherever on the helix it belongs. Looping
     doesn't arise — one pass, with fill-mode holding both ends — which is
     also why the wrap that drift mode must hide isn't a problem here. */
  @supports (animation-timeline: view()) {
    /* A NAMED timeline declared on the figure, not `view()` on the cards.
       `view()` resolves against the nearest scroll container, and the scene
       above is `overflow:hidden` — which counts as one. Bound to that, the
       timeline never advances and every card freezes at whatever progress it
       happened to start on. The figure sits outside the clip, so its passage
       through the real viewport is what drives the rotation. */
    .pk-helix--scroll{view-timeline-name:--pk-hx-view;view-timeline-axis:block}
    .pk-helix--scroll .pk-helix__card{animation-name:var(--pk-hx-k1);animation-timeline:--pk-hx-view;animation-duration:auto;animation-iteration-count:1;animation-delay:0s;animation-fill-mode:both;animation-range:cover 0% cover 100%}
    .pk-helix--scroll .pk-helix__card::after{animation-name:var(--pk-hx-k2);animation-timeline:--pk-hx-view;animation-duration:auto;animation-iteration-count:1;animation-delay:0s;animation-fill-mode:both;animation-range:cover 0% cover 100%}
  }

  /* Blur is by far the most expensive part — recomputed for every card on
     every frame — so it comes off wherever the hardware is likely to be
     modest: small screens, and touch devices of any size (a coarse pointer at
     tablet width is still phone-class silicon). Brightness alone still reads
     as depth. */
  @media (max-width:767px){.pk-helix__scene{--pk-hx-blur:0px}}
  @media (hover:none) and (pointer:coarse){.pk-helix__scene{--pk-hx-blur:0px}}

  /* Someone who asked for less motion gets the helix holding still. Each
     card's delay already places it correctly, so pausing is a posed
     arrangement rather than the heap that stopping a script would leave. */
  @media (prefers-reduced-motion:reduce){
    .pk-helix__card,.pk-helix__card::after{animation-play-state:paused}
  }

  /* Data saver, and displays that repaint slowly (e-ink, some kiosk panels):
     abandon the effect entirely and show the grid, which costs one repaint
     instead of a permanent animation. */
  @media (prefers-reduced-data:reduce),(update:slow){
    .pk-helix__scene{display:block;height:auto;background:none;perspective:none;overflow:visible}
    .pk-helix__world{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:.75rem;position:static;inset:auto;transform-style:flat}
    .pk-helix__card{position:static;width:auto;height:auto;aspect-ratio:3/2;transform:none;animation:none;filter:none;opacity:1;will-change:auto}
    .pk-helix__card::after{display:none}
    .pk-helix__vignette{display:none}
  }
  </style>
  """

  # Named grid lines make the overlap literal: the media spans
  # [edge → overlap-end] and the text [overlap-start → edge], so the middle
  # track belongs to both. Mirrored for side="right".
  @showcase_css """
  <style>
  .pk-showcase{display:grid;grid-template-columns:[sc-edge-start] 1fr [sc-mid-start] var(--pk-sc-overlap,15%) [sc-mid-end] 1fr [sc-edge-end];align-items:center;margin:2.5rem 0;overflow:hidden}
  /* tone="page" (default): the band takes the PAGE's own colours, so there is
     no slab beside the image — the picture simply dissolves into the page. */
  .pk-showcase--page{background:var(--color-base-100,#fff);color:var(--color-base-content,#111)}
  .pk-showcase--dark{background:#0b0b0d;color:#fff}
  .pk-showcase--light{background:#fafafa;color:#111}
  .pk-showcase__media{grid-row:1;position:relative;align-self:stretch;min-height:0}
  .pk-showcase__media img{display:block;width:100%;height:100%;min-height:14rem;object-fit:cover;margin:0;border-radius:0}
  .pk-showcase__text{grid-row:1;position:relative;z-index:1;padding:clamp(1rem,4vw,3rem)}
  /* height="short|medium|tall|<px>" pins the image area; object-fit crops. */
  .pk-showcase--fixed .pk-showcase__media{height:var(--pk-sc-height,26rem)}
  .pk-showcase--fixed .pk-showcase__media img{height:100%;min-height:0}
  .pk-showcase__text > :first-child{margin-top:0}
  .pk-showcase__text > :last-child{margin-bottom:0}
  .pk-showcase--left .pk-showcase__media{grid-column:sc-edge-start / sc-mid-end}
  .pk-showcase--left .pk-showcase__text{grid-column:sc-mid-start / sc-edge-end}
  .pk-showcase--right .pk-showcase__media{grid-column:sc-mid-start / sc-edge-end}
  .pk-showcase--right .pk-showcase__text{grid-column:sc-edge-start / sc-mid-end}
  /* Scrim: blends the image into the band on the side the text comes from,
     starting at --pk-sc-fade (earlier for a wider overlap). */
  .pk-showcase__media::after{content:"";position:absolute;inset:0;pointer-events:none}
  .pk-showcase--left.pk-showcase--page .pk-showcase__media::after{background:linear-gradient(to right,transparent var(--pk-sc-fade,55%),var(--color-base-100,#fff))}
  .pk-showcase--right.pk-showcase--page .pk-showcase__media::after{background:linear-gradient(to left,transparent var(--pk-sc-fade,55%),var(--color-base-100,#fff))}
  .pk-showcase--left.pk-showcase--dark .pk-showcase__media::after{background:linear-gradient(to right,transparent var(--pk-sc-fade,55%),rgb(11 11 13 / var(--pk-sc-shade,.55)))}
  .pk-showcase--right.pk-showcase--dark .pk-showcase__media::after{background:linear-gradient(to left,transparent var(--pk-sc-fade,55%),rgb(11 11 13 / var(--pk-sc-shade,.55)))}
  .pk-showcase--left.pk-showcase--light .pk-showcase__media::after{background:linear-gradient(to right,transparent var(--pk-sc-fade,55%),rgb(250 250 250 / var(--pk-sc-shade,.55)))}
  .pk-showcase--right.pk-showcase--light .pk-showcase__media::after{background:linear-gradient(to left,transparent var(--pk-sc-fade,55%),rgb(250 250 250 / var(--pk-sc-shade,.55)))}
  /* Narrow screens: the two stack, so the overlap is total and the scrim
     becomes a full vertical wash — the boss's "as the overlap increases the
     image gets darkened or lightened as needed".
     Must repeat the side classes: the desktop rules are .side.tone (three
     classes), so a two-class rule here loses on specificity even inside
     the media query and the wash would silently never apply. */
  @media (max-width:767px){
    .pk-showcase{grid-template-columns:1fr}
    .pk-showcase--left .pk-showcase__media,.pk-showcase--right .pk-showcase__media,
    .pk-showcase--left .pk-showcase__text,.pk-showcase--right .pk-showcase__text{grid-column:1;grid-row:1}
    .pk-showcase__text{align-self:end}
    .pk-showcase__media img{min-height:22rem}
    .pk-showcase--fixed .pk-showcase__media img{min-height:0}
    .pk-showcase--left.pk-showcase--page .pk-showcase__media::after,
    .pk-showcase--right.pk-showcase--page .pk-showcase__media::after{background:linear-gradient(to bottom,transparent 25%,var(--color-base-100,#fff))}
    .pk-showcase--left.pk-showcase--dark .pk-showcase__media::after,
    .pk-showcase--right.pk-showcase--dark .pk-showcase__media::after{background:linear-gradient(to bottom,rgb(11 11 13 / .2) 30%,rgb(11 11 13 / .85))}
    .pk-showcase--left.pk-showcase--light .pk-showcase__media::after,
    .pk-showcase--right.pk-showcase--light .pk-showcase__media::after{background:linear-gradient(to bottom,rgb(250 250 250 / .2) 30%,rgb(250 250 250 / .9))}
  }
  </style>
  """

  # Fenced code blocks, double-backtick inline code, and single-backtick
  # inline code spans — masked out before the component scan so a literal
  # component example inside a code block is not rendered as a real component.
  # Order matters: fences first (win at a fence boundary), then double-backtick
  # (so double-backtick spans containing single backticks work correctly), then single.
  # The single-backtick branch allows soft line breaks (a `…` span may run over
  # several lines, matching CommonMark) but stops at a blank line — `\n(?!\n)`
  # rejects the paragraph boundary, so two unbalanced backticks in separate
  # paragraphs don't swallow a real component sitting between them.
  # Known limitation: 4+ backtick fences and backslash-escaped backticks (rare
  # CommonMark corners) are not matched and would still be scanned for components.
  @code_region_regex ~r/```.*?```|~~~.*?~~~|``[^\n]+?``|`(?:[^`\n]|\n(?!\n))*`/s

  # MDEx (comrak) options chosen to reproduce the prior Earmark behavior:
  #   * parse smart punctuation — curly quotes, en/em dashes, ellipses
  #   * GFM extensions — tables, strikethrough, autolinks, task lists
  #   * render unsafe — pass raw inline/block HTML straight through, the
  #     documented admin trust boundary (see render_markdown_html/1)
  # The GFM `tagfilter` extension is deliberately omitted so a pasted `<script>`
  # still renders live — neutering it would break that trust boundary. comrak
  # emits fenced code as `<pre><code class="language-x">`, matching the
  # `language-` prefix the post-processing in style_code_blocks/1 expects.
  @mdex_options [
    extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
    parse: [smart: true],
    render: [unsafe: true]
  ]

  # Sentinel for a `<` that sits inside a code span/fence. The component scanner
  # is plain regex over the source, so without this it would extract a `<Image>`
  # / `<CTA>` / … shown *literally* inside a code block and render it as a real
  # component. We mask the `<` before scanning and restore it before MDEx renders
  # — comrak then HTML-escapes it inside the code, so it shows as literal text. A
  # NUL-delimited token can't collide with real post content.
  @code_lt_sentinel "\x00pk-code-lt\x00"

  # Tailwind/daisyUI classes for post-processing the rendered markdown HTML.
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
  @spec render_post(map(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def render_post(post, opts \\ []) do
    if Constants.published?(post.metadata.status) and render_cache_enabled?(post.group) do
      cache_key = build_cache_key(post, opts)

      case get_cached(cache_key) do
        {:ok, html} ->
          {:ok, html}

        :miss ->
          render_and_cache(post, cache_key, opts)
      end
    else
      # Don't cache drafts, archived posts, or when cache is disabled.
      # Some callers pass bare maps without :language — hashtags then
      # render as plain text instead of crashing.
      {:ok,
       render_markdown(post.content,
         tag_links: tag_link_context(post),
         notes_style: Keyword.get(opts, :notes_style)
       )}
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
  Falls back to MDEx markdown rendering for non-XML content.

  ## Examples

      html = Renderer.render_markdown(content)

  """
  @spec render_markdown(String.t() | any(), keyword()) :: String.t()
  def render_markdown(content, opts \\ [])

  def render_markdown(content, opts) when is_binary(content) do
    # Author notes are a document-level feature (sequential numbering + a
    # collected section), so they're extracted before the per-segment
    # component pipeline runs. Two display styles (group setting):
    # "footnotes" (default) — refs link to a collected bottom section;
    # "panel" — refs link to per-note slide-out panels the POST TEMPLATE
    # renders (they carry live comment threads, which must never be baked
    # into this cacheable HTML).
    notes_style = normalize_notes_style(Keyword.get(opts, :notes_style))
    {content, notes} = extract_notes(content, notes_style)

    # Body hashtags become tag-archive links when the caller supplies the
    # group/language context (public post renders). Runs AFTER the notes
    # pass — note bodies/phrases have their '#' entity-encoded, so a tag
    # mentioned inside a note never turns into markup. Code regions are
    # skipped inside linkify/2 itself.
    content =
      case Keyword.get(opts, :tag_links) do
        {group_slug, language} when is_binary(group_slug) and is_binary(language) ->
          Hashtags.linkify(content, fn tag ->
            PublishingHTML.term_archive_path(language, group_slug, {:tag, tag})
          end)

        _ ->
          content
      end

    {time, result} =
      :timer.tc(fn ->
        if has_embedded_components?(content) do
          render_mixed_content(content)
        else
          # No code-region pre-escaping needed: comrak always HTML-escapes
          # fenced and inline code content, so a raw <script> inside a
          # ```fence``` renders as literal text. Raw HTML *outside* code still
          # passes through live (render: [unsafe: true]) — the admin trust
          # boundary documented in render_markdown_html/1.
          render_markdown_html(content)
        end
      end)

    # credo:disable-for-lines:2 Credo.Check.Warning.MissingMetadataKeyInLoggerConfig
    Logger.debug("Content render time: #{time}μs", content_size: byte_size(content))

    notes_html =
      case notes_style do
        "panel" -> notes_ref_styles(notes)
        _ -> notes_section(notes)
      end

    healed = heal_signed_file_urls(result)
    healed <> notes_html <> showcase_styles(healed) <> helix_styles(healed)
  end

  def render_markdown(_, _opts), do: ""

  # One stylesheet per document, appended only when a band actually RENDERED.
  # Keyed off the output rather than the source: a <Showcase> shown inside a
  # code fence, or one whose src was rejected, produces no band and must not
  # drag the stylesheet along with it.
  defp showcase_styles(html) do
    if String.contains?(html, ~s(class="pk-showcase )), do: @showcase_css, else: ""
  end

  defp helix_styles(html) do
    if String.contains?(html, ~s(class="pk-helix)), do: @helix_css, else: ""
  end

  defp normalize_notes_style("panel"), do: "panel"
  defp normalize_notes_style(_), do: "footnotes"

  # ===========================================================================
  # Author notes (<Note note="…">phrase</Note>)
  #
  # The writer annotates a phrase to clarify it for readers. Renders as the
  # phrase with a superscript number linking to a collected Notes section at
  # the bottom (plain-HTML footnote UX — the no-JS baseline), plus a
  # CSS-only hover/focus popover carrying the note text (progressive
  # enhancement via `content: attr(data-note)` — still no JS). Numbering is
  # sequential through the document; a literal <Note> inside a code fence is
  # ignored (the code mask runs first). Named "notes", not "annotations" —
  # core already uses that word for Etcher media markup.
  # ===========================================================================

  @note_regex ~r/<Note\s+note="([^"]*)"\s*>(.*?)<\/Note>/s

  @doc """
  The post's author notes in document order:
  `[%{number: n, id: stable_id, body: text}]`. The id is derived from the
  note text (not the number), so a comment anchored to a note survives the
  author inserting an earlier note — it detaches only when the note text
  itself changes. The post template uses this to render the slide-out
  panels in "panel" notes style; a `<Note>` inside a code fence is ignored
  (same mask as rendering).
  """
  def list_notes(content) when is_binary(content) do
    @note_regex
    |> Regex.scan(mask_scanned_code(content), capture: :all_but_first)
    |> Enum.with_index(1)
    |> Enum.map_reduce(%{}, fn {[body, _phrase], number}, seen ->
      occurrence = Map.get(seen, body, 0) + 1

      {%{number: number, id: note_dom_id(body, occurrence), body: body},
       Map.put(seen, body, occurrence)}
    end)
    |> elem(0)
  end

  def list_notes(_), do: []

  @doc """
  Stable DOM/comment anchor for a note: a short url-safe digest of the
  note text. Content-addressed on purpose — see `list_notes/1`. Repeated
  identical note texts get occurrence-suffixed digests (2nd, 3rd, …) so
  panel DOM ids stay unique; the first occurrence keeps the plain digest,
  so existing comments never detach when a duplicate appears later.
  """
  def note_dom_id(body, occurrence \\ 1)

  def note_dom_id(body, 1) when is_binary(body), do: digest_note(body)

  def note_dom_id(body, occurrence) when is_binary(body) and is_integer(occurrence),
    do: digest_note(body <> "\n#{occurrence}")

  defp digest_note(input) do
    :sha256
    |> :crypto.hash(input)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end

  defp extract_notes(content, notes_style) do
    masked = mask_scanned_code(content)

    if masked =~ @note_regex do
      {iodata, notes} =
        @note_regex
        |> Regex.split(masked, include_captures: true)
        |> Enum.reduce({[], []}, &take_note(&1, &2, notes_style))

      # Content stays masked here: the plain path unmasks inside
      # render_markdown_html/1, and the mixed path's re-mask is a no-op on
      # already-masked code regions.
      {iodata |> Enum.reverse() |> IO.iodata_to_binary(), Enum.reverse(notes)}
    else
      {content, []}
    end
  end

  # Split with include_captures alternates prose and whole `<Note>` tags, so a
  # part that matches the regex in full IS a note; anything else passes through.
  # `notes` accumulates bodies in reverse, which is what makes both the number
  # and the duplicate-body occurrence a plain count of what came before.
  defp take_note(part, {out, notes}, notes_style) do
    case Regex.run(@note_regex, part) do
      [^part, body, phrase] ->
        number = length(notes) + 1
        # Occurrence of this exact body so far — duplicate note texts must not
        # collide on the panel anchor (note_dom_id/2).
        occurrence = Enum.count(notes, &(&1 == body)) + 1

        {[note_ref_html(number, occurrence, body, phrase, notes_style) | out], [body | notes]}

      _ ->
        {[part | out], notes}
    end
  end

  defp note_ref_html(number, occurrence, body, phrase, notes_style) do
    # Footnotes target the collected bottom section; panel style targets the
    # template-rendered slide-out (`:target` opens it — still no JS).
    href =
      case notes_style do
        "panel" -> "#pk-note-panel-#{note_dom_id(body, occurrence)}"
        _ -> "#pk-note-#{number}"
      end

    [
      ~s(<a class="pk-note-ref" id="pk-note-ref-#{number}" href="#{href}" data-note="),
      escape_html(body),
      ~s(">),
      # Escaped, not just #-encoded. The '#' still has to go (the ref is
      # already an <a> and the later hashtag pass must not nest a second
      # anchor inside it), and escape_html does that along with the rest.
      # Admin markdown renders with `unsafe: true`, so leaving the phrase raw
      # was not a way in that the body didn't already offer — but it sits
      # inside an <a> this function is building, one line below the body's own
      # escape, and the AI-translation and import paths write bodies no admin
      # typed.
      escape_html(phrase),
      ~s(<sup>#{number}</sup></a>)
    ]
  end

  # Panel style: no bottom section — the template renders the panels. The
  # refs keep the hover/focus popover, so emit just that style block.
  defp notes_ref_styles([]), do: ""

  defp notes_ref_styles(_notes) do
    """
    <style>
    .pk-note-ref{text-decoration:underline dotted;text-underline-offset:3px;position:relative;color:inherit}
    .pk-note-ref sup{color:var(--color-primary,currentColor);font-weight:600;margin-left:1px}
    .pk-note-ref:hover::after,.pk-note-ref:focus-visible::after{content:attr(data-note);position:absolute;bottom:calc(100% + 6px);left:50%;transform:translateX(-50%);width:max-content;max-width:min(20rem,80vw);white-space:normal;background:var(--color-base-200,#eee);color:var(--color-base-content,#111);border:1px solid var(--color-base-300,#ddd);border-radius:.5rem;padding:.5rem .75rem;font-size:.8rem;line-height:1.35;z-index:20;box-shadow:0 4px 12px rgb(0 0 0/.08)}
    </style>
    """
  end

  defp notes_section([]), do: ""

  # The "Notes"/"Back to text" chrome is gettext'd at RENDER time — safe with
  # the render cache because the cache key includes the content language and
  # the request locale matches it when the cache fills.
  defp notes_section(notes) do
    back_label = escape_html(gettext("Back to text"))

    items =
      notes
      |> Enum.with_index(1)
      |> Enum.map_join(fn {body, number} ->
        ~s(<li id="pk-note-#{number}">) <>
          escape_html(body) <>
          ~s( <a href="#pk-note-ref-#{number}" aria-label="#{back_label}">↩</a></li>)
      end)

    """
    <section class="pk-notes mt-10 border-t border-base-200 pt-4 text-sm text-base-content/70">
    <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-2">#{escape_html(gettext("Notes"))}</h2>
    <ol class="list-decimal space-y-1 pl-5">#{items}</ol>
    </section>
    <style>
    .pk-note-ref{text-decoration:underline dotted;text-underline-offset:3px;position:relative;color:inherit}
    .pk-note-ref sup{color:var(--color-primary,currentColor);font-weight:600;margin-left:1px}
    .pk-note-ref:hover::after,.pk-note-ref:focus-visible::after{content:attr(data-note);position:absolute;bottom:calc(100% + 6px);left:50%;transform:translateX(-50%);width:max-content;max-width:min(20rem,80vw);white-space:normal;background:var(--color-base-200,#eee);color:var(--color-base-content,#111);border:1px solid var(--color-base-300,#ddd);border-radius:.5rem;padding:.5rem .75rem;font-size:.8rem;line-height:1.35;z-index:20;box-shadow:0 4px 12px rgb(0 0 0/.08)}
    .pk-notes li:target{background:var(--color-base-200,#eee);border-radius:.25rem}
    </style>
    """
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    # '#' too: the hashtag-link pass runs after the notes pass, and an
    # entity-encoded hash renders identically while never matching the
    # hashtag regex — a tag mentioned in a note stays plain text.
    |> String.replace("#", "&#35;")
  end

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
      String.contains?(content, "<Audio") ||
      String.contains?(content, "<Showcase") ||
      String.contains?(content, "<Gallery") ||
      String.contains?(content, "<EntityForm")
  end

  # Render markdown using MDEx (comrak), then inject Tailwind/daisyUI classes
  # on each tag.
  defp render_markdown_html(content) do
    content =
      content
      |> normalize_markdown()
      # Restore any `<` masked out of code regions for the component scan
      # (mixed path only); comrak then HTML-escapes it inside the code block.
      |> unmask_scanned_code()

    # Trust model: admin-authored Markdown can include inline HTML
    # (`<div class="grid">…</div>` is a common authoring affordance), so we
    # render with `unsafe: true` — an admin who pastes a `<script>` tag sees it
    # render as live HTML. This is the documented trust boundary; true XSS
    # protection would require a sanitiser like html_sanitize_ex on the output.
    # comrak always escapes code spans/blocks, so fenced examples render as
    # literal text regardless. Re-evaluate if any non-admin-authored input
    # reaches this path (API import, AI-translation prompt-injection on
    # rotating roles).
    case MDEx.to_html(content, @mdex_options) do
      {:ok, html} ->
        add_tailwind_classes(html)

      {:error, _reason} ->
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
    # Mask `<` inside fenced/inline code spans BEFORE scanning for components, so
    # a `<Image>`/`<CTA>`/… shown literally inside a code block (a docs post
    # demonstrating the PHK syntax) no longer matches the component regex. The
    # mask is restored right before MDEx renders each markdown segment, where
    # comrak HTML-escapes it — so it shows as visible code text. Components
    # OUTSIDE code blocks are untouched and still render.
    content
    |> mask_scanned_code()
    |> render_mixed_segments([])
    |> Enum.reverse()
    |> Enum.join()
  end

  # Mask every `<` inside ```fenced``` and `inline` code spans with a sentinel so
  # the component scanner can't match a component shown literally inside code.
  # Backtick/fence delimiters are left intact so the markdown still parses as
  # code. Restored by unmask_scanned_code/1 before MDEx renders.
  defp mask_scanned_code(content) do
    Regex.replace(@code_region_regex, content, fn match ->
      String.replace(match, "<", @code_lt_sentinel)
    end)
  end

  # Restore sentinels back to raw `<`. A no-op on the plain path (which never
  # masks); on the mixed path the restored `<` re-enters MDEx inside a code span,
  # where comrak HTML-escapes it to `&lt;`.
  defp unmask_scanned_code(content) do
    String.replace(content, @code_lt_sentinel, "<")
  end

  defp render_mixed_segments("", acc), do: acc

  defp render_mixed_segments(content, acc) do
    case next_component_match(content) do
      nil ->
        [render_markdown_html(content) | acc]

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
    [render_markdown_html(text) | acc]
  end

  defp add_component(acc, tag, attrs) do
    [render_inline_component(tag, attrs) | acc]
  end

  defp add_block_component(acc, fragment) do
    # A block component's inner content can hold a code span whose `<` was masked
    # for the scan; restore it before PageBuilder renders the fragment.
    [render_block_component(unmask_scanned_code(fragment)) | acc]
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
    |> PageBuilder.Renderer.wrap_stretch(attr_map)
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
    |> PageBuilder.Renderer.wrap_stretch(attr_map)
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  rescue
    error ->
      Logger.warning("Error rendering Video component: #{inspect(error)}")
      "<div class='error'>Error rendering video</div>"
  end

  defp render_inline_component("Audio", attrs) do
    attr_map = parse_xml_attributes(attrs)

    assigns = %{
      __changed__: nil,
      attributes: attr_map,
      variant: Map.get(attr_map, "variant", "default"),
      content: nil,
      children: []
    }

    AudioComponent.render(assigns)
    |> PageBuilder.Renderer.wrap_stretch(attr_map)
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  rescue
    error ->
      Logger.warning("Error rendering Audio component: #{inspect(error)}")
      "<div class='error'>Error rendering audio</div>"
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
    |> PageBuilder.Renderer.wrap_stretch(attr_map)
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
    cond do
      match = Regex.run(@showcase_regex, fragment) ->
        [_full, attrs, body] = match
        render_showcase(parse_xml_attributes(attrs), body)

      match = Regex.run(@gallery_regex, fragment) ->
        [_full, attrs, body] = match
        render_gallery(parse_xml_attributes(attrs), body)

      true ->
        render_page_builder_block(fragment)
    end
  end

  # Images arranged on a slowly turning double helix. See `@helix_css` for why
  # this is pure CSS and how the animation loops.
  #
  # The body is ordinary Markdown image lines, so a gallery reads as a list of
  # pictures in the source and degrades to exactly that if this ever stops
  # rendering:
  #
  #     <Gallery height="520" radius="420">
  #     ![A doorway](https://…/1.jpg)
  #     ![The courtyard](https://…/2.jpg)
  #     </Gallery>
  defp render_gallery(attrs, body) do
    case gallery_images(body) do
      # Nothing usable — better to render nothing than an empty black box.
      [] ->
        ""

      images ->
        motion = gallery_motion(Map.get(attrs, "motion"))
        strands = gallery_int(Map.get(attrs, "strands"), 2, 1, 4)
        turns = gallery_int(Map.get(attrs, "turns"), 2, 1, 6)
        radius = gallery_int(Map.get(attrs, "radius"), 420, 120, 900)
        height = gallery_int(Map.get(attrs, "height"), 520, 200, 1200)
        card_w = gallery_int(Map.get(attrs, "card_width"), 225, 60, 600)
        card_h = gallery_int(Map.get(attrs, "card_height"), 155, 40, 400)
        # Seconds for one card to travel a whole strand.
        duration = gallery_int(Map.get(attrs, "speed"), 80, 10, 600)

        # Runs the strand off both edges, which is what hides the wrap.
        span = round(height * 1.5)
        per_strand = max(ceil(length(images) / strands), 1)

        scene_vars =
          [
            "--pk-hx-height:#{height}px",
            "--pk-hx-radius:#{radius}px",
            "--pk-hx-span:#{span}px",
            "--pk-hx-turns:#{turns}",
            "--pk-hx-card-w:#{card_w}px",
            "--pk-hx-card-h:#{card_h}px",
            "--pk-hx-dur:#{duration}s",
            "--pk-hx-rot:#{Float.round(duration / turns, 3)}s"
          ] ++ gallery_background(Map.get(attrs, "background"))

        gid = "g#{:erlang.phash2({images, height, radius, turns, motion}, 100_000)}"

        geometry = %{
          strands: strands,
          per_strand: per_strand,
          turns: turns,
          duration: duration,
          radius: radius,
          span: span,
          gid: gid,
          motion: motion
        }

        cards =
          images
          |> Enum.with_index()
          |> Enum.map_join("\n", fn {image, i} -> gallery_card(image, i, geometry) end)

        # Scroll mode can't express per-card phase through delays or ranges,
        # so each card gets keyframes carrying its own starting angle.
        keyframes =
          if motion == "scroll" do
            "<style>" <>
              Enum.map_join(0..(length(images) - 1), "", &gallery_scroll_keyframes(&1, geometry)) <>
              "</style>"
          else
            ""
          end

        """
        <figure class="pk-helix#{if motion == "scroll", do: " pk-helix--scroll", else: ""}">
        <div class="pk-helix__scene" style="#{Enum.join(scene_vars, ";")}">
        <div class="pk-helix__world">
        #{cards}
        </div>
        <div class="pk-helix__vignette"></div>
        </div>
        </figure>
        #{keyframes}
        """
        |> Phoenix.HTML.raw()
        |> PageBuilder.Renderer.wrap_stretch(showcase_lane(attrs))
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()
    end
  rescue
    error ->
      Logger.warning("Error rendering Gallery component: #{inspect(error)}")
      ""
  end

  defp gallery_card(%{src: src, alt: alt}, i, geo) do
    %{strands: strands, per_strand: per_strand, turns: turns, duration: duration} = geo
    %{radius: radius, span: span, gid: gid, motion: motion} = geo
    strand = rem(i, strands)
    index = div(i, strands)
    # Where this card starts along its strand, 0..1.
    progress = index / per_strand
    # Strand phase, in turns: two strands sit half a turn apart.
    phase = strand / strands

    # Negative delays start each animation partway through, which is what
    # spreads the cards along the strand instead of stacking them at the top.
    move_delay = -Float.round(progress * duration, 3)

    # The depth animation runs on the ROTATION period, so its offset is the
    # card's absolute angle expressed in rotations.
    rotations = phase + progress * turns
    depth_delay = -Float.round(:math.fmod(rotations, 1.0) * (duration / turns), 3)

    # The resting pose, for when animations don't run at all. Carried as a
    # CUSTOM PROPERTY rather than as `transform` directly: an inline transform
    # would also apply on devices that fall back to the plain grid, throwing
    # its cards off-screen. The `@supports` block is what turns this into an
    # actual transform, so it exists only where the helix does.
    angle = phase + progress * turns
    y = (progress - 0.5) * span

    static =
      "--pk-hx-rest:translate(-50%,-50%) rotateY(#{Float.round(angle, 4)}turn) " <>
        "translateZ(#{radius}px) translateY(#{Float.round(y, 1)}px)"

    # Delays travel as custom properties rather than as `animation-delay`
    # directly, because the depth scrim lives on a ::after that needs the same
    # offset — and a pseudo-element can inherit a custom property but cannot
    # read its host's animation-delay.
    style =
      [
        "--pk-hx-phase:#{Float.round(phase, 4)}turn",
        "--pk-hx-d1:#{move_delay}s",
        "--pk-hx-d2:#{depth_delay}s",
        static
      ]
      |> then(fn base ->
        # Scroll mode names this card's own keyframes; drift mode uses the
        # shared pair declared in the stylesheet.
        if motion == "scroll" do
          base ++ ["--pk-hx-k1:pk-hx-#{gid}-m#{i}", "--pk-hx-k2:pk-hx-#{gid}-s#{i}"]
        else
          base
        end
      end)
      |> Enum.join(";")

    ~s(<div class="pk-helix__card" style="#{style}">) <>
      ~s(<img src="#{src}" alt="#{alt}" loading="lazy" decoding="async"></div>)
  end

  # One card's scroll-driven pass: it starts wherever it belongs on the helix
  # and travels a full strand length as the gallery crosses the viewport.
  #
  # The depth stops are computed here rather than shared, because with the
  # starting angle baked in, each card meets the far side of the cylinder at a
  # different point of its own pass.
  defp gallery_scroll_keyframes(i, geo) do
    %{strands: strands, per_strand: per_strand, turns: turns} = geo
    %{radius: radius, span: span, gid: gid} = geo

    strand = rem(i, strands)
    index = div(i, strands)
    progress = index / per_strand
    phase = strand / strands

    a0 = phase + progress * turns
    y0 = (progress - 0.5) * span

    move =
      "@keyframes pk-hx-#{gid}-m#{i}{" <>
        "from{transform:translate(-50%,-50%) rotateY(#{Float.round(a0, 4)}turn) " <>
        "translateZ(#{radius}px) translateY(#{Float.round(y0, 1)}px)}" <>
        "to{transform:translate(-50%,-50%) rotateY(#{Float.round(a0 + turns, 4)}turn) " <>
        "translateZ(#{radius}px) translateY(#{Float.round(y0 + span, 1)}px)}}"

    scrim =
      0..8
      |> Enum.map_join("", fn stop ->
        pct = stop / 8
        # Where this card is facing at that point of its pass.
        angle = (a0 + pct * turns) * 2 * :math.pi()
        depth = (:math.cos(angle) + 1) / 2
        opacity = Float.round(0.85 * (1 - depth * depth), 3)
        "#{Float.round(pct * 100, 1)}%{opacity:#{opacity}}"
      end)

    move <> "@keyframes pk-hx-#{gid}-s#{i}{" <> scrim <> "}"
  end

  # The pictures, in source order. Two forms are accepted: ordinary Markdown
  # image lines, and `<Image file_uuid="…">` tags — the latter being what the
  # editor's picker inserts, and what survives a change of storage prefix or
  # signing secret, since the URL is resolved at render time rather than
  # frozen into the post.
  #
  # Anything else in the body is ignored rather than rendered, so a stray
  # blank line or comment can't produce a card with no picture in it.
  defp gallery_images(body) do
    body = to_string(body)

    (gallery_markdown_images(body) ++ gallery_uuid_images(body))
    |> Enum.sort_by(& &1.at)
    |> Enum.map(&Map.delete(&1, :at))
    # Same scheme allow-list every other component's image goes through.
    # Escaping alone let `![x](javascript:…)` reach a public `src`; browsers
    # won't run a script URL from an `<img>`, so nothing was exploitable, but
    # one component quietly trusting a scheme its siblings reject is how the
    # next component that CAN run it gets written.
    |> Enum.filter(&showcase_safe_src?(&1.src))
  end

  defp gallery_markdown_images(body) do
    ~r/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/
    |> Regex.scan(body, return: :index)
    |> Enum.map(fn [{at, _}, alt_r, src_r] ->
      %{
        at: at,
        src: body |> binary_part(elem(src_r, 0), elem(src_r, 1)) |> escape_html(),
        alt: body |> binary_part(elem(alt_r, 0), elem(alt_r, 1)) |> escape_html()
      }
    end)
  end

  defp gallery_uuid_images(body) do
    # Matched as a whole tag and then parsed with the module's own attribute
    # reader, rather than picking attributes out with one clever regex: an
    # optional capture group after a lazy quantifier is happy to match nothing,
    # which silently dropped every alt text.
    ~r/<Image\s([^>]*)>/
    |> Regex.scan(body, return: :index)
    |> Enum.map(fn [{at, _}, {attr_start, attr_len}] ->
      attrs = body |> binary_part(attr_start, attr_len) |> parse_xml_attributes()
      {at, attrs}
    end)
    |> Enum.filter(fn {_at, attrs} ->
      uuid = Map.get(attrs, "file_uuid")
      is_binary(uuid) and Shared.uuid_format?(uuid)
    end)
    |> Enum.map(fn {at, attrs} ->
      %{
        at: at,
        src: escape_html(URLSigner.signed_url(Map.get(attrs, "file_uuid"), "large")),
        alt: escape_html(Map.get(attrs, "alt", ""))
      }
    end)
  rescue
    _ -> []
  end

  # "drift" (default) turns on its own; "scroll" ties the rotation to the
  # reader's scroll. Anything else falls back to drift rather than erroring —
  # a typo in an attribute shouldn't cost you the gallery.
  defp gallery_motion("scroll"), do: "scroll"
  defp gallery_motion(_), do: "drift"

  # The default is the theme's own surface, so the gallery belongs to the page
  # rather than sitting on it as a foreign panel. An explicit override is
  # allow-listed rather than escaped: this lands inside a `style` attribute,
  # where the dangerous character is `;` — it starts a new declaration, and
  # HTML-escaping doesn't touch it. Anything not recognisably a colour is
  # dropped and the theme default stands.
  @gallery_color_regex ~r/^(#[0-9a-fA-F]{3,8}|(rgb|rgba|hsl|hsla|oklch|oklab|color-mix)\([^;{}"'()]*\)|var\(--[a-zA-Z0-9_-]+\)|[a-zA-Z]{3,20})$/

  defp gallery_background(bg) when is_binary(bg) do
    trimmed = String.trim(bg)

    if trimmed != "" and Regex.match?(@gallery_color_regex, trimmed) do
      ["--pk-hx-bg:#{trimmed}"]
    else
      []
    end
  end

  defp gallery_background(_bg), do: []

  defp gallery_int(value, default, min, max) do
    case value |> to_string() |> String.trim() |> Integer.parse() do
      {n, _} -> n |> max(min) |> min(max)
      :error -> default
    end
  end

  defp render_page_builder_block(fragment) do
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

  # ===========================================================================
  # <Showcase> — image bled to one edge, text on the other, sharing an overlap
  #
  #     <Showcase file_uuid="018e…" side="left" overlap="18">
  #     ### Paintings, reconstructed
  #     Excitingly recreated and brought to life.
  #     </Showcase>
  #
  # A self-contained band: it paints its OWN background and text colour rather
  # than inheriting the host theme's, because the text sits partly over the
  # image and partly over the band — one colour has to work for both, and the
  # host's base-100 could be anything. `tone` picks which ("dark" = dark band,
  # light text; "light" = the inverse; "none" = inherit and no scrim).
  #
  # The overlap is a real grid track shared by the image and the text, so the
  # browser does the layout — no absolute positioning, no JS. The scrim over
  # the image strengthens with the overlap (more text over image = more tint),
  # and on narrow screens, where the two stack and the overlap is total, it
  # becomes a full vertical gradient.
  # ===========================================================================

  defp render_showcase(attrs, body) do
    text_html = render_markdown_html(body)

    case showcase_src(attrs) do
      # No usable image — degrade to the prose alone rather than an empty band.
      nil ->
        text_html

      src ->
        side = if Map.get(attrs, "side") == "right", do: "right", else: "left"
        tone = showcase_tone(Map.get(attrs, "tone"))
        overlap = showcase_overlap(Map.get(attrs, "overlap"))
        alt = attrs |> Map.get("alt", "") |> escape_html()
        height = showcase_height(Map.get(attrs, "height"))

        classes =
          ["pk-showcase", "pk-showcase--#{side}", "pk-showcase--#{tone}"] ++
            if(height, do: ["pk-showcase--fixed"], else: [])

        vars =
          [
            "--pk-sc-overlap:#{overlap}%",
            "--pk-sc-shade:#{showcase_shade(overlap)}",
            "--pk-sc-fade:#{showcase_fade(overlap)}%"
          ] ++ if(height, do: ["--pk-sc-height:#{height}"], else: [])

        html = """
        <figure class="#{Enum.join(classes, " ")}" style="#{Enum.join(vars, ";")}">
        <div class="pk-showcase__media"><img src="#{src}" alt="#{alt}" loading="lazy" decoding="async"></div>
        <div class="pk-showcase__text">#{text_html}</div>
        </figure>
        """

        html
        |> Phoenix.HTML.raw()
        |> PageBuilder.Renderer.wrap_stretch(showcase_lane(attrs))
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()
    end
  rescue
    error ->
      Logger.warning("Error rendering Showcase component: #{inspect(error)}")
      "<div class='error'>Error rendering showcase</div>"
  end

  # Full-bleed by default — the look is the image running off the page edge —
  # but an author can dial it back with the same align/stretch attrs every
  # other component takes.
  defp showcase_lane(attrs) do
    if Map.has_key?(attrs, "align") or Map.has_key?(attrs, "stretch") do
      attrs
    else
      Map.put(attrs, "align", "full")
    end
  end

  defp showcase_src(attrs) do
    file_uuid = Map.get(attrs, "file_uuid")
    src = Map.get(attrs, "src")

    cond do
      is_binary(file_uuid) and Shared.uuid_format?(file_uuid) ->
        URLSigner.signed_url(file_uuid, Map.get(attrs, "file_variant", "large"))

      is_binary(src) and showcase_safe_src?(src) ->
        escape_html(src)

      true ->
        nil
    end
  end

  # http(s) or root-relative only — same posture as <Audio>/<Image>; a
  # javascript:/data: src never reaches the element.
  defp showcase_safe_src?("/" <> _), do: true
  defp showcase_safe_src?("http://" <> _), do: true
  defp showcase_safe_src?("https://" <> _), do: true
  defp showcase_safe_src?(_), do: false

  defp showcase_tone("dark"), do: "dark"
  defp showcase_tone("light"), do: "light"
  defp showcase_tone("none"), do: "none"
  defp showcase_tone(_), do: "page"

  defp showcase_overlap(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 and n <= @showcase_max_overlap -> n
      _ -> @showcase_default_overlap
    end
  end

  defp showcase_overlap(_), do: @showcase_default_overlap

  # The more the text sits over the image, the more the image is tinted
  # toward the band colour so the text stays readable. Capped so the image
  # never washes out entirely.
  defp showcase_shade(overlap) do
    (0.35 + overlap * 0.012)
    |> min(0.8)
    |> Float.round(2)
  end

  # Where the scrim starts, as a percentage across the image. A wider overlap
  # pulls the fade earlier so more of the image is already blended by the time
  # the text reaches it.
  defp showcase_fade(overlap), do: (70 - overlap) |> max(30) |> min(70)

  # How tall the image area is. Without this the band's height comes from the
  # image's own aspect at whatever width the lane gives it, which on a
  # full-bleed band can be very tall. A preset or a plain pixel count (clamped)
  # pins it and lets `object-fit: cover` crop. nil = keep the natural aspect.
  defp showcase_height("short"), do: "18rem"
  defp showcase_height("medium"), do: "26rem"
  defp showcase_height("tall"), do: "38rem"
  defp showcase_height("auto"), do: nil

  defp showcase_height(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= @showcase_min_height and n <= @showcase_max_height -> "#{n}px"
      _ -> nil
    end
  end

  defp showcase_height(_), do: nil

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

  defp tag_link_context(post) do
    with group when is_binary(group) <- Map.get(post, :group),
         language when is_binary(language) <- Map.get(post, :language) do
      {group, language}
    else
      _ -> nil
    end
  end

  defp render_and_cache(post, cache_key, opts) do
    html =
      render_markdown(post.content,
        tag_links: tag_link_context(post),
        notes_style: Keyword.get(opts, :notes_style)
      )

    # Cache the rendered HTML
    put_cached(cache_key, html)

    {:ok, html}
  end

  defp build_cache_key(post, opts) do
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

    # The notes style changes the emitted ref markup — a group flipping the
    # setting must not serve the other style's cached HTML.
    style_token =
      case Keyword.get(opts, :notes_style) do
        "panel" -> ":np"
        _ -> ""
      end

    "#{@cache_version}:publishing_post:#{post.group}:#{identifier}:#{post.language}:#{content_hash}#{style_token}"
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
