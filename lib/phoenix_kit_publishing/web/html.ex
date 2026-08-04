defmodule PhoenixKit.Modules.Publishing.Web.HTML do
  @moduledoc """
  HTML rendering functions for Publishing.Web.Controller.
  """
  use PhoenixKitWeb, :html
  use Gettext, backend: PhoenixKitPublishing.Gettext

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PublishingCategory
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings

  @timestamp_modes Constants.timestamp_modes()
  @slug_modes Constants.slug_modes()

  @og_render_key "publishing_render_og_tags"

  import PhoenixKitWeb.Components.LanguageSwitcher

  @doc """
  Renders the OpenGraph + Twitter Card meta tags for a public page from the
  `:og` map the controller builds.

  These are emitted in-page (inside the rendered body) so a social preview
  works out of the box even when the host's root layout doesn't render the
  forwarded `:og` assign in `<head>` — most host apps ship their own root
  layout. The same `:og` map is ALSO forwarded via `module_assigns`, so a host
  that does render it in `<head>` gets the strictly-correct placement; such a
  host disables the in-page copy via `publishing_render_og_tags` to avoid
  duplicate tags. Renders nothing when `:og` is absent (e.g. the groups index).
  """
  attr :og, :map, default: nil

  def og_meta_tags(assigns) do
    ~H"""
    <%= if @og && (@og[:title] || @og[:url]) do %>
      <meta property="og:type" content={@og[:type] || "article"} />
      <%= if @og[:title] do %>
        <meta property="og:title" content={@og[:title]} />
        <meta name="twitter:title" content={@og[:title]} />
      <% end %>
      <%= if @og[:description] do %>
        <meta property="og:description" content={@og[:description]} />
        <meta name="twitter:description" content={@og[:description]} />
      <% end %>
      <%= if @og[:image] do %>
        <meta property="og:image" content={@og[:image]} />
        <meta name="twitter:image" content={@og[:image]} />
        <meta :if={@og[:image_type]} property="og:image:type" content={@og[:image_type]} />
        <meta :if={@og[:image_width]} property="og:image:width" content={@og[:image_width]} />
        <meta :if={@og[:image_height]} property="og:image:height" content={@og[:image_height]} />
      <% end %>
      <meta :if={@og[:url]} property="og:url" content={@og[:url]} />
      <meta :if={@og[:locale]} property="og:locale" content={@og[:locale]} />
      <meta property="og:site_name" content={Settings.get_project_title()} />
      <meta
        name="twitter:card"
        content={if @og[:image], do: "summary_large_image", else: "summary"}
      />
    <% end %>
    """
  end

  # Whether to emit the in-page OG/Twitter tags. On by default; a host that
  # renders the forwarded `:og` assign in its own `<head>` flips this off from
  # /admin/settings/publishing so the tags aren't duplicated.
  defp og_tags_enabled? do
    Settings.get_boolean_setting(@og_render_key, true)
  rescue
    _ -> true
  end

  @doc """
  Whether group RSS feeds are served (`publishing_feeds_enabled`, default on).
  Read by the controller's feed branch and by the listing's autodiscovery link.
  """
  def feeds_enabled? do
    Settings.get_boolean_setting("publishing_feeds_enabled", true)
  rescue
    _ -> true
  end

  # Whether the post page emits the JSON-LD Article script (default on).
  # Invisible to readers; a host that builds its own structured data can
  # disable it site-wide.
  defp jsonld_enabled? do
    Settings.get_boolean_setting("publishing_render_jsonld", true)
  rescue
    _ -> true
  end

  @doc """
  Renders the JSON-LD `Article` structured-data script for a post page, built
  from the same `:og` map the meta tags use (title/description/image/url are
  already override- and plugin-refined there) plus the post's publish date.
  Rendered in-page for the same reason as the OG tags: search engines read
  body placement, and the host owns `<head>`.
  """
  attr :og, :map, default: nil
  attr :post, :map, required: true
  attr :language, :string, required: true

  def jsonld_script(assigns) do
    data = article_jsonld(assigns.og, assigns.post, assigns.language)
    # escape: :html_safe encodes angle brackets as unicode escapes inside
    # JSON strings, so no value can smuggle a closing script tag and break
    # out of the element.
    assigns = assign(assigns, :json, data && Jason.encode!(data, escape: :html_safe))

    ~H"""
    <script :if={@json} type="application/ld+json">
      <%= Phoenix.HTML.raw(@json) %>
    </script>
    """
  end

  defp article_jsonld(og, post, language) do
    if og && og[:title] do
      %{
        "@context" => "https://schema.org",
        "@type" => "Article",
        "headline" => og[:title],
        "inLanguage" => language
      }
      |> maybe_put_jsonld("description", og[:description])
      |> maybe_put_jsonld("image", og[:image])
      |> maybe_put_jsonld("mainEntityOfPage", og[:url])
      |> maybe_put_jsonld("datePublished", jsonld_date_published(post))
      |> maybe_put_jsonld("publisher", %{
        "@type" => "Organization",
        "name" => Settings.get_project_title()
      })
    end
  end

  # The effective publish date, matching the feed/listing notion: post_date for
  # timestamp-mode posts, the version's published_at otherwise. Safe access —
  # a post map may lack either field.
  defp jsonld_date_published(post) do
    case post[:date] do
      %Date{} = date -> Date.to_iso8601(date)
      _ -> get_in(post, [:metadata, :published_at])
    end
  end

  defp maybe_put_jsonld(map, _key, nil), do: map
  defp maybe_put_jsonld(map, _key, ""), do: map
  defp maybe_put_jsonld(map, key, value), do: Map.put(map, key, value)

  # ===========================================================================
  # Scroll navigation (per-group). Additive visuals only — never replaces native
  # scroll, so keyboard/touch/screen-reader behaviour stays intact. See
  # dev_docs/research/2026-07-16-custom-scrollbars-accessibility.md.
  # ===========================================================================

  @doc """
  Emits a `<style>` that recolors the page's native scrollbar to the daisyUI
  theme when the group opts into "branded"/"thin". "default" renders nothing
  (the browser's native bar is untouched). Only recolors/resizes the real
  scrollbar — scrolling stays native.
  """
  attr :style, :string, default: "default"

  def scrollbar_style_tag(assigns) do
    ~H"""
    {Phoenix.HTML.raw(scrollbar_style_html(@style))}
    """
  end

  defp scrollbar_style_html(style) when style in ["branded", "thin"] do
    width = if style == "thin", do: "9px", else: "14px"
    thin = if style == "thin", do: "scrollbar-width: thin;", else: ""

    """
    <style>
    :root {
      scrollbar-color: var(--color-primary, #6b7280) var(--color-base-300, #d1d5db);
      #{thin}
    }
    ::-webkit-scrollbar { width: #{width}; height: #{width}; }
    ::-webkit-scrollbar-track { background: var(--color-base-200, #e5e7eb); }
    ::-webkit-scrollbar-thumb {
      background: var(--color-primary, #6b7280);
      border-radius: 9999px;
      border: 3px solid var(--color-base-200, #e5e7eb);
    }
    </style>
    """
  end

  defp scrollbar_style_html(_style), do: ""

  @doc """
  Renders a thin reading-progress bar fixed to the top of the viewport that
  fills as the reader scrolls the article. Decorative (`aria-hidden`), pointer
  transparent, and honors `prefers-reduced-motion`.
  """
  attr :enabled, :boolean, default: false

  def reading_progress(assigns) do
    ~H"""
    <%= if @enabled do %>
      <div class="pk-reading-progress" aria-hidden="true">
        <div class="pk-reading-progress__bar" id="pk-progress-bar"></div>
      </div>
      {Phoenix.HTML.raw(reading_progress_assets())}
    <% end %>
    """
  end

  defp reading_progress_assets do
    """
    <style>
    .pk-reading-progress { position: fixed; top: 0; left: 0; right: 0; height: 3px; z-index: 60; pointer-events: none; background: transparent; }
    .pk-reading-progress__bar { height: 100%; width: 0; background: var(--color-primary, #6b7280); transition: width .1s linear; }
    @media (prefers-reduced-motion: reduce) { .pk-reading-progress__bar { transition: none; } }
    </style>
    <script>
    (function () {
      if (window.__pkReadingProgress) return;
      window.__pkReadingProgress = true;
      function update() {
        var bar = document.getElementById('pk-progress-bar');
        if (!bar) return;
        var doc = document.documentElement;
        var max = doc.scrollHeight - doc.clientHeight;
        var pct = max > 0 ? (doc.scrollTop / max) * 100 : 0;
        bar.style.width = pct + '%';
      }
      window.addEventListener('scroll', update, { passive: true });
      window.addEventListener('resize', update, { passive: true });
      if (document.readyState !== 'loading') update();
      else document.addEventListener('DOMContentLoaded', update);
    })();
    </script>
    """
  end

  @doc """
  Renders a slim heading-anchor rail on post pages: a fixed side rail with a
  tick per `<h2>/<h3>/<h4>` in the article; hover reveals the heading text,
  click smooth-scrolls to it, and the current section is highlighted as you
  scroll. Built client-side (assigns heading ids in the browser, so the cached
  render pipeline is untouched) as a real `<nav>` of links — keyboard and
  screen-reader accessible. Hidden on narrow screens; honors reduced-motion.
  """
  attr :enabled, :boolean, default: false

  def reading_headings(assigns) do
    ~H"""
    <%= if @enabled do %>
      <div id="pk-headings-config" data-label={gettext("On this page")} hidden></div>
      {Phoenix.HTML.raw(reading_headings_assets())}
    <% end %>
    """
  end

  @doc """
  Drives `<Gallery motion="scroll">` where the browser has no scroll-driven
  animations.

  The gallery expresses scroll-linking in pure CSS (`animation-timeline`), and
  that is the real implementation — this does nothing at all where it works.
  But support is only around 84% of browsers: Firefox has it from 156, Safari
  from 26. Everywhere else the `@supports` gate falls through to the drift
  animation, which is a perfectly good gallery but silently not the feature
  that was asked for.

  So this is enhancement in the strict sense: no JS still gives you a turning
  helix, a modern browser gives you the CSS one, and only the gap in between
  is filled here.

  It works by pausing the drift animations and setting their `currentTime`
  from scroll position rather than re-implementing the geometry. Every card's
  phase already lives in its own negative delay, so a single virtual clock
  driven by scroll reproduces the exact arrangement CSS would have produced —
  there is no second copy of the maths to drift out of step with the first.
  """
  def helix_scroll_fallback(assigns) do
    ~H"""
    {Phoenix.HTML.raw(helix_scroll_fallback_script())}
    """
  end

  defp helix_scroll_fallback_script do
    ~S"""
    <script>
    (function () {
      if (window.__pkHelixScroll) return;
      window.__pkHelixScroll = true;

      function init() {
        // Where the CSS works, leave it entirely alone.
        if (window.CSS && CSS.supports && CSS.supports('animation-timeline: view()')) return;

        var figures = document.querySelectorAll('.pk-helix--scroll');
        if (!figures.length) return;
        if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

        var scenes = [];
        figures.forEach(function (fig) {
          var anims = [];
          fig.querySelectorAll('.pk-helix__card').forEach(function (card) {
            var list = card.getAnimations ? card.getAnimations({ subtree: true }) : [];
            list.forEach(function (a) {
              try { a.pause(); } catch (e) { return; }
              anims.push(a);
            });
          });
          if (!anims.length) return;

          // One virtual clock for the whole gallery: the cards' own delays
          // supply their phase, exactly as they do when it runs on time.
          var span = 0;
          anims.forEach(function (a) {
            var t = a.effect && a.effect.getTiming ? a.effect.getTiming().duration : 0;
            if (typeof t === 'number' && t > span) span = t;
          });
          if (!span) return;
          scenes.push({ el: fig, anims: anims, span: span });
        });
        if (!scenes.length) return;

        var ticking = false;
        function apply() {
          ticking = false;
          var vh = window.innerHeight || document.documentElement.clientHeight;
          scenes.forEach(function (s) {
            var r = s.el.getBoundingClientRect();
            // 0 as the figure's top edge reaches the bottom of the viewport,
            // 1 as its bottom edge leaves the top — the same span the CSS
            // `cover` range describes.
            var total = r.height + vh;
            var p = total > 0 ? (vh - r.top) / total : 0;
            p = p < 0 ? 0 : p > 1 ? 1 : p;
            var t = p * s.span;
            s.anims.forEach(function (a) {
              try { a.currentTime = t; } catch (e) {}
            });
          });
        }
        function onScroll() {
          if (ticking) return;
          ticking = true;
          window.requestAnimationFrame(apply);
        }

        window.addEventListener('scroll', onScroll, { passive: true });
        window.addEventListener('resize', onScroll, { passive: true });
        apply();
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
      } else {
        init();
      }
    })();
    </script>
    """
  end

  defp reading_headings_assets do
    ~S"""
    <style>
    .pk-heading-rail { position: fixed; top: 6vh; right: .5rem; height: 88vh; z-index: 40; }
    @media (max-width: 1024px) { .pk-heading-rail { display: none; } }
    .pk-heading-rail__item { position: absolute; right: 0; transform: translateY(-50%); display: flex; align-items: center; justify-content: flex-end; gap: .5rem; text-decoration: none; padding: .35rem .5rem; border-radius: 9999px; transition: background-color .15s ease; }
    .pk-heading-rail__tick { display: block; width: .5rem; height: .5rem; border-radius: 9999px; background: var(--color-base-content, #9ca3af); opacity: .45; transition: transform .15s ease, background-color .15s ease, opacity .15s ease; }
    .pk-heading-rail__item--h3 .pk-heading-rail__tick { width: .4rem; height: .4rem; }
    .pk-heading-rail__item--h4 .pk-heading-rail__tick { width: .3rem; height: .3rem; }
    .pk-heading-rail__label { font-size: .72rem; line-height: 1.2; color: var(--color-base-content, #1f2937); background: var(--color-base-100, #fff); padding: .2rem .45rem; border-radius: .3rem; box-shadow: 0 1px 4px rgba(0,0,0,.18); white-space: nowrap; max-width: 16rem; overflow: hidden; text-overflow: ellipsis; opacity: 0; transform: translateX(.25rem); transition: opacity .15s ease, transform .15s ease; pointer-events: none; }
    .pk-heading-rail__item:hover { background-color: var(--color-base-200, #e5e7eb); z-index: 2; }
    .pk-heading-rail__item.is-current { z-index: 1; }
    .pk-heading-rail__item:hover .pk-heading-rail__tick, .pk-heading-rail__item.is-current .pk-heading-rail__tick { opacity: 1; background: var(--color-primary, #4f46e5); transform: scale(1.6); }
    .pk-heading-rail__item:hover .pk-heading-rail__label, .pk-heading-rail__item.is-current .pk-heading-rail__label, .pk-heading-rail__item:focus-visible .pk-heading-rail__label { opacity: 1; transform: translateX(0); }
    .pk-heading-rail__item:focus-visible { outline: 2px solid var(--color-primary, #4f46e5); outline-offset: 1px; }
    @keyframes pk-heading-flash { 0% { box-shadow: 0 0 0 0 var(--color-primary, #4f46e5); } 30% { box-shadow: 0 0 0 6px var(--color-primary, #4f46e5); } 100% { box-shadow: 0 0 0 0 rgba(0,0,0,0); } }
    .pk-heading-flash { animation: pk-heading-flash 1.2s ease-out 1; border-radius: .25rem; }
    @media (prefers-reduced-motion: reduce) { .pk-heading-flash { animation: none; outline: 2px solid var(--color-primary, #4f46e5); } }
    </style>
    <script>
    (function () {
      if (window.__pkHeadingRail) return;
      window.__pkHeadingRail = true;
      function slugify(t) { return (t || '').toLowerCase().trim().replace(/[^\w\s-]/g, '').replace(/\s+/g, '-').slice(0, 60) || 'section'; }
      function init() {
        var container = document.querySelector('.post-container');
        if (!container) return;
        var heads = Array.prototype.slice.call(container.querySelectorAll('h2, h3, h4'));
        if (heads.length < 2) return;
        var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        var cfg = document.getElementById('pk-headings-config');
        var nav = document.createElement('nav');
        nav.className = 'pk-heading-rail';
        nav.setAttribute('aria-label', (cfg && cfg.getAttribute('data-label')) || 'On this page');
        var items = {}, ids = [];
        heads.forEach(function (h) {
          if (!h.id) { var base = slugify(h.textContent), s = base, i = 1; while (document.getElementById(s)) { s = base + '-' + (i++); } h.id = s; }
          var a = document.createElement('a');
          a.href = '#' + h.id;
          a.className = 'pk-heading-rail__item pk-heading-rail__item--' + h.tagName.toLowerCase();
          a.setAttribute('data-target', h.id);
          var label = document.createElement('span'); label.className = 'pk-heading-rail__label'; label.textContent = (h.textContent || '').trim();
          var tick = document.createElement('span'); tick.className = 'pk-heading-rail__tick';
          a.appendChild(label); a.appendChild(tick);
          nav.appendChild(a); items[h.id] = a; ids.push(h.id);
        });
        document.body.appendChild(nav);

        // Position each dot at the vertical fraction where its heading sits in the
        // document — same as the timeline rail — so the marks track the content
        // instead of floating in a centered stack.
        function position() {
          var docH = document.documentElement.scrollHeight || 1;
          var railH = nav.clientHeight || Math.round(window.innerHeight * 0.88);
          var arr = heads.map(function (h) {
            var mid = h.getBoundingClientRect().top + window.scrollY + h.offsetHeight / 2;
            return { id: h.id, pos: Math.max(0, Math.min(1, mid / docH)) * railH };
          });
          var minGap = 14;
          for (var i = 1; i < arr.length; i++) {
            if (arr[i].pos < arr[i - 1].pos + minGap) arr[i].pos = arr[i - 1].pos + minGap;
          }
          var over = arr.length ? arr[arr.length - 1].pos - railH : 0;
          if (over > 0) arr.forEach(function (p) { p.pos = Math.max(0, p.pos - over); });
          arr.forEach(function (p) { items[p.id].style.top = p.pos + 'px'; });
        }

        nav.addEventListener('click', function (e) {
          var a = e.target.closest('.pk-heading-rail__item'); if (!a) return;
          e.preventDefault();
          var id = a.getAttribute('data-target');
          var el = document.getElementById(id);
          if (el) {
            el.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'start' });
            try { history.replaceState(null, '', '#' + id); } catch (err) {}
            setTimeout(function () {
              el.classList.remove('pk-heading-flash'); void el.offsetWidth; el.classList.add('pk-heading-flash');
              setTimeout(function () { el.classList.remove('pk-heading-flash'); }, 1300);
            }, reduce ? 0 : 400);
          }
        });

        // Current heading tracks scroll position, matching the listing timeline rail:
        // a reference line runs from the top of the viewport (scrolled to top) to the
        // bottom (scrolled to bottom), and the heading whose midpoint sits nearest that
        // line is emphasized. This ties the highlight to % scrolled rather than to
        // whichever heading last crossed a fixed top line — so the last heading lights
        // up when you reach the very bottom, even if it never passes the top of the page.
        function refresh() {
          var maxScroll = document.documentElement.scrollHeight - window.innerHeight;
          var pct = maxScroll > 0 ? Math.min(1, Math.max(0, window.scrollY / maxScroll)) : 0;
          var refY = pct * window.innerHeight;
          var current = null, best = Infinity;
          heads.forEach(function (h) {
            var r = h.getBoundingClientRect();
            var dist = Math.abs(r.top + r.height / 2 - refY);
            if (dist < best) { best = dist; current = h.id; }
          });
          ids.forEach(function (id) { items[id].classList.toggle('is-current', id === current); });
        }

        // Hide the whole rail when the page is short enough that there's no
        // scrollbar — a jump-to-heading rail is pointless with nothing to scroll.
        // Re-checked on load/resize since late images can make a short page scroll.
        function updateVisibility() {
          var d = document.documentElement;
          nav.style.display = d.scrollHeight > d.clientHeight + 4 ? '' : 'none';
        }

        position(); refresh(); updateVisibility();
        var pkTick = false;
        window.addEventListener('scroll', function () {
          if (pkTick) return;
          pkTick = true;
          requestAnimationFrame(function () { refresh(); pkTick = false; });
        }, { passive: true });
        window.addEventListener('resize', function () { position(); refresh(); updateVisibility(); }, { passive: true });
        window.addEventListener('load', function () { position(); refresh(); updateVisibility(); });
        setTimeout(function () { position(); refresh(); updateVisibility(); }, 600);
      }
      if (document.readyState !== 'loading') init();
      else document.addEventListener('DOMContentLoaded', init);
    })();
    </script>
    """
  end

  @doc """
  Renders a date-timeline rail on the group listing: a fixed side rail with a
  marker per distinct year found across the rendered post cards (which carry a
  `data-post-date`); click a year to smooth-scroll to its first post, and the
  current year highlights as you scroll. Only appears when 2+ years are present.
  Built client-side as an accessible `<nav>` of links; hidden on narrow screens.
  """
  attr :enabled, :boolean, default: false
  attr :granularity, :string, default: "auto"

  def scroll_timeline(assigns) do
    # The rail is built client-side, so its month labels + aria-label ride the
    # config element — otherwise they'd be hardcoded English inside the static
    # JS string on otherwise fully-localized public pages.
    assigns =
      assign(assigns, :months_json, Jason.encode!(translated_abbreviated_month_names()))

    ~H"""
    <%= if @enabled do %>
      <div
        id="pk-timeline-config"
        data-granularity={@granularity}
        data-months={@months_json}
        data-label={gettext("Jump to date")}
        hidden
      >
      </div>
      {Phoenix.HTML.raw(scroll_timeline_assets())}
    <% end %>
    """
  end

  defp scroll_timeline_assets do
    ~S"""
    <style>
    .pk-timeline-rail { position: fixed; top: 6vh; right: .5rem; height: 88vh; z-index: 40; }
    @media (max-width: 1024px) { .pk-timeline-rail { display: none; } }
    .pk-timeline-rail__item { position: absolute; right: 0; transform: translateY(-50%); display: flex; align-items: center; justify-content: flex-end; gap: .5rem; text-decoration: none; font-size: .7rem; line-height: 1; color: var(--color-base-content, #6b7280); opacity: .5; padding: .35rem .6rem; border-radius: 9999px; transition: color .15s ease, opacity .15s ease, background-color .15s ease; }
    .pk-timeline-rail__label { font-variant-numeric: tabular-nums; white-space: nowrap; transition: all .15s ease; }
    .pk-timeline-rail__tick { display: block; width: .5rem; height: .5rem; border-radius: 9999px; background: var(--color-base-content, #9ca3af); opacity: .5; transition: transform .15s ease, background-color .15s ease, opacity .15s ease; }
    .pk-timeline-rail__item.is-active { opacity: 1; color: var(--color-base-content, #111827); font-weight: 600; }
    .pk-timeline-rail__item.is-active .pk-timeline-rail__tick { background: var(--color-primary, #4f46e5); opacity: 1; transform: scale(1.4); }
    .pk-timeline-rail__item:hover { opacity: 1; background-color: var(--color-base-200, #e5e7eb); z-index: 2; }
    .pk-timeline-rail__item:hover .pk-timeline-rail__label { font-weight: 700; font-size: .84rem; }
    .pk-timeline-rail__item:hover .pk-timeline-rail__tick { background: var(--color-primary, #4f46e5); opacity: 1; transform: scale(2); }
    .pk-timeline-rail__item:focus-visible { outline: 2px solid var(--color-primary, #4f46e5); outline-offset: 1px; }
    .pk-timeline-rail--dense .pk-timeline-rail__item { padding: .2rem .5rem; }
    .pk-timeline-rail--dense .pk-timeline-rail__label { max-width: 0; opacity: 0; overflow: hidden; }
    .pk-timeline-rail--dense .pk-timeline-rail__item:hover .pk-timeline-rail__label { max-width: 12rem; opacity: 1; }
    .pk-timeline-rail__item.is-current { opacity: 1; color: var(--color-base-content, #111827); font-weight: 600; z-index: 1; }
    .pk-timeline-rail--dense .pk-timeline-rail__item.is-current { background-color: var(--color-base-200, #e5e7eb); }
    .pk-timeline-rail--dense .pk-timeline-rail__item.is-current .pk-timeline-rail__label { max-width: 12rem; opacity: 1; }
    @keyframes pk-timeline-flash { 0% { box-shadow: 0 0 0 0 var(--color-primary, #4f46e5); } 30% { box-shadow: 0 0 0 4px var(--color-primary, #4f46e5); } 100% { box-shadow: 0 0 0 0 rgba(0,0,0,0); } }
    .pk-timeline-flash { animation: pk-timeline-flash 1.2s ease-out 1; }
    @media (prefers-reduced-motion: reduce) { .pk-timeline-flash { animation: none; outline: 2px solid var(--color-primary, #4f46e5); } }
    </style>
    <script>
    (function () {
      if (window.__pkTimelineRail) return;
      window.__pkTimelineRail = true;
      var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      function parts(el) {
        var d = el.getAttribute('data-post-date') || '';
        var m = d.match(/(\d{4})-(\d{2})-(\d{2})/) || d.match(/(\d{4})-(\d{2})/) || d.match(/(\d{4})/);
        return m ? { y: m[1], mo: m[2] || null, d: m[3] || null } : null;
      }
      function keyOf(el, gran) {
        var p = parts(el); if (!p) return null;
        if (gran === 'day' && p.d) return p.y + '-' + p.mo + '-' + p.d;
        if ((gran === 'month' || gran === 'day') && p.mo) return p.y + '-' + p.mo;
        return p.y;
      }
      function labelOf(key, gran) {
        var s = key.split('-');
        if (gran === 'day' && s.length === 3) return parseInt(s[2], 10) + ' ' + MONTHS[parseInt(s[1], 10) - 1] + " '" + s[0].slice(2);
        if (s.length >= 2) return MONTHS[parseInt(s[1], 10) - 1] + ' ' + s[0];
        return s[0];
      }
      // "auto": pick the resolution that fits the posts' date span — a wide range
      // reads best by year, a few months by month, a short burst by day.
      function autoGran(cards) {
        var times = [];
        cards.forEach(function (c) {
          var p = parts(c); if (!p) return;
          times.push(new Date(p.y + '-' + (p.mo || '01') + '-' + (p.d || '01') + 'T00:00:00').getTime());
        });
        if (times.length < 2) return 'year';
        var days = (Math.max.apply(null, times) - Math.min.apply(null, times)) / 86400000;
        if (days > 730) return 'year';
        if (days > 90) return 'month';
        return 'day';
      }
      function init() {
        var cfg = document.getElementById('pk-timeline-config');
        var gran = (cfg && cfg.getAttribute('data-granularity')) || 'year';
        try {
          var m = cfg && JSON.parse(cfg.getAttribute('data-months') || 'null');
          if (m && m.length === 12) MONTHS = m;
        } catch (err) {}
        var container = document.querySelector('.group-index-container');
        if (!container) return;
        var cards = Array.prototype.slice.call(container.querySelectorAll('[data-post-date]'));
        if (!cards.length) return;
        if (gran === 'auto') gran = autoGran(cards);
        var keys = [], firstOf = {};
        cards.forEach(function (c) { var k = keyOf(c, gran); if (!k) return; if (!(k in firstOf)) { firstOf[k] = c; keys.push(k); } });
        if (keys.length < 2) return;
        keys.sort(function (a, b) { return a < b ? 1 : (a > b ? -1 : 0); });
        var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        var nav = document.createElement('nav');
        nav.className = 'pk-timeline-rail' + (keys.length > 24 ? ' pk-timeline-rail--dense' : '');
        nav.setAttribute('aria-label', (cfg && cfg.getAttribute('data-label')) || 'Jump to date');
        var items = {};
        keys.forEach(function (k) {
          var c = firstOf[k]; if (!c.id) c.id = 'pk-t-' + k.replace(/[^0-9]/g, '');
          var a = document.createElement('a');
          a.href = '#' + c.id; a.className = 'pk-timeline-rail__item'; a.setAttribute('data-key', k);
          var label = document.createElement('span'); label.className = 'pk-timeline-rail__label'; label.textContent = labelOf(k, gran);
          var tick = document.createElement('span'); tick.className = 'pk-timeline-rail__tick';
          a.appendChild(label); a.appendChild(tick);
          nav.appendChild(a); items[k] = a;
        });
        document.body.appendChild(nav);

        // Position each marker at the vertical fraction where that year's first
        // post actually sits in the document, so the rail tracks the content:
        // empty above the featured band, pressed toward wherever the dated grid
        // is, and shifting up if a footer/comments push the grid higher. A min-gap
        // keeps years that share a grid row from overlapping.
        function position() {
          var docH = document.documentElement.scrollHeight || 1;
          var railH = nav.clientHeight || Math.round(window.innerHeight * 0.88);
          var arr = keys.map(function (k) {
            var c = firstOf[k];
            var mid = c.getBoundingClientRect().top + window.scrollY + c.offsetHeight / 2;
            return { k: k, pos: Math.max(0, Math.min(1, mid / docH)) * railH };
          });
          // Order markers by where their post actually sits on the page, not by
          // the (newest-first) key sort — otherwise an "oldest first" listing,
          // which renders oldest-at-top, feeds descending positions into the
          // min-gap and clamp passes below and stacks every marker together.
          arr.sort(function (a, b) { return a.pos - b.pos; });
          var minGap = nav.classList.contains('pk-timeline-rail--dense') ? 14 : 24;
          for (var i = 1; i < arr.length; i++) {
            if (arr[i].pos < arr[i - 1].pos + minGap) arr[i].pos = arr[i - 1].pos + minGap;
          }
          var over = arr.length ? arr[arr.length - 1].pos - railH : 0;
          if (over > 0) arr.forEach(function (p) { p.pos = Math.max(0, p.pos - over); });
          arr.forEach(function (p) { items[p.k].style.top = p.pos + 'px'; });
        }

        nav.addEventListener('click', function (e) {
          var a = e.target.closest('.pk-timeline-rail__item'); if (!a) return;
          e.preventDefault();
          var k = a.getAttribute('data-key');
          var el = document.getElementById(a.getAttribute('href').slice(1));
          if (el) el.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'start' });
          setTimeout(function () {
            cards.forEach(function (c) {
              if (keyOf(c, gran) === k) {
                c.classList.remove('pk-timeline-flash'); void c.offsetWidth; c.classList.add('pk-timeline-flash');
                setTimeout(function () { c.classList.remove('pk-timeline-flash'); }, 1300);
              }
            });
          }, reduce ? 0 : 400);
        });
        // Highlight the whole range of years whose posts are currently on screen,
        // not just one — so scrolling lights up every visible year at once.
        var visible = {};
        function refresh() {
          var active = {};
          cards.forEach(function (c) { if (visible[c.__pkId]) { var k = keyOf(c, gran); if (k) active[k] = true; } });
          // Current period tracks scroll position: a reference line runs from the
          // top of the viewport (scrolled to top) to the bottom (scrolled to bottom),
          // and the period whose post sits nearest that line is emphasized — so the
          // last date lights up when you reach the very bottom.
          var maxScroll = document.documentElement.scrollHeight - window.innerHeight;
          var pct = maxScroll > 0 ? Math.min(1, Math.max(0, window.scrollY / maxScroll)) : 0;
          var refY = pct * window.innerHeight;
          var current = null, best = Infinity;
          keys.forEach(function (k) {
            var r = firstOf[k].getBoundingClientRect();
            var dist = Math.abs(r.top + r.height / 2 - refY);
            if (dist < best) { best = dist; current = k; }
          });
          keys.forEach(function (k) {
            items[k].classList.toggle('is-active', !!active[k]);
            items[k].classList.toggle('is-current', k === current);
          });
        }
        if ('IntersectionObserver' in window) {
          cards.forEach(function (c, i) { c.__pkId = 'c' + i; });
          var obs = new IntersectionObserver(function (entries) {
            entries.forEach(function (en) { visible[en.target.__pkId] = en.isIntersecting; });
            refresh();
          }, { threshold: 0 });
          cards.forEach(function (c) { obs.observe(c); });
        }

        refresh();
        var pkTick = false;
        window.addEventListener('scroll', function () {
          if (pkTick) return;
          pkTick = true;
          requestAnimationFrame(function () { refresh(); pkTick = false; });
        }, { passive: true });

        position();
        window.addEventListener('resize', function () { position(); refresh(); }, { passive: true });
        window.addEventListener('load', function () { position(); refresh(); });
        setTimeout(function () { position(); refresh(); }, 600);
      }
      if (document.readyState !== 'loading') init();
      else document.addEventListener('DOMContentLoaded', init);
    })();
    </script>
    """
  end

  def index(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      page_title={@page_title}
      current_path={@conn.request_path}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      module_assigns={
        %{
          phoenix_kit_publishing_translations: assigns[:phoenix_kit_publishing_translations],
          og: assigns[:og]
        }
      }
    >
      <.og_meta_tags :if={og_tags_enabled?()} og={assigns[:og]} />
      <%!-- Feed autodiscovery — body placement for the same reason as the OG
        tags (the host owns <head>); feed readers scan the whole document. --%>
      <%!-- On a category/tag archive the advertised feed is the ARCHIVE's
        feed, not the group's — a reader subscribing from /blog/category/x
        expects that category's items. --%>
      <link
        :if={feeds_enabled?() && assigns[:group]}
        rel="alternate"
        type="application/rss+xml"
        title={Publishing.translated_group_name(@group, @current_language)}
        href={
          feed_path(
            @current_language,
            @group["slug"],
            assigns[:term_filter] && {@term_filter.type, @term_filter.value}
          )
        }
      />
      <.scrollbar_style_tag style={(assigns[:group] && @group["scrollbar_style"]) || "default"} />
      <.scroll_timeline
        enabled={(assigns[:group] && @group["scroll_timeline_enabled"]) || false}
        granularity={(assigns[:group] && @group["scroll_timeline_granularity"]) || "auto"}
      />
      <div class="group-index-container max-w-6xl mx-auto px-6 py-8">
        <%!-- Breadcrumb Navigation (gated on the group's show_breadcrumbs setting) --%>
        <%= if (assigns[:group] && @group["show_breadcrumbs"]) do %>
          <div class="breadcrumbs text-sm mb-6">
            <ul>
              <%= for breadcrumb <- @breadcrumbs do %>
                <li>
                  <%= if breadcrumb.url do %>
                    <.link navigate={breadcrumb.url}>{breadcrumb.label}</.link>
                  <% else %>
                    {breadcrumb.label}
                  <% end %>
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>
        <%!-- Group Header --%>
        <header class="mb-8">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h1 class="text-2xl sm:text-4xl font-bold mb-2">
                {Publishing.translated_group_name(@group, @current_language)}
              </h1>
              <p
                :if={assigns[:group] && @group["show_post_count"]}
                class="text-base sm:text-lg text-base-content/70"
              >
                {ngettext("1 post", "%{count} posts", @total_count)}
              </p>
            </div>
            <%!-- Admin Edit Button --%>
            <%= if assigns[:admin_edit_url] do %>
              <a href={@admin_edit_url} class="btn btn-sm btn-outline gap-2">
                <.icon name="hero-pencil-square" class="w-4 h-4" />
                {@admin_edit_label || "Edit"}
              </a>
            <% end %>
          </div>
          <%!-- Language Switcher (gated on `publishing_show_language_switcher` —
            disable when the host renders its own switcher in the layout). --%>
          <%= if assigns[:show_language_switcher] != false and length(@translations) > 1 do %>
            <div class="mt-4">
              <.language_switcher
                languages={build_public_translations(@translations, @current_language)}
                current_language={public_current_language(@translations, @current_language)}
                show_status={false}
                size={:sm}
              />
            </div>
          <% end %>
          <%!-- Search (gated on the group's search_enabled setting). Plain GET
            form — dead views, works without JS; the controller reads ?q=. --%>
          <form
            :if={assigns[:group] && @group["search_enabled"]}
            method="get"
            action={group_listing_path(@current_language, @group["slug"])}
            class="mt-4 flex max-w-md items-center gap-2"
          >
            <label class="input input-sm input-bordered flex flex-1 items-center gap-2">
              <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-50" />
              <input
                type="search"
                name="q"
                value={assigns[:search_query]}
                placeholder={gettext("Search posts…")}
                class="grow"
                maxlength="100"
              />
            </label>
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Search")}</button>
          </form>
        </header>
        <%!-- Search-results heading — the bands are suppressed in search mode,
          matches render in the group's regular listing layout below. --%>
        <div :if={assigns[:search_query]} class="mb-6 flex flex-wrap items-center gap-3">
          <h2 class="text-lg font-semibold">
            {ngettext(
              "%{count} result for “%{query}”",
              "%{count} results for “%{query}”",
              @total_count,
              query: @search_query
            )}
          </h2>
          <.link
            navigate={group_listing_path(@current_language, @group["slug"])}
            class="link text-sm text-base-content/60"
          >
            {gettext("Clear search")}
          </.link>
        </div>
        <%!-- Category/tag archive heading — same shape as the search heading. --%>
        <div :if={assigns[:term_filter]} class="mb-6 flex flex-wrap items-center gap-3">
          <h2 class="text-lg font-semibold">
            <%= if @term_filter.type == :category do %>
              {gettext("Category: %{name}", name: @term_filter.label)}
            <% else %>
              {gettext("Tag: %{name}", name: @term_filter.label)}
            <% end %>
            <span class="ml-1 text-sm font-normal text-base-content/60">
              {ngettext("%{count} post", "%{count} posts", @term_filter.count)}
            </span>
          </h2>
          <.link
            navigate={group_listing_path(@current_language, @group["slug"])}
            class="link text-sm text-base-content/60"
          >
            {gettext("All posts")}
          </.link>
        </div>
        <% featured_posts = assigns[:featured_posts] || [] %>
        <% featured_layout = assigns[:featured_layout] || "hero" %>
        <% featured_style = assigns[:featured_style] || "classic" %>
        <% newest_posts = assigns[:newest_posts] || [] %>
        <% newest_layout = assigns[:newest_layout] || "hero" %>
        <% newest_style = assigns[:newest_style] || "classic" %>
        <% image_links = (assigns[:group] && @group["listing_image_links"]) != false %>
        <% animations = (assigns[:group] && @group["listing_animations"]) != false %>
        <%!-- Prefer the controller's group-wide counts (all pages + pinned
          bands); the visible-set fallback covers direct template renders. --%>
        <% date_counts =
          assigns[:date_counts] || build_date_counts(featured_posts ++ newest_posts ++ @posts) %>
        <%!-- Featured posts — pinned above the grid on page 1, excluded from it. --%>
        <%= if featured_posts != [] do %>
          <section class="mb-10">
            <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-4">
              {gettext("Featured")}
            </h2>
            <div class={
              if featured_layout == "card",
                do: "grid gap-6 md:grid-cols-2",
                else: "flex flex-col gap-6"
            }>
              <.listing_band_card
                :for={post <- featured_posts}
                post={post}
                group_slug={@group["slug"]}
                current_language={@current_language}
                date_counts={date_counts}
                band={:featured}
                layout={featured_layout}
                style={featured_style}
                image_links={image_links}
                animations={animations}
              />
            </div>
          </section>
        <% end %>

        <%!-- Latest post — pinned under the featured band on page 1, excluded
          from the grid (a featured newest post stays in the Featured band). --%>
        <%= if newest_posts != [] do %>
          <section class="mb-10">
            <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-4">
              {gettext("Latest")}
            </h2>
            <div class={
              if newest_layout == "card",
                do: "grid gap-6 md:grid-cols-2",
                else: "flex flex-col gap-6"
            }>
              <.listing_band_card
                :for={post <- newest_posts}
                post={post}
                group_slug={@group["slug"]}
                current_language={@current_language}
                date_counts={date_counts}
                band={:newest}
                layout={newest_layout}
                style={newest_style}
                image_links={image_links}
                animations={animations}
              />
            </div>
          </section>
        <% end %>

        <%!-- Posts — layout per the group's listing_layout setting. The
          Featured/Latest bands above are deliberately unaffected: they carry
          their own layout/style settings. --%>
        <% listing_layout = (assigns[:group] && @group["listing_layout"]) || "grid" %>
        <%= if @posts != [] do %>
          <%= case listing_layout do %>
            <% "minimal" -> %>
              <ul class="divide-y divide-base-200">
                <.listing_post_line
                  :for={post <- @posts}
                  post={post}
                  group_slug={@group["slug"]}
                  current_language={@current_language}
                  date_counts={date_counts}
                  animations={animations}
                />
              </ul>
            <% "list" -> %>
              <div class="flex flex-col gap-4">
                <.listing_post_row
                  :for={post <- @posts}
                  post={post}
                  group_slug={@group["slug"]}
                  current_language={@current_language}
                  date_counts={date_counts}
                  image_links={image_links}
                  animations={animations}
                />
              </div>
            <% _ -> %>
              <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
                <.listing_post_card
                  :for={post <- @posts}
                  post={post}
                  group_slug={@group["slug"]}
                  current_language={@current_language}
                  date_counts={date_counts}
                  variant={:grid}
                  image_links={image_links}
                  animations={animations}
                />
              </div>
          <% end %>
          <%!-- Pagination --%>
          <%= if @total_pages > 1 do %>
            <div class="join mt-8 flex justify-center">
              <%= for page_num <- 1..@total_pages do %>
                <%= if page_num == @page do %>
                  <button class="join-item btn btn-active">{page_num}</button>
                <% else %>
                  <.link
                    navigate={group_listing_path(@current_language, @group["slug"], page: page_num)}
                    class="join-item btn"
                  >
                    {page_num}
                  </.link>
                <% end %>
              <% end %>
            </div>
          <% end %>
        <% end %>

        <%= if @total_count == 0 do %>
          <div class="alert alert-info">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="stroke-current shrink-0 w-6 h-6"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              >
              </path>
            </svg>
            <span>
              <%= if assigns[:search_query] do %>
                {gettext("No posts match your search.")}
              <% else %>
                {gettext("No published posts yet.")}
              <% end %>
            </span>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  @doc "Renders a post's publication date (calendar icon + formatted date)."
  attr :post, :map, required: true
  attr :group_slug, :string, required: true
  attr :class, :any, default: nil

  def post_date(assigns) do
    ~H"""
    <div class={["flex items-center gap-2 text-sm text-base-content/70", @class]}>
      <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
        />
      </svg>
      <time datetime={@post.metadata.published_at || ""}>
        {format_post_date(@post, @group_slug)}
      </time>
    </div>
    """
  end

  # One card for every public-listing variant — the featured band (hero),
  # featured-in-grid (card), their Latest-band twins, and the regular grid
  # share the same article shell; only sizing, badge, accent color, and
  # heading level differ. All variants carry `data-post-date` so the timeline
  # rail sees highlighted posts too.
  attr :post, :map, required: true
  attr :group_slug, :string, required: true
  attr :current_language, :string, required: true
  attr :date_counts, :map, required: true

  attr :variant, :atom,
    required: true,
    values: [:featured_hero, :featured_card, :newest_hero, :newest_card, :grid]

  attr :image_links, :boolean, default: true
  attr :animations, :boolean, default: true

  defp listing_post_card(assigns) do
    highlight? = assigns.variant != :grid
    newest? = assigns.variant in [:newest_hero, :newest_card]

    assigns =
      assigns
      |> assign(:highlight?, highlight?)
      |> assign(:newest?, newest?)
      |> assign(
        :img,
        featured_image_url(assigns.post, if(highlight?, do: "large", else: "medium"))
      )
      |> assign(:excerpt, post_card_excerpt(assigns.post))
      |> assign(
        :post_url,
        build_post_url(
          assigns.group_slug,
          assigns.post,
          assigns.current_language,
          assigns.date_counts
        )
      )

    ~H"""
    <article
      class={[
        "card bg-base-200",
        @animations && "transition motion-safe:hover:-translate-y-1",
        @highlight? && "shadow-lg ring-1 overflow-hidden",
        @animations && @highlight? && "hover:shadow-xl",
        @highlight? && ((@newest? && "ring-secondary/20") || "ring-primary/20"),
        !@highlight? && "shadow-md",
        @animations && !@highlight? && "hover:shadow-lg",
        @variant in [:featured_hero, :newest_hero] && "lg:card-side"
      ]}
      data-post-date={effective_post_date(@post)}
    >
      <%= if @img do %>
        <figure class={card_figure_class(@variant)}>
          <%= if @image_links do %>
            <%!-- aria-hidden + tabindex=-1: the title link right below is the
              accessible route to the same destination — screen readers and the
              tab order shouldn't hit it twice. --%>
            <.link navigate={@post_url} class="block h-full w-full" tabindex="-1" aria-hidden="true">
              <img
                src={@img}
                alt={@post.metadata.title || gettext("Featured image")}
                class={[
                  "h-full w-full object-cover",
                  @animations && "transition-opacity hover:opacity-90"
                ]}
                loading="lazy"
              />
            </.link>
          <% else %>
            <img
              src={@img}
              alt={@post.metadata.title || gettext("Featured image")}
              class="h-full w-full object-cover"
              loading="lazy"
            />
          <% end %>
        </figure>
      <% end %>
      <div class="card-body">
        <span :if={@highlight? and not @newest?} class="badge badge-primary badge-sm w-fit gap-1">
          ★ {gettext("Featured")}
        </span>
        <span :if={@newest?} class="badge badge-secondary badge-sm w-fit gap-1">
          ✦ {gettext("Latest")}
        </span>
        <h3 :if={@highlight?} class="card-title text-2xl">
          <.link navigate={@post_url} class="hover:text-primary">{@post.metadata.title}</.link>
        </h3>
        <h2 :if={!@highlight?} class="card-title text-xl">
          <.link navigate={@post_url} class="hover:text-primary">{@post.metadata.title}</.link>
        </h2>

        <%= if @excerpt && @excerpt != "" do %>
          <p class={[
            "text-base-content/70 line-clamp-3",
            (@highlight? && "text-base") || "text-sm"
          ]}>
            {@excerpt}
          </p>
        <% end %>

        <%!-- mt-auto (not a content-following margin) pins the date + button
          row to the card bottom, so cards whose content differs in height
          still line their buttons up across a grid row. --%>
        <div class="card-actions justify-between items-center mt-auto pt-4">
          <%= if has_publication_date?(@post) do %>
            <time class="text-xs text-base-content/60" datetime={@post.metadata.published_at || ""}>
              {format_post_date(@post, @group_slug, @date_counts)}
            </time>
          <% else %>
            <span class="text-xs text-base-content/60"></span>
          <% end %>

          <.link navigate={@post_url} class="btn btn-sm btn-primary">
            {gettext("Read More →")}
          </.link>
        </div>
      </div>
    </article>
    """
  end

  defp card_figure_class(:grid), do: "h-40 w-full overflow-hidden rounded-t-2xl bg-base-300"

  defp card_figure_class(variant) when variant in [:featured_card, :newest_card],
    do: "h-52 w-full overflow-hidden bg-base-300"

  defp card_figure_class(variant) when variant in [:featured_hero, :newest_hero],
    do: "lg:w-2/5 h-56 lg:h-auto overflow-hidden bg-base-300"

  # ---------------------------------------------------------------------------
  # Minimal listing line — the "minimal" listing_layout: one date — title row
  # per post, no image, no excerpt, no button. The whole row links to the post.
  # The fixed-width date cell keeps titles left-aligned down the list; it
  # renders (empty) even for date-less posts for the same reason.
  # ---------------------------------------------------------------------------
  attr :post, :map, required: true
  attr :group_slug, :string, required: true
  attr :current_language, :string, required: true
  attr :date_counts, :map, required: true
  attr :animations, :boolean, default: true

  defp listing_post_line(assigns) do
    assigns =
      assign(
        assigns,
        :post_url,
        build_post_url(
          assigns.group_slug,
          assigns.post,
          assigns.current_language,
          assigns.date_counts
        )
      )

    ~H"""
    <li data-post-date={effective_post_date(@post)}>
      <.link
        navigate={@post_url}
        class={[
          "group -mx-2 flex flex-wrap items-baseline gap-x-4 gap-y-0.5 rounded-lg px-2 py-3 sm:flex-nowrap",
          @animations && "transition-colors hover:bg-base-200/60"
        ]}
      >
        <%!-- w-44 fits the full "%B %d, %Y" dates format_post_date/3 emits
          ("September 15, 2024"); the ellipsis guards the rare same-day
          "… at HH:MM" suffix instead of letting it overlap the title. --%>
        <time
          class="w-44 shrink-0 overflow-hidden text-ellipsis whitespace-nowrap text-sm tabular-nums text-base-content/60"
          datetime={@post.metadata.published_at || ""}
        >
          {if has_publication_date?(@post), do: format_post_date(@post, @group_slug, @date_counts)}
        </time>
        <h2 class="min-w-0 text-base font-medium group-hover:text-primary">
          {@post.metadata.title}
        </h2>
      </.link>
    </li>
    """
  end

  # ---------------------------------------------------------------------------
  # List row — the "list" listing_layout: a horizontal card per post with a
  # left thumbnail (when the post has one), title + excerpt, and the shared
  # bottom-pinned date/Read-More footer.
  # ---------------------------------------------------------------------------
  attr :post, :map, required: true
  attr :group_slug, :string, required: true
  attr :current_language, :string, required: true
  attr :date_counts, :map, required: true
  attr :image_links, :boolean, default: true
  attr :animations, :boolean, default: true

  defp listing_post_row(assigns) do
    assigns =
      assigns
      |> assign(:img, featured_image_url(assigns.post, "medium"))
      |> assign(:excerpt, post_card_excerpt(assigns.post))
      |> assign(
        :post_url,
        build_post_url(
          assigns.group_slug,
          assigns.post,
          assigns.current_language,
          assigns.date_counts
        )
      )

    ~H"""
    <article
      class={[
        "card sm:card-side bg-base-200 shadow-md",
        @animations && "transition hover:shadow-lg motion-safe:hover:-translate-y-0.5"
      ]}
      data-post-date={effective_post_date(@post)}
    >
      <%= if @img do %>
        <figure class="h-40 w-full shrink-0 overflow-hidden bg-base-300 sm:h-auto sm:w-48">
          <%= if @image_links do %>
            <.link navigate={@post_url} class="block h-full w-full" tabindex="-1" aria-hidden="true">
              <img
                src={@img}
                alt={@post.metadata.title || gettext("Featured image")}
                class={[
                  "h-full w-full object-cover",
                  @animations && "transition-opacity hover:opacity-90"
                ]}
                loading="lazy"
              />
            </.link>
          <% else %>
            <img
              src={@img}
              alt={@post.metadata.title || gettext("Featured image")}
              class="h-full w-full object-cover"
              loading="lazy"
            />
          <% end %>
        </figure>
      <% end %>
      <div class="card-body p-5">
        <h2 class="card-title text-lg">
          <.link navigate={@post_url} class="hover:text-primary">{@post.metadata.title}</.link>
        </h2>
        <p :if={@excerpt && @excerpt != ""} class="line-clamp-2 text-sm text-base-content/70">
          {@excerpt}
        </p>
        <div class="card-actions mt-auto items-center justify-between pt-2">
          <%= if has_publication_date?(@post) do %>
            <time class="text-xs text-base-content/60" datetime={@post.metadata.published_at || ""}>
              {format_post_date(@post, @group_slug, @date_counts)}
            </time>
          <% else %>
            <span class="text-xs text-base-content/60"></span>
          <% end %>
          <.link navigate={@post_url} class="btn btn-sm btn-primary">
            {gettext("Read More →")}
          </.link>
        </div>
      </div>
    </article>
    """
  end

  # ---------------------------------------------------------------------------
  # Band cards — the Featured/Latest bands' style-aware wrapper.
  #
  # `layout` stays size/placement (hero band vs card in a 2-col grid); `style`
  # owns the paint. "classic" (and any unknown value — defensive, the write
  # path whitelists) delegates to the original listing_post_card variants so
  # pre-styles groups render pixel-identical.
  # ---------------------------------------------------------------------------
  attr :post, :map, required: true
  attr :group_slug, :string, required: true
  attr :current_language, :string, required: true
  attr :date_counts, :map, required: true
  attr :band, :atom, required: true, values: [:featured, :newest]
  attr :layout, :string, required: true
  attr :style, :string, required: true
  attr :image_links, :boolean, default: true
  attr :animations, :boolean, default: true

  defp listing_band_card(%{style: style} = assigns)
       when style in ["cover", "cover_panel", "minimal", "top"] do
    assigns =
      assigns
      |> assign(:img, featured_image_url(assigns.post, "large"))
      |> assign(:excerpt, post_card_excerpt(assigns.post))
      |> assign(
        :post_url,
        build_post_url(
          assigns.group_slug,
          assigns.post,
          assigns.current_language,
          assigns.date_counts
        )
      )

    case assigns.style do
      "cover" -> band_cover(assigns)
      "cover_panel" -> band_cover_panel(assigns)
      "minimal" -> band_minimal(assigns)
      "top" -> band_top(assigns)
    end
  end

  defp listing_band_card(assigns) do
    assigns =
      assign(
        assigns,
        :variant,
        case {assigns.band, assigns.layout} do
          {:featured, "card"} -> :featured_card
          {:featured, _} -> :featured_hero
          {:newest, "card"} -> :newest_card
          {:newest, _} -> :newest_hero
        end
      )

    ~H"""
    <.listing_post_card
      post={@post}
      group_slug={@group_slug}
      current_language={@current_language}
      date_counts={@date_counts}
      variant={@variant}
      image_links={@image_links}
      animations={@animations}
    />
    """
  end

  # The full-bleed decorative image layer, the (optional) contrast scrim, and
  # the stretched click-through link shared by band_cover and
  # band_cover_panel. Rendered as ONE block so the stacking order can't drift:
  # img UNDER scrim UNDER link (positioned siblings stack by DOM order — the
  # link must sit above the scrim to receive background clicks, and the z-10
  # text strip above them all still wins on its own links).
  # aria-hidden/tabindex=-1 on the link: the title link is the accessible route.
  attr :img, :string, default: nil
  attr :post_url, :string, required: true
  attr :image_links, :boolean, required: true
  attr :scrim, :boolean, required: true

  defp band_cover_media(assigns) do
    ~H"""
    <img
      :if={@img}
      src={@img}
      alt=""
      aria-hidden="true"
      loading="lazy"
      class="absolute inset-0 h-full w-full object-cover"
    />
    <div
      :if={@scrim}
      aria-hidden="true"
      class="absolute inset-0 bg-gradient-to-t from-black/80 via-black/40 to-black/10"
    >
    </div>
    <.link
      :if={@image_links}
      navigate={@post_url}
      class="pk-band-cover-link absolute inset-0"
      tabindex="-1"
      aria-hidden="true"
    >
    </.link>
    """
  end

  # Per-band accent ring + per-layout band height — shared by the image-backed
  # band styles so the stanzas can't drift apart.
  defp band_ring_class(:featured), do: "ring-primary/20"
  defp band_ring_class(:newest), do: "ring-secondary/20"

  defp band_minh_class("card"), do: "min-h-64"
  defp band_minh_class(_hero), do: "min-h-80 lg:min-h-96"

  # Cover — the featured image fills the card; text overlaid in the dark zone
  # of a hardcoded bottom-heavy scrim (the accessibility guarantee — never an
  # option). No image degrades to a branded gradient banner, scrim on top, so
  # the fixed light text keeps contrast either way. A real <img> (not a CSS
  # background) so the browser can lazy-load it.
  defp band_cover(assigns) do
    ~H"""
    <article
      class={[
        "relative flex items-end overflow-hidden rounded-2xl shadow-lg ring-1",
        @animations && "transition hover:shadow-xl motion-safe:hover:-translate-y-1",
        band_ring_class(@band),
        band_minh_class(@layout)
      ]}
      data-post-date={effective_post_date(@post)}
    >
      <div
        :if={!@img}
        aria-hidden="true"
        class={[
          "absolute inset-0",
          (@band == :featured && "bg-gradient-to-br from-primary to-secondary") ||
            "bg-gradient-to-br from-secondary to-primary"
        ]}
      >
      </div>
      <.band_cover_media img={@img} post_url={@post_url} image_links={@image_links} scrim={true} />
      <%!-- pointer-events-none + auto on the links: empty space in the text
        strip falls through to the stretched link, so the WHOLE band is
        clickable, while the title/Read More links still win on their own
        pixels. --%>
      <div class={[
        "relative z-10 flex w-full flex-col gap-2 p-6 lg:p-8 text-white",
        @image_links && "pointer-events-none"
      ]}>
        <.band_badge band={@band} />
        <h3 class={["font-bold", (@layout == "card" && "text-2xl") || "text-2xl lg:text-3xl"]}>
          <.link
            navigate={@post_url}
            class="pointer-events-auto text-white hover:text-white/80 focus-visible:outline-white"
          >
            {@post.metadata.title}
          </.link>
        </h3>
        <p :if={@excerpt && @excerpt != ""} class="line-clamp-2 max-w-3xl text-white/80">
          {@excerpt}
        </p>
        <div class="mt-2 flex items-center justify-between gap-4">
          <%= if has_publication_date?(@post) do %>
            <time class="text-xs text-white/70" datetime={@post.metadata.published_at || ""}>
              {format_post_date(@post, @group_slug, @date_counts)}
            </time>
          <% else %>
            <span></span>
          <% end %>
          <.link navigate={@post_url} class="pointer-events-auto btn btn-sm btn-primary">
            {gettext("Read More →")}
          </.link>
        </div>
      </div>
    </article>
    """
  end

  # Cover panel — full-bleed image with an opaque theme panel for the text:
  # the a11y-safe cover (contrast comes from the panel, not a scrim, so any
  # uploaded photo works). No image reads as a normal panel on bg-base-200.
  defp band_cover_panel(assigns) do
    ~H"""
    <article
      class={[
        "relative flex items-end overflow-hidden rounded-2xl bg-base-200 shadow-lg ring-1",
        @animations && "transition hover:shadow-xl motion-safe:hover:-translate-y-1",
        band_ring_class(@band),
        band_minh_class(@layout)
      ]}
      data-post-date={effective_post_date(@post)}
    >
      <%!-- No scrim — this style's contrast comes from the opaque panel. --%>
      <.band_cover_media img={@img} post_url={@post_url} image_links={@image_links} scrim={false} />
      <%!-- Wrapper falls through to the stretched link; the opaque panel
        itself keeps normal pointer behavior. --%>
      <div class={["relative z-10 w-full p-5 lg:p-8", @image_links && "pointer-events-none"]}>
        <div class="pointer-events-auto flex max-w-xl flex-col gap-2 rounded-2xl bg-base-100/95 p-6 shadow-xl">
          <.band_badge band={@band} />
          <h3 class="text-2xl font-bold">
            <.link navigate={@post_url} class="hover:text-primary">{@post.metadata.title}</.link>
          </h3>
          <p :if={@excerpt && @excerpt != ""} class="line-clamp-2 text-base-content/70">
            {@excerpt}
          </p>
          <.band_card_footer post={@post} group_slug={@group_slug} date_counts={@date_counts} post_url={@post_url} />
        </div>
      </div>
    </article>
    """
  end

  # Minimal — typography-first editorial band; the image is deliberately
  # ignored, so it doubles as the canonical no-image look.
  defp band_minimal(assigns) do
    ~H"""
    <article
      class={[
        "rounded-e-2xl border-s-4 bg-base-100 shadow-sm",
        @animations && "transition hover:shadow-md motion-safe:hover:-translate-y-1",
        (@band == :featured && "border-primary") || "border-secondary",
        (@layout == "card" && "px-5 py-6") || "px-6 py-8 lg:px-10"
      ]}
      data-post-date={effective_post_date(@post)}
    >
      <%!-- h-full so the footer's mt-auto can pin to the bottom when this
        card is grid-stretched next to a taller sibling. --%>
      <div class="flex h-full flex-col gap-2">
        <.band_badge band={@band} />
        <h3 class="text-2xl font-bold tracking-tight lg:text-3xl">
          <.link navigate={@post_url} class="hover:text-primary">{@post.metadata.title}</.link>
        </h3>
        <p :if={@excerpt && @excerpt != ""} class="line-clamp-3 max-w-2xl text-base-content/70">
          {@excerpt}
        </p>
        <.band_card_footer post={@post} group_slug={@group_slug} date_counts={@date_counts} post_url={@post_url} />
      </div>
    </article>
    """
  end

  # Top — a wide 16:9 image banner stacked above the text, even at hero
  # width. The one style that gets native lazy-loading for free; no image
  # simply drops the banner.
  defp band_top(assigns) do
    ~H"""
    <article
      class={[
        "card overflow-hidden bg-base-200 shadow-lg ring-1",
        @animations && "transition hover:shadow-xl motion-safe:hover:-translate-y-1",
        band_ring_class(@band)
      ]}
      data-post-date={effective_post_date(@post)}
    >
      <figure :if={@img} class="aspect-video w-full overflow-hidden bg-base-300">
        <%= if @image_links do %>
          <.link navigate={@post_url} class="block h-full w-full" tabindex="-1" aria-hidden="true">
            <img
              src={@img}
              alt={@post.metadata.title || gettext("Featured image")}
              class={[
                "h-full w-full object-cover",
                @animations && "transition-opacity hover:opacity-90"
              ]}
              loading="lazy"
            />
          </.link>
        <% else %>
          <img
            src={@img}
            alt={@post.metadata.title || gettext("Featured image")}
            class="h-full w-full object-cover"
            loading="lazy"
          />
        <% end %>
      </figure>
      <div class="card-body">
        <.band_badge band={@band} />
        <h3 class="card-title text-2xl">
          <.link navigate={@post_url} class="hover:text-primary">{@post.metadata.title}</.link>
        </h3>
        <p :if={@excerpt && @excerpt != ""} class="text-base line-clamp-3 text-base-content/70">
          {@excerpt}
        </p>
        <.band_card_footer post={@post} group_slug={@group_slug} date_counts={@date_counts} post_url={@post_url} />
      </div>
    </article>
    """
  end

  attr :band, :atom, required: true, values: [:featured, :newest]

  defp band_badge(assigns) do
    ~H"""
    <span :if={@band == :featured} class="badge badge-primary badge-sm w-fit gap-1">
      ★ {gettext("Featured")}
    </span>
    <span :if={@band == :newest} class="badge badge-secondary badge-sm w-fit gap-1">
      ✦ {gettext("Latest")}
    </span>
    """
  end

  # Date + Read More row shared by the theme-surface band styles (cover has
  # its own light-text variant inline).
  attr :post, :map, required: true
  attr :group_slug, :string, required: true
  attr :date_counts, :map, required: true
  attr :post_url, :string, required: true

  defp band_card_footer(assigns) do
    ~H"""
    <div class="mt-auto flex items-center justify-between gap-4 pt-2">
      <%= if has_publication_date?(@post) do %>
        <time class="text-xs text-base-content/60" datetime={@post.metadata.published_at || ""}>
          {format_post_date(@post, @group_slug, @date_counts)}
        </time>
      <% else %>
        <span class="text-xs text-base-content/60"></span>
      <% end %>
      <.link navigate={@post_url} class="btn btn-sm btn-primary">
        {gettext("Read More →")}
      </.link>
    </div>
    """
  end

  # Comment author display: full name, else the email's local part.
  defp comment_author_name(%{user: %{} = user}) do
    name =
      [Map.get(user, :first_name), Map.get(user, :last_name)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    cond do
      name != "" -> name
      is_binary(Map.get(user, :email)) -> user.email |> String.split("@") |> List.first()
      true -> gettext("Reader")
    end
  end

  defp comment_author_name(_), do: gettext("Reader")

  defp can_comment?(assigns) do
    match?(%{user: %{}}, assigns[:phoenix_kit_current_scope])
  end

  # Progressive enhancement for every comment form on the page (main
  # thread, replies, note panels): with JS, the POST goes over fetch and
  # the #comments / #pk-note-panels sections are re-fetched and swapped in
  # place — no page reload, scroll and the open panel (:target) survive.
  # Without JS (or on any fetch failure) the plain form POST still works.
  # Same inline-script pattern as reading_progress/1 on these dead views.
  defp comment_fetch_assets do
    """
    <script>
    (function () {
      if (window.__pkCommentFetch) return;
      window.__pkCommentFetch = true;
      function showError(form, message) {
        var note = form.querySelector('[data-pk-comment-error]');
        if (!note) {
          note = document.createElement('p');
          note.setAttribute('data-pk-comment-error', '');
          note.className = 'text-error text-xs';
          form.insertBefore(note, form.querySelector('textarea'));
        }
        note.textContent = message || 'Something went wrong — please try again.';
      }
      // Success path AFTER the server stored the comment: re-fetch the page
      // and swap the thread sections. MUST NOT fall back to form.submit()
      // from here — the POST already succeeded, a resubmit would duplicate
      // the comment. Any failure downgrades to a plain reload (a GET).
      function refreshSections() {
        return fetch(window.location.pathname + window.location.search, {
          credentials: 'same-origin'
        })
          .then(function (resp) {
            if (!resp.ok) throw new Error('refetch failed');
            return resp.text();
          })
          .then(function (html) {
            var doc = new DOMParser().parseFromString(html, 'text/html');
            var stale = false;
            ['comments', 'pk-note-panels'].forEach(function (id) {
              var cur = document.getElementById(id);
              var next = doc.getElementById(id);
              if (cur && next) cur.replaceWith(next);
              else if (cur && !next) stale = true;
            });
            if (stale) throw new Error('sections vanished');
            // Swapping the :target node drops the :target CSS match in
            // browsers — re-open the hash's panel by class.
            var hash = window.location.hash.slice(1);
            var target = hash && document.getElementById(hash);
            if (target && target.classList.contains('pk-note-panel')) {
              target.classList.add('pk-open');
            }
          })
          .catch(function () { window.location.reload(); });
      }
      // Real fragment navigation (opening another panel, the ✕/backdrop
      // close links) hands control back to :target — clear the class.
      window.addEventListener('hashchange', function () {
        document.querySelectorAll('.pk-note-panel.pk-open').forEach(function (el) {
          el.classList.remove('pk-open');
        });
      });
      document.addEventListener('submit', function (e) {
        var form = e.target;
        if (!form.matches || !form.matches('form[data-pk-comment-form]')) return;
        if (!window.fetch || !window.DOMParser || form.dataset.pkNative) return;
        e.preventDefault();
        var btn = form.querySelector('button[type=submit], input[type=submit]');
        if (btn) btn.disabled = true;
        fetch(form.action, {
          method: 'POST',
          body: new FormData(form),
          headers: { 'x-pk-comment-fetch': '1' },
          credentials: 'same-origin'
        })
          .then(function (resp) { return resp.json(); })
          .then(function (data) { return data; }, function () { return null; })
          .then(function (data) {
            if (data === null) {
              // The POST failed, or its response wasn't JSON (proxy error,
              // auth redirect, dropped connection). We CANNOT tell whether
              // the server stored the comment, so we must not resubmit —
              // a lost success response would post it twice. Reload instead:
              // the reader sees the real state and can retype if needed.
              window.location.reload();
              return;
            }
            if (!data.ok) {
              showError(form, data.message);
              if (btn) btn.disabled = false;
              return;
            }
            return refreshSections();
          });
      });
    })();
    </script>
    """
  end

  # One comment in the thread, recursively rendering its replies. The reply
  # form hides behind <details> — open/close works with no JS, several can
  # be open at once, and nothing scroll-jumps.
  defp comment_node(assigns) do
    assigns = Map.put_new(assigns, :note_id, nil)

    ~H"""
    <li id={"comment-#{@comment.uuid}"}>
      <div class="flex items-baseline gap-2 text-sm">
        <span class="font-semibold">{comment_author_name(@comment)}</span>
        <time class="text-xs text-base-content/50" datetime={DateTime.to_iso8601(@comment.inserted_at)}>
          {Calendar.strftime(@comment.inserted_at, "%Y-%m-%d %H:%M")}
        </time>
      </div>
      <div class="mt-1 text-sm">
        {Publishing.Comments.render_content(@comment.content)}
      </div>
      <details :if={@can_comment} class="mt-1">
        <summary class="cursor-pointer select-none text-xs text-base-content/50 hover:text-primary">
          {gettext("Reply")}
        </summary>
        <div class="mt-2">
          <%!-- note_id rides along for ANCHORING only: on a validation error
                the controller redirects back, and without it the fragment
                points at a comment inside a closed panel, bouncing a no-JS
                reader out of the panel they were typing in. Threading still
                comes from the parent alone (the seam ignores a client
                note_id on replies). --%>
          <.comment_form
            action={@form_action}
            post_uuid={@post_uuid}
            token={@form_token}
            parent_uuid={@comment.uuid}
            note_id={@note_id}
            compact={true}
            placeholder={gettext("Write a reply…")}
            submit_label={gettext("Post reply")}
          />
        </div>
      </details>
      <ol
        :if={@comment.children != []}
        class="mt-4 space-y-4 border-l-2 border-base-200 pl-4 sm:pl-5"
      >
        <.comment_node
          :for={child <- @comment.children}
          comment={child}
          form_action={@form_action}
          post_uuid={@post_uuid}
          form_token={@form_token}
          can_comment={@can_comment}
          note_id={@note_id}
        />
      </ol>
    </li>
    """
  end

  # The POST comment form — shared by the top-level thread, per-comment
  # reply <details>, and the note panels. Same protections everywhere:
  # CSRF, honeypot, signed time-trap token; parent_uuid/note_id thread it.
  defp comment_form(assigns) do
    assigns =
      assigns
      |> Map.put_new(:parent_uuid, nil)
      |> Map.put_new(:note_id, nil)
      |> Map.put_new(:compact, false)
      |> Map.put_new(:placeholder, gettext("Write a comment… (Markdown supported)"))
      |> Map.put_new(:submit_label, gettext("Post comment"))

    ~H"""
    <form method="post" action={@action} data-pk-comment-form class="space-y-2">
      <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
      <input type="hidden" name="post_uuid" value={@post_uuid} />
      <input type="hidden" name="ft" value={@token} />
      <input :if={@parent_uuid} type="hidden" name="parent_uuid" value={@parent_uuid} />
      <input :if={@note_id} type="hidden" name="note_id" value={@note_id} />
      <%!-- Honeypot — visually hidden; anything typed here is a bot. --%>
      <div class="hidden" aria-hidden="true">
        <label>
          Website <input type="text" name="website" tabindex="-1" autocomplete="off" />
        </label>
      </div>
      <textarea
        name="content"
        rows={if @compact, do: "2", else: "4"}
        required
        maxlength="10000"
        placeholder={@placeholder}
        class="textarea textarea-bordered w-full"
      ></textarea>
      <button type="submit" class={["btn btn-primary", if(@compact, do: "btn-xs", else: "btn-sm")]}>
        {@submit_label}
      </button>
    </form>
    """
  end

  @doc """
  The right-side slide-out panels for "panel" notes style. CSS-only:
  hidden off-canvas until the panel is the URL :target (the note ref in
  the body links to it); the backdrop and ✕ link back to the ref, which
  both closes the panel and returns the reader to the annotated phrase.
  Public so the editor preview can render the same panels (with
  commenting off) — preview must match production.
  """
  def note_panels(assigns) do
    ~H"""
    <section id="pk-note-panels" aria-label={gettext("Author notes")}>
      <%!-- Closing a note used to point back at its reference marker in the
        prose, on the reasoning that it returns you to what you were reading.
        But opening a panel scrolls nothing — the panel is fixed — so you were
        never taken away, and the "return" was a 440px jump to wherever the
        browser chose to align that marker.

        Closing instead targets this: fixed, one pixel, always inside the
        viewport. `:target` moves off the panel so it shuts, and there is
        nothing to scroll into view because it is already there. --%>
      <span id="pk-note-dismiss" class="pk-note-dismiss" aria-hidden="true"></span>
      <div :for={note <- @post_notes} id={"pk-note-panel-#{note.id}"} class="pk-note-panel">
        <a href="#pk-note-dismiss" class="pk-note-panel-backdrop" aria-label={gettext("Close note")}>
        </a>
        <aside
          role="dialog"
          aria-label={gettext("Note %{number}", number: note.number)}
          tabindex="-1"
          class="bg-base-100 shadow-2xl border-l border-base-200"
        >
          <header class="flex items-center justify-between gap-2 border-b border-base-200 px-4 py-3">
            <span class="text-sm font-semibold">
              <span class="badge badge-primary badge-sm align-middle">{note.number}</span>
              {gettext("Note")}
            </span>
            <a
              href="#pk-note-dismiss"
              class="btn btn-ghost btn-xs btn-circle"
              aria-label={gettext("Close note")}
            >
              ✕
            </a>
          </header>
          <div class="px-4 py-3 text-sm leading-relaxed">{note.body}</div>
          <div :if={@comments_enabled} class="border-t border-base-200 px-4 py-3">
            <h3 class="mb-3 text-xs font-semibold uppercase tracking-wider text-base-content/50">
              {ngettext(
                "%{count} comment on this note",
                "%{count} comments on this note",
                Publishing.Comments.tree_size(Map.get(@note_comments, note.id, []))
              )}
            </h3>
            <ol class="mb-4 space-y-4">
              <.comment_node
                :for={comment <- Map.get(@note_comments, note.id, [])}
                comment={comment}
                form_action={@form_action <> "#pk-note-panel-#{note.id}"}
                post_uuid={@post_uuid}
                form_token={@form_token}
                can_comment={@can_comment}
                note_id={note.id}
              />
            </ol>
            <%= if @can_comment do %>
              <.comment_form
                action={@form_action <> "#pk-note-panel-#{note.id}"}
                post_uuid={@post_uuid}
                token={@form_token}
                note_id={note.id}
                compact={true}
                placeholder={gettext("Comment on this note…")}
              />
            <% else %>
              <div class="text-xs text-base-content/60">
                <.link navigate={PhoenixKit.Utils.Routes.path("/users/log-in")} class="link">
                  {gettext("Log in")}
                </.link>
                {gettext("to comment on this note.")}
              </div>
            <% end %>
          </div>
        </aside>
      </div>
    </section>
    <style>
      /* .pk-open mirrors :target — replacing a :target node in the DOM
         (the fetch enhancement's section swap) makes browsers drop the
         :target match, so the script re-opens the hash's panel by class. */
      .pk-note-dismiss{position:fixed;top:0;left:0;width:1px;height:1px;pointer-events:none}
    .pk-note-panel{position:fixed;inset:0;z-index:60;visibility:hidden;pointer-events:none}
      .pk-note-panel:target,.pk-note-panel.pk-open{visibility:visible;pointer-events:auto}
      .pk-note-panel-backdrop{position:absolute;inset:0;background:rgb(0 0 0/.25);opacity:0;transition:opacity .2s ease}
      .pk-note-panel:target .pk-note-panel-backdrop,.pk-note-panel.pk-open .pk-note-panel-backdrop{opacity:1}
      .pk-note-panel aside{position:absolute;top:0;right:0;bottom:0;width:min(26rem,92vw);overflow-y:auto;transform:translateX(100%);transition:transform .25s ease}
      .pk-note-panel:target aside,.pk-note-panel.pk-open aside{transform:none}
      @media (prefers-reduced-motion: reduce){
        .pk-note-panel-backdrop,.pk-note-panel aside{transition:none}
      }
    </style>
    """
  end

  # The preview always derives from the per-language content that
  # Controller.Listing's resolve step put in :content (content.data excerpt/
  # description where a legacy row still carries one, else the first paragraph
  # or the part before <!-- more -->). The version-level data["description"]
  # is deliberately NOT consulted: it has no editor UI and carries no language
  # (legacy V1 promotion / API writes fill it), so on multi-language groups it
  # showed one language's text under every language's title. Its remaining
  # job is the LAST-RESORT og:description default on post pages
  # (build_og_data/4 — per-language override and derived excerpt both outrank
  # it there too).
  defp post_card_excerpt(post) do
    extract_excerpt(post.content)
  end

  # The date the timeline rail bins a card under — MUST match the effective
  # publish date the listing sorts by (Listing.listing_sort_key/1): the
  # post_date for timestamp-mode posts (metadata.published_at is the version's
  # publish timestamp and can differ from the URL date), the version's
  # published_at for slug-mode posts. Nil (attribute omitted) when the post has
  # neither, so the rail skips the card.
  defp effective_post_date(post) do
    cond do
      match?(%Date{}, post[:date]) ->
        Date.to_iso8601(post.date)

      is_binary(get_in(post, [:metadata, :published_at])) and post.metadata.published_at != "" ->
        post.metadata.published_at

      true ->
        nil
    end
  end

  def show(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      page_title={@page_title}
      current_path={@conn.request_path}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      module_assigns={
        %{
          phoenix_kit_publishing_translations: assigns[:phoenix_kit_publishing_translations],
          og: assigns[:og]
        }
      }
    >
      <.og_meta_tags :if={og_tags_enabled?()} og={assigns[:og]} />
      <.jsonld_script
        :if={jsonld_enabled?()}
        og={assigns[:og]}
        post={@post}
        language={@current_language}
      />
      <.scrollbar_style_tag style={assigns[:scrollbar_style] || "default"} />
      <.reading_progress enabled={assigns[:scroll_progress_enabled] || false} />
      <.reading_headings enabled={assigns[:scroll_headings_enabled] || false} />
      <.helix_scroll_fallback />
      <article class={["post-container mx-auto px-6 py-8", post_width_class(assigns[:post_width])]}>
        <%!-- Top back link (gated on the group's show_top_back_link setting,
          default on) — a compact muted twin of the footer link, hugging the
          title so it doesn't cost the page a band of empty space. --%>
        <nav :if={assigns[:show_top_back_link] != false} class="mb-1">
          <%!-- Visible text is just the group name (boss call) — the arrow
            carries the "back" meaning visually; aria-label keeps it explicit
            for screen readers. --%>
          <.link
            navigate={group_listing_path(@current_language, @group_slug)}
            class="inline-flex items-center gap-1 text-xs text-base-content/50 hover:text-primary transition-colors"
            aria-label={gettext("Back to %{group}", group: @group_name)}
          >
            <.icon name="hero-arrow-left" class="w-3 h-3" /> {@group_name}
          </.link>
        </nav>
        <%!-- Breadcrumb Navigation (gated on the group's show_breadcrumbs setting) --%>
        <%= if assigns[:show_breadcrumbs] do %>
          <div class="breadcrumbs text-sm mb-6">
            <ul>
              <%= for breadcrumb <- @breadcrumbs do %>
                <li>
                  <%= if breadcrumb.url do %>
                    <.link navigate={breadcrumb.url}>{breadcrumb.label}</.link>
                  <% else %>
                    {breadcrumb.label}
                  <% end %>
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <%!-- Featured image (gated on the group's show_featured_image setting) --%>
        <%= if assigns[:show_featured_image] do %>
          <% hero_url = featured_image_url(@post, "large") %>
          <figure :if={hero_url} class="mb-8 overflow-hidden rounded-xl bg-base-200">
            <img
              src={hero_url}
              alt={@post.metadata.title || ""}
              class="w-full h-auto max-h-[28rem] object-cover"
              loading="lazy"
            />
          </figure>
        <% end %>

        <%!-- Post Header --%>
        <header class="mb-8 border-b pb-6">
          <.post_date
            :if={
              has_publication_date?(@post) and (assigns[:post_date_position] || "below") == "above"
            }
            post={@post}
            group_slug={@group_slug}
            class="mb-3"
          />
          <h1 class="text-3xl font-bold">
            {@post.metadata.title || PhoenixKit.Modules.Publishing.Constants.default_title()}
          </h1>
          <.post_date
            :if={
              has_publication_date?(@post) and (assigns[:post_date_position] || "below") == "below"
            }
            post={@post}
            group_slug={@group_slug}
            class="mt-3"
          />
          <div :if={assigns[:show_reading_time]} class="text-sm text-base-content/60 mt-2">
            {reading_time_label(@html_content)}
          </div>
          <div :if={(assigns[:view_count] || 0) > 0} class="text-sm text-base-content/60 mt-2">
            {ngettext("%{count} view", "%{count} views", @view_count)}
          </div>
          <%!-- Toolbar row renders only when at least one tool does — an empty
            flex row still costs its mt-4, leaving an awkward gap under the
            title on single-language public views with no admin session. --%>
          <% show_switcher? = assigns[:show_language_switcher] != false and length(@translations) > 1 %>
          <div
            :if={show_switcher? || assigns[:admin_edit_url] || @version_dropdown}
            class="flex flex-wrap items-center gap-4 mt-4"
          >
            <%!-- Language Switcher (gated on `publishing_show_language_switcher` —
              disable when the host renders its own switcher in the layout). --%>
            <%= if show_switcher? do %>
              <.language_switcher
                languages={build_public_translations(@translations, @current_language)}
                current_language={public_current_language(@translations, @current_language)}
                show_status={false}
                size={:sm}
              />
            <% end %>
            <%!-- Admin Edit Button --%>
            <%= if assigns[:admin_edit_url] do %>
              <a href={@admin_edit_url} class="btn btn-sm btn-outline gap-2">
                <.icon name="hero-pencil-square" class="w-4 h-4" />
                {@admin_edit_label || "Edit"}
              </a>
            <% end %>
            <%!-- Version History Dropdown --%>
            <%= if @version_dropdown do %>
              <div class="dropdown dropdown-end">
                <div tabindex="0" role="button" class="btn btn-ghost btn-sm gap-1">
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  v{@version_dropdown.current_version}
                  <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M19 9l-7 7-7-7"
                    />
                  </svg>
                </div>
                <ul
                  tabindex="0"
                  class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-40 border border-base-200"
                >
                  <%= for v <- @version_dropdown.versions do %>
                    <li>
                      <.link
                        navigate={v.url}
                        class={"flex items-center justify-between #{if v.is_current, do: "active"}"}
                      >
                        <span>v{v.version}</span>
                        <%= if v.is_live do %>
                          <span class="badge badge-success badge-xs h-auto">{gettext("live")}</span>
                        <% end %>
                      </.link>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          </div>
        </header>
        <%!-- Audio version — present whenever the live version carries one. --%>
        <% audio_uuid = Map.get(@post.metadata, :audio_uuid) %>
        <figure :if={audio_uuid} class="mb-8">
          <audio
            controls
            preload="none"
            class="w-full"
            src={PhoenixKit.Modules.Storage.URLSigner.signed_url(audio_uuid, "original")}
          >
            {gettext("Your browser does not support the audio element.")}
          </audio>
          <figcaption class="mt-1 text-xs text-base-content/60">
            {gettext("Listen to this post")}
          </figcaption>
        </figure>
        <%!-- Post Content --%>
        <div class="markdown-content max-w-none">
          {raw(@html_content)}
        </div>
        <%!-- Categories (gated on show_categories) — chips link to their
          archives. They sit BELOW the content: they're filing metadata, not
          something a reader needs before the first paragraph. Tags aren't
          listed at all any more — they live inline in the prose as #hashtags,
          already rendered as links to the same archives, so a chip row just
          repeated them. --%>
        <% post_categories = assigns[:post_categories] || [] %>
        <%!-- Everything else on this page announces a change of register with
              a rule: the header closes with one, comments and the footer open
              with one. These two sat between the prose and the comments on
              margin alone, so the article appeared to trail off into its own
              filing metadata.

              The rule goes on whichever of the two comes first, not on both —
              two rules for one boundary reads as a table. Which one that is
              depends on the group's settings, hence the flag rather than a
              fixed class.

              Bare `border-t`, deliberately: the header, comments and footer
              rules all use the default border colour, which resolves to a
              near-black oklch(0.21 …). Naming `border-base-200` here drew it
              at oklch(0.96 …) — all but invisible, and visibly weaker than
              the rules a few lines above and below it. --%>
        <% trailing_rule = "mt-6 border-t pt-4" %>
        <div
          :if={post_categories != []}
          class={["flex flex-wrap gap-2", trailing_rule]}
        >
          <.link
            :for={category <- post_categories}
            navigate={term_archive_path(@current_language, @group_slug, {:category, category.slug})}
            class="badge badge-primary badge-outline badge-sm hover:badge-primary"
          >
            {PublishingCategory.translated_name(category, @current_language)}
          </.link>
        </div>
        <%!-- Chronological neighbors (gated on the group's show_prev_next
          setting; either side absent at the chronology's edge). Newer on the
          left mirrors the newest-first listing order. --%>
        <nav
          :if={assigns[:newer_post] || assigns[:older_post]}
          class={[
            "grid gap-4 sm:grid-cols-2",
            # Following the categories, this is the second half of one
            # trailing block rather than a new section, so it sits close. The
            # old `mt-8` was sized for a boundary it used to mark itself and
            # left a gap nearly as tall as the chips row above it.
            if(post_categories == [], do: trailing_rule, else: "mt-4")
          ]}
          aria-label={gettext("More posts")}
        >
          <.link
            :if={assigns[:newer_post]}
            navigate={@newer_post.url}
            class="group flex flex-col gap-1 rounded-lg border border-base-200 p-4 transition-colors hover:border-primary/40"
          >
            <span class="inline-flex items-center gap-1 text-xs text-base-content/50">
              <.icon name="hero-arrow-left" class="w-3 h-3" /> {gettext("Newer")}
            </span>
            <span class="font-medium group-hover:text-primary">{@newer_post.title}</span>
          </.link>
          <.link
            :if={assigns[:older_post]}
            navigate={@older_post.url}
            class="group flex flex-col gap-1 rounded-lg border border-base-200 p-4 text-right transition-colors hover:border-primary/40 sm:col-start-2"
          >
            <span class="inline-flex items-center justify-end gap-1 text-xs text-base-content/50">
              {gettext("Older")} <.icon name="hero-arrow-right" class="w-3 h-3" />
            </span>
            <span class="font-medium group-hover:text-primary">{@older_post.title}</span>
          </.link>
        </nav>
        <%!-- Comments (gated on comments_enabled + the optional comments
          module). Dead-view thread + plain POST form — works with no JS;
          the controller handles honeypot/time-trap/auth and redirects back
          here with a flash. --%>
        <%!-- The enhancement script lives OUTSIDE #comments: that section
          gets swapped by the script itself, and a document-level listener
          shouldn't ride a subtree it replaces. --%>
        <div :if={assigns[:comments_enabled]} class="hidden" aria-hidden="true">
          {Phoenix.HTML.raw(comment_fetch_assets())}
        </div>
        <section :if={assigns[:comments_enabled]} id="comments" class="mt-10 border-t pt-6">
          {Publishing.Comments.content_styles()}
          <h2 class="mb-4 text-lg font-semibold">
            {ngettext("%{count} comment", "%{count} comments", @post_comment_count)}
          </h2>
          <div :if={@post_comments == []} class="mb-6 text-sm text-base-content/60">
            {gettext("No comments yet — be the first.")}
          </div>
          <ol class="mb-8 space-y-5">
            <.comment_node
              :for={comment <- @post_comments}
              comment={comment}
              form_action={build_post_url(@group_slug, @post, @current_language) <> "#comments"}
              post_uuid={@post.uuid}
              form_token={assigns[:comment_form_token]}
              can_comment={can_comment?(assigns)}
            />
          </ol>
          <%= if can_comment?(assigns) do %>
            <.comment_form
              action={build_post_url(@group_slug, @post, @current_language) <> "#comments"}
              post_uuid={@post.uuid}
              token={assigns[:comment_form_token]}
            />
          <% else %>
            <div class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
              <.link navigate={PhoenixKit.Utils.Routes.path("/users/log-in")} class="link">
                {gettext("Log in")}
              </.link>
              {gettext("to join the conversation.")}
            </div>
          <% end %>
        </section>
        <%!-- Author-note slide-out panels ("panel" notes style). Pure CSS:
          a note ref in the body targets its panel; :target slides it in
          from the right — no JS. Each panel carries the note text and,
          when commenting is on, that note's own comment thread. --%>
        <.note_panels
          :if={assigns[:post_notes] != nil and assigns.post_notes != []}
          post_notes={@post_notes}
          note_comments={assigns[:note_comments] || %{}}
          comments_enabled={assigns[:comments_enabled]}
          form_action={build_post_url(@group_slug, @post, @current_language)}
          post_uuid={@post.uuid}
          form_token={assigns[:comment_form_token]}
          can_comment={can_comment?(assigns)}
        />
        <%!-- Post Footer — same compact muted link as the top, no button chrome. --%>
        <footer class="mt-6 border-t pt-2">
          <.link
            navigate={group_listing_path(@current_language, @group_slug)}
            class="inline-flex items-center gap-1 text-xs text-base-content/50 hover:text-primary transition-colors"
            aria-label={gettext("Back to %{group}", group: @group_name)}
          >
            <.icon name="hero-arrow-left" class="w-3 h-3" /> {@group_name}
          </.link>
        </footer>
      </article>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  @doc """
  Builds the public URL for a group listing page.
  Omits the locale prefix when the site is effectively single-language.
  Can also omit the default-language prefix when that setting is enabled.
  """
  def group_listing_path(language, group_slug, params \\ []) do
    # Segment ≠ identity: a non-owner sibling dialect renders as its full
    # lowercase code ("en-gb"); everything else keeps the base code. The
    # prefix decision uses the ORIGINAL language (only the primary itself
    # may go prefixless).
    segment = LanguageHelpers.public_url_segment(language)

    segments =
      if LanguageHelpers.use_language_prefix?(language),
        do: [segment, group_slug],
        else: [group_slug]

    base_path = build_public_path(segments)

    # Match both `[]` and `%{}` as "no query string" — `Listing.render_group_listing/4`
    # passes `Map.take(params, ["page"])` here, which is a Map. Encoding an empty
    # Map produces `""`, but `base_path <> "?" <> ""` is `"foo?"` — a different
    # URL than `foo` per HTTP. The canonical-URL comparison would then disagree
    # with the request URL forever and the 301 redirect loops to itself.
    case URI.encode_query(params) do
      "" -> base_path
      encoded -> base_path <> "?" <> encoded
    end
  end

  @doc """
  Builds the public URL for a group's RSS feed (`…/<group>/feed.xml`) or a
  term archive's (`…/<group>/category/<slug>/feed.xml`, `…/tag/<tag>/feed.xml`),
  with the same locale-prefix rules as `group_listing_path/3`.
  """
  def feed_path(language, group_slug, scope \\ nil) do
    segment = LanguageHelpers.public_url_segment(language)

    tail =
      case scope do
        {:category, slug} -> ["category", slug, "feed.xml"]
        {:tag, tag} -> ["tag", tag, "feed.xml"]
        nil -> ["feed.xml"]
      end

    segments =
      if LanguageHelpers.use_language_prefix?(language),
        do: [segment, group_slug | tail],
        else: [group_slug | tail]

    build_public_path(segments)
  end

  @doc """
  Public URL for a category archive (`…/<group>/category/<slug>`) or tag
  archive (`…/<group>/tag/<tag>`).
  """
  def term_archive_path(language, group_slug, {type, value}) do
    segment = LanguageHelpers.public_url_segment(language)

    tail = [to_string(type), value]

    segments =
      if LanguageHelpers.use_language_prefix?(language),
        do: [segment, group_slug | tail],
        else: [group_slug | tail]

    build_public_path(segments)
  end

  @doc """
  Builds a post URL based on mode.
  Omits the locale prefix when the site is effectively single-language.
  Can also omit the default-language prefix when that setting is enabled.

  For slug mode posts, uses the language-specific URL slug (from post.url_slug
  or post.language_slugs[language]) for SEO-friendly localized URLs.

  For timestamp mode posts:
  - If only one post exists on the date, uses date-only URL (e.g., /group/2025-12-09)
  - If multiple posts exist on the date, includes time (e.g., /group/2025-12-09/16:26)
  """
  def build_post_url(group_slug, post, language, date_counts \\ nil) do
    # The ORIGINAL language keeps its identity for the per-language slug
    # lookup (an "en-GB" caller must get the en-GB slug) and for the prefix
    # decision; only the rendered path segment goes through
    # public_url_segment (sibling dialects → lowercase full code).
    language = language || LanguageHelpers.get_primary_language()
    segment = LanguageHelpers.public_url_segment(language)

    case post.mode do
      mode when mode in @slug_modes ->
        # Use language-specific URL slug for SEO-friendly localized URLs
        url_slug = get_url_slug_for_language(post, language)

        segments =
          if LanguageHelpers.use_language_prefix?(language),
            do: [segment, group_slug, url_slug],
            else: [group_slug, url_slug]

        build_public_path(segments)

      mode when mode in @timestamp_modes ->
        date = get_timestamp_date(post)
        post_count = lookup_date_count(date_counts, group_slug, date)

        segments =
          timestamp_url_segments({language, segment}, group_slug, date, post_count > 1, post)

        build_public_path(segments)

      _ ->
        # Use language-specific URL slug for fallback mode as well
        url_slug = get_url_slug_for_language(post, language)

        segments =
          if LanguageHelpers.use_language_prefix?(language),
            do: [segment, group_slug, url_slug],
            else: [group_slug, url_slug]

        build_public_path(segments)
    end
  end

  defp timestamp_url_segments({language, segment}, group_slug, date, true = _include_time, post) do
    time = get_timestamp_time(post)

    if LanguageHelpers.use_language_prefix?(language),
      do: [segment, group_slug, date, time],
      else: [group_slug, date, time]
  end

  defp timestamp_url_segments({language, segment}, group_slug, date, false = _include_time, _post) do
    if LanguageHelpers.use_language_prefix?(language),
      do: [segment, group_slug, date],
      else: [group_slug, date]
  end

  # Gets the URL slug for a specific language
  # Priority:
  # 1. language_slugs map (from cache/mapper — the per-language slugs) when
  #    the requested language resolves to one of its keys
  # 2. Direct url_slug field on post (set by controller for specific language)
  # 3. metadata.url_slug (from content record, current language only)
  # 4. post.slug (post slug fallback)
  #
  # The per-language map MUST outrank the top-level :url_slug: listing maps
  # (Mapper.to_listing_map/5) always fill :url_slug with the PRIMARY
  # language's slug, so checking it first made a custom slug set in any other
  # language unreachable from listing links — cards on /de/... linked the
  # primary slug. When the language does NOT resolve (post has no content in
  # it), the old chain applies unchanged.
  defp get_url_slug_for_language(post, language) do
    language_slugs = Map.get(post, :language_slugs) || %{}

    resolved_key =
      if map_size(language_slugs) > 0 do
        LanguageHelpers.resolve_language_key(language, Map.keys(language_slugs))
      end

    cond do
      # Per-language slug for the requested (resolved) language
      resolved_key != nil and Map.get(language_slugs, resolved_key) not in [nil, ""] ->
        Map.get(language_slugs, resolved_key)

      # Direct url_slug on post (set by controller)
      Map.get(post, :url_slug) not in [nil, ""] ->
        post.url_slug

      # metadata.url_slug
      is_map(Map.get(post, :metadata)) and Map.get(post.metadata, :url_slug) not in [nil, ""] ->
        post.metadata.url_slug

      # Default to post slug
      true ->
        post.slug
    end
  end

  @doc """
  Builds a public path with explicit date and time (always includes time).
  Used when redirecting from date-only URLs to full timestamp URLs.
  """
  def build_public_path_with_time(language, group_slug, date, time) do
    segment = LanguageHelpers.public_url_segment(language)

    segments =
      if LanguageHelpers.use_language_prefix?(language),
        do: [segment, group_slug, date, time],
        else: [group_slug, date, time]

    build_public_path(segments)
  end

  @doc """
  Formats a date for display using locale-aware month names.
  """
  def format_date(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_date()
    |> locale_strftime(gettext("%B %d, %Y"))
  end

  def format_date(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        datetime
        |> DateTime.to_date()
        |> locale_strftime(gettext("%B %d, %Y"))

      _ ->
        datetime_string
    end
  end

  def format_date(_), do: ""

  @doc """
  Formats a date with time for display.
  Used when multiple posts exist on the same date.
  """
  def format_date_with_time(datetime) when is_struct(datetime, DateTime) do
    date_str = locale_strftime(datetime, gettext("%B %d, %Y"))
    time_str = Calendar.strftime(datetime, "%H:%M")
    gettext("%{date} at %{time}", date: date_str, time: time_str)
  end

  def format_date_with_time(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        date_str = locale_strftime(datetime, gettext("%B %d, %Y"))
        time_str = Calendar.strftime(datetime, "%H:%M")
        gettext("%{date} at %{time}", date: date_str, time: time_str)

      _ ->
        datetime_string
    end
  end

  def format_date_with_time(_), do: ""

  @doc """
  Checks if a post has a publication date to display.
  For timestamp mode, the date comes from the DB fields.
  For slug mode, it comes from metadata.published_at.
  """
  def has_publication_date?(post) do
    case post.mode do
      mode when mode in @timestamp_modes ->
        # Timestamp mode always has a date (from DB fields)
        post[:date] != nil

      _ ->
        # Slug mode uses metadata.published_at
        published_at = get_in(post, [:metadata, :published_at])
        published_at != nil and published_at != ""
    end
  end

  @doc """
  Formats a post's publication date, including time only when multiple posts exist on the same date.
  """
  def format_post_date(post, group_slug, date_counts \\ nil) do
    case post.mode do
      mode when mode in @timestamp_modes ->
        # For timestamp mode, use date/time from DB fields
        date = get_timestamp_date(post)
        post_count = lookup_date_count(date_counts, group_slug, date)

        if post_count > 1 do
          format_timestamp_date_with_time(post)
        else
          format_timestamp_date(post)
        end

      _ ->
        format_date(post.metadata.published_at)
    end
  end

  @doc """
  Formats a date for URL.
  """
  def format_date_for_url(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  def format_date_for_url(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        datetime
        |> DateTime.to_date()
        |> Date.to_iso8601()

      _ ->
        "2025-01-01"
    end
  end

  def format_date_for_url(_), do: "2025-01-01"

  @doc """
  Formats time for URL (HH:MM).
  """
  def format_time_for_url(datetime) when is_struct(datetime, DateTime) do
    datetime
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
    |> String.slice(0..4)
  end

  def format_time_for_url(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} ->
        datetime
        |> DateTime.to_time()
        |> Time.truncate(:second)
        |> Time.to_string()
        |> String.slice(0..4)

      _ ->
        "00:00"
    end
  end

  def format_time_for_url(_), do: "00:00"

  @doc """
  Pluralizes a word based on count.
  """
  def pluralize(1, singular, _plural), do: "1 #{singular}"
  def pluralize(count, _singular, plural), do: "#{count} #{plural}"

  @doc """
  Extracts and renders an excerpt from post content.
  Returns content before <!-- more --> tag, or first paragraph if no tag.
  Renders markdown and strips HTML tags for plain text display.
  """
  def extract_excerpt(content) when is_binary(content) do
    excerpt_markdown =
      if String.contains?(content, "<!-- more -->") do
        # Extract content before <!-- more --> tag
        content
        |> String.split("<!-- more -->")
        |> List.first()
        |> String.trim()
      else
        # Get first paragraph (content before first double newline)
        content
        |> String.split(~r/\n\s*\n/, parts: 2)
        |> List.first()
        |> String.trim()
      end

    # PHK components must not reach the preview: rendering a <Note> here
    # would bake its body text AND the notes-section CSS into the excerpt,
    # and a truncated component tag survives tag-stripping as escaped junk.
    html = excerpt_markdown |> Shared.strip_components() |> Renderer.render_markdown()

    # Strip HTML tags to get plain text
    html
    |> Phoenix.HTML.raw()
    |> Phoenix.HTML.safe_to_string()
    |> strip_html_tags()
    |> decode_basic_entities()
    |> String.trim()
  end

  def extract_excerpt(_), do: ""

  # The renderer HTML-escapes text; after tag-stripping the excerpt is plain
  # text that HEEx will escape AGAIN, so "Fish & chips" read "Fish &amp;
  # chips" on every card. Decode the standard named entities back — `&amp;`
  # LAST, or a double-encoded `&amp;lt;` would decode twice.
  defp decode_basic_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  defp strip_html_tags(html) when is_binary(html) do
    html
    # style/script CONTENT is not prose — removing only the tags used to
    # leave a wall of CSS text in excerpts and inflate reading-time counts.
    |> String.replace(~r/<(style|script)\b[^>]*>.*?<\/\1>/is, " ")
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Maps the group's post_width setting to a max-width class for the article.
  defp post_width_class("narrow"), do: "max-w-2xl"
  defp post_width_class("wide"), do: "max-w-6xl"
  defp post_width_class(_), do: "max-w-4xl"

  # Estimates reading time from the rendered HTML (min 1 min).
  #
  # The rate is a setting because 200 wpm is an English prose figure, and the
  # label is shown to whoever the site is written for: dense technical writing
  # is read slower, a language with longer words counts fewer of them for the
  # same reading, and a site can simply disagree. Hardcoding it made the one
  # number on the page that is a claim about the READER unarguable.
  defp reading_time_label(html) when is_binary(html) do
    words =
      html
      |> strip_html_tags()
      |> String.split(~r/\s+/, trim: true)
      |> length()

    minutes = max(1, ceil(words / reading_words_per_minute()))
    ngettext("%{count} min read", "%{count} min read", minutes)
  end

  defp reading_time_label(_), do: ""

  @default_reading_wpm 200

  defp reading_words_per_minute do
    case Settings.get_setting_cached("publishing_reading_wpm") do
      nil ->
        @default_reading_wpm

      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> @default_reading_wpm
        end

      _ ->
        @default_reading_wpm
    end
  end

  # Formats a timestamp post's date for display (e.g., "December 31, 2025")
  defp format_timestamp_date(post) do
    cond do
      is_struct(post[:date], Date) ->
        locale_strftime(post.date, gettext("%B %d, %Y"))

      is_binary(post[:date]) ->
        case Date.from_iso8601(post.date) do
          {:ok, date} -> locale_strftime(date, gettext("%B %d, %Y"))
          _ -> post.date
        end

      true ->
        format_date(post.metadata.published_at)
    end
  end

  # Formats a timestamp post's date with time for display (e.g., "December 31, 2025 at 03:42")
  defp format_timestamp_date_with_time(post) do
    date_str = format_timestamp_date(post)
    time_str = get_timestamp_time(post)
    gettext("%{date} at %{time}", date: date_str, time: time_str)
  end

  # Gets the date for a timestamp-mode post from post.date field (DB fields)
  # Falls back to metadata.published_at if post.date not available
  defp get_timestamp_date(post) do
    cond do
      # Use post.date from DB fields (e.g., Date struct or "2025-12-31")
      is_struct(post[:date], Date) ->
        Date.to_iso8601(post.date)

      is_binary(post[:date]) ->
        post.date

      # Fallback to metadata.published_at if no post.date
      true ->
        format_date_for_url(post.metadata.published_at)
    end
  end

  # Gets the time for a timestamp-mode post from post.time field (DB fields)
  # Falls back to metadata.published_at if post.time not available
  defp get_timestamp_time(post) do
    cond do
      # Use post.time from DB fields (e.g., "03:42" or ~T[03:42:00])
      is_struct(post[:time], Time) ->
        post.time |> Time.to_string() |> String.slice(0..4)

      is_binary(post[:time]) ->
        # Ensure format is HH:MM (5 chars)
        String.slice(post.time, 0..4)

      # Fallback to metadata.published_at if no post.time
      true ->
        format_time_for_url(post.metadata.published_at)
    end
  end

  defp build_public_path(segments) do
    parts =
      url_prefix_segments() ++
        (segments
         |> Enum.reject(&(&1 in [nil, ""]))
         |> Enum.map(&to_string/1))

    case parts do
      [] -> "/"
      _ -> "/" <> Enum.join(parts, "/")
    end
  end

  defp url_prefix_segments do
    Config.get_url_prefix()
    |> case do
      "/" -> []
      prefix -> prefix |> String.trim("/") |> String.split("/", trim: true)
    end
  end

  @doc """
  Pre-computes date counts for timestamp-mode posts to avoid per-post DB queries.

  Returns a map of `%{date_string => count}` for use with `build_post_url/4`
  and `format_post_date/3`.
  """
  def build_date_counts(posts) do
    posts
    |> Enum.filter(&(&1.mode in @timestamp_modes))
    |> Enum.map(&get_timestamp_date/1)
    |> Enum.frequencies()
  end

  # Looks up date count from pre-computed map, falling back to DB query
  defp lookup_date_count(nil, group_slug, date) do
    Publishing.count_posts_on_date(group_slug, date)
  end

  defp lookup_date_count(date_counts, _group_slug, date) when is_map(date_counts) do
    Map.get(date_counts, date, 0)
  end

  @doc """
  Resolves a featured image URL for a post, falling back to the original variant.
  """
  def featured_image_url(post, variant \\ "medium") do
    post.metadata
    |> Map.get(:featured_image_uuid)
    |> resolve_featured_image_url(variant)
  end

  defp resolve_featured_image_url(nil, _variant), do: nil
  defp resolve_featured_image_url("", _variant), do: nil

  defp resolve_featured_image_url(file_uuid, variant) when is_binary(file_uuid) do
    Storage.get_public_url_by_uuid(file_uuid, variant) ||
      Storage.get_public_url_by_uuid(file_uuid)
  rescue
    _ -> nil
  end

  @doc """
  Builds language data for the publishing_language_switcher component on public pages.
  Converts the @translations assign to the format expected by the component.
  """
  def build_public_translations(translations, _current_language) do
    translations
    # A disabled/legacy language is not publicly routable — RouterDispatch
    # only rewrites ENABLED locales, so these entries' URLs 404 at the host.
    # The post-page translation list deliberately includes them (admin
    # context); the public switcher must not render dead links. The current
    # entry survives regardless so the switcher never loses its anchor;
    # entries without the flag (listing translations) are enabled-only by
    # construction.
    |> Enum.reject(fn t -> Map.get(t, :enabled) == false and not (t.current || false) end)
    |> Enum.map(fn translation ->
      %{
        code: translation.code,
        display_code: translation.display_code || translation.code,
        name: translation.name,
        flag: translation.flag || "",
        url: translation.url,
        current: translation.current || false,
        status: Constants.status_published(),
        exists: true
      }
    end)
  end

  @doc """
  Resolves the exact language-switcher code to highlight on public pages.
  """
  def public_current_language(translations, fallback) do
    Enum.find_value(translations, fallback, fn translation ->
      if translation.current do
        translation.code
      end
    end)
  end

  # Locale-aware Calendar.strftime that translates month names via gettext.
  # The format string itself can also be translated (e.g., "%d %B %Y" for day-first locales).
  defp locale_strftime(date_or_datetime, format) do
    Calendar.strftime(date_or_datetime, format,
      month_names: fn month ->
        Enum.at(translated_month_names(), month - 1)
      end,
      abbreviated_month_names: fn month ->
        Enum.at(translated_abbreviated_month_names(), month - 1)
      end
    )
  end

  defp translated_month_names do
    [
      gettext("January"),
      gettext("February"),
      gettext("March"),
      gettext("April"),
      gettext("May"),
      gettext("June"),
      gettext("July"),
      gettext("August"),
      gettext("September"),
      gettext("October"),
      gettext("November"),
      gettext("December")
    ]
  end

  defp translated_abbreviated_month_names do
    [
      gettext("Jan"),
      gettext("Feb"),
      gettext("Mar"),
      gettext("Apr"),
      gettext("May"),
      gettext("Jun"),
      gettext("Jul"),
      gettext("Aug"),
      gettext("Sep"),
      gettext("Oct"),
      gettext("Nov"),
      gettext("Dec")
    ]
  end
end
