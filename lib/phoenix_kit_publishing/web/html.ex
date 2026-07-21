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
  alias PhoenixKit.Modules.Publishing.Renderer
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

  def all_groups(assigns) do
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
      <div class="groups-overview-container max-w-6xl mx-auto px-6 py-8">
        <%!-- Page Header --%>
        <header class="mb-8">
          <h1 class="text-2xl sm:text-4xl font-bold mb-2">{gettext("Publishing")}</h1>
          <p class="text-base sm:text-lg text-base-content/70">
            {gettext("Explore our published content")}
          </p>
        </header>
        <%!-- Group Cards --%>
        <%= if length(@groups) > 0 do %>
          <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
            <%= for group <- @groups do %>
              <article class="card bg-base-200 shadow-md hover:shadow-lg transition-shadow">
                <div class="card-body">
                  <h2 class="card-title text-2xl">
                    <.link
                      navigate={group_listing_path(@current_language, group["slug"])}
                      class="hover:text-primary"
                    >
                      {Publishing.translated_group_name(group, @current_language)}
                    </.link>
                  </h2>

                  <div class="text-sm text-base-content/70 mt-2">
                    <span>{ngettext("%{count} post", "%{count} posts", group["post_count"],
                      count: group["post_count"]
                    )}</span>
                  </div>

                  <div class="card-actions justify-end mt-4">
                    <.link
                      navigate={group_listing_path(@current_language, group["slug"])}
                      class="btn btn-sm btn-primary"
                    >
                      {gettext("View Posts")} →
                    </.link>
                  </div>
                </div>
              </article>
            <% end %>
          </div>
        <% else %>
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
            <span>{gettext("No groups configured yet.")}</span>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
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
        </header>
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

        <%!-- Posts Grid --%>
        <%= if @posts != [] do %>
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
            <span>{gettext("No published posts yet.")}</span>
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

        <div class="card-actions justify-between items-center mt-4">
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
        (@band == :featured && "ring-primary/20") || "ring-secondary/20",
        (@layout == "card" && "min-h-64") || "min-h-80 lg:min-h-96"
      ]}
      data-post-date={effective_post_date(@post)}
    >
      <%!-- Decorative — the title link below is the accessible route. --%>
      <img
        :if={@img}
        src={@img}
        alt=""
        aria-hidden="true"
        loading="lazy"
        class="absolute inset-0 h-full w-full object-cover"
      />
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
      <div
        aria-hidden="true"
        class="absolute inset-0 bg-gradient-to-t from-black/80 via-black/40 to-black/10"
      >
      </div>
      <%!-- Stretched link — the whole background clicks through to the post
        (same listing_image_links gate as card images). Sits after the scrim
        and before the z-10 content, so the title/Read More links still win
        in the text strip. Decorative for a11y: the title link is the route. --%>
      <.link
        :if={@image_links}
        navigate={@post_url}
        class="pk-band-cover-link absolute inset-0"
        tabindex="-1"
        aria-hidden="true"
      >
      </.link>
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
        (@band == :featured && "ring-primary/20") || "ring-secondary/20",
        (@layout == "card" && "min-h-64") || "min-h-80 lg:min-h-96"
      ]}
      data-post-date={effective_post_date(@post)}
    >
      <img
        :if={@img}
        src={@img}
        alt=""
        aria-hidden="true"
        loading="lazy"
        class="absolute inset-0 h-full w-full object-cover"
      />
      <%!-- Same stretched-link treatment as band_cover — the image area
        outside the text panel clicks through to the post. --%>
      <.link
        :if={@image_links}
        navigate={@post_url}
        class="pk-band-cover-link absolute inset-0"
        tabindex="-1"
        aria-hidden="true"
      >
      </.link>
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
      <div class="flex flex-col gap-2">
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
        (@band == :featured && "ring-primary/20") || "ring-secondary/20"
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
    <div class="mt-2 flex items-center justify-between gap-4">
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

  # An explicit description wins; otherwise derive an excerpt from the content.
  defp post_card_excerpt(post) do
    if desc = Map.get(post.metadata, :description) do
      desc
    else
      extract_excerpt(post.content)
    end
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
      <.scrollbar_style_tag style={assigns[:scrollbar_style] || "default"} />
      <.reading_progress enabled={assigns[:scroll_progress_enabled] || false} />
      <.reading_headings enabled={assigns[:scroll_headings_enabled] || false} />
      <article class={["post-container mx-auto px-6 py-8", post_width_class(assigns[:post_width])]}>
        <%!-- Top back link (gated on the group's show_top_back_link setting,
          default on) — a compact muted twin of the footer link, hugging the
          title so it doesn't cost the page a band of empty space. --%>
        <nav :if={assigns[:show_top_back_link] != false} class="mb-1">
          <.link
            navigate={group_listing_path(@current_language, @group_slug)}
            class="inline-flex items-center gap-1 text-xs text-base-content/50 hover:text-primary transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-3 h-3" /> {gettext("Back to %{group}",
              group: @group_name
            )}
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
                          <span class="badge badge-success badge-xs h-auto">live</span>
                        <% end %>
                      </.link>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          </div>
        </header>
        <%!-- Tags (gated on the group's show_tags setting) --%>
        <% post_tags = if assigns[:show_tags], do: post_tag_list(@post), else: [] %>
        <div :if={post_tags != []} class="flex flex-wrap gap-2 mb-8">
          <span :for={tag <- post_tags} class="badge badge-outline badge-sm">{tag}</span>
        </div>
        <%!-- Post Content --%>
        <div class="markdown-content max-w-none">
          {raw(@html_content)}
        </div>
        <%!-- Post Footer — same compact muted link as the top, no button chrome. --%>
        <footer class="mt-6 border-t pt-2">
          <.link
            navigate={group_listing_path(@current_language, @group_slug)}
            class="inline-flex items-center gap-1 text-xs text-base-content/50 hover:text-primary transition-colors"
          >
            <.icon name="hero-arrow-left" class="w-3 h-3" /> {gettext("Back to %{group}",
              group: @group_name
            )}
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
    language =
      LanguageHelpers.url_language_code(language) || LanguageHelpers.get_primary_language_base()

    segments =
      if LanguageHelpers.use_language_prefix?(language),
        do: [language, group_slug],
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
    language =
      LanguageHelpers.url_language_code(language) || LanguageHelpers.get_primary_language_base()

    case post.mode do
      mode when mode in @slug_modes ->
        # Use language-specific URL slug for SEO-friendly localized URLs
        url_slug = get_url_slug_for_language(post, language)

        segments =
          if LanguageHelpers.use_language_prefix?(language),
            do: [language, group_slug, url_slug],
            else: [group_slug, url_slug]

        build_public_path(segments)

      mode when mode in @timestamp_modes ->
        date = get_timestamp_date(post)
        post_count = lookup_date_count(date_counts, group_slug, date)

        segments = timestamp_url_segments(language, group_slug, date, post_count > 1, post)

        build_public_path(segments)

      _ ->
        # Use language-specific URL slug for fallback mode as well
        url_slug = get_url_slug_for_language(post, language)

        segments =
          if LanguageHelpers.use_language_prefix?(language),
            do: [language, group_slug, url_slug],
            else: [group_slug, url_slug]

        build_public_path(segments)
    end
  end

  defp timestamp_url_segments(language, group_slug, date, true = _include_time, post) do
    time = get_timestamp_time(post)

    if LanguageHelpers.use_language_prefix?(language),
      do: [language, group_slug, date, time],
      else: [group_slug, date, time]
  end

  defp timestamp_url_segments(language, group_slug, date, false = _include_time, _post) do
    if LanguageHelpers.use_language_prefix?(language),
      do: [language, group_slug, date],
      else: [group_slug, date]
  end

  # Gets the URL slug for a specific language
  # Priority:
  # 1. Direct url_slug field on post (set by controller for specific language)
  # 2. language_slugs map (from cache, contains all languages)
  # 3. metadata.url_slug (from content record, current language only)
  # 4. post.slug (post slug fallback)
  defp get_url_slug_for_language(post, language) do
    cond do
      # Direct url_slug on post (highest priority, set by controller)
      Map.get(post, :url_slug) not in [nil, ""] ->
        post.url_slug

      # language_slugs map from cache
      map_size(Map.get(post, :language_slugs, %{})) > 0 ->
        resolved_key =
          LanguageHelpers.resolve_language_key(language, Map.keys(post.language_slugs))

        Map.get(post.language_slugs, resolved_key, post.slug)

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
    language =
      LanguageHelpers.url_language_code(language) || LanguageHelpers.get_primary_language_base()

    segments =
      if LanguageHelpers.use_language_prefix?(language),
        do: [language, group_slug, date, time],
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

    # Render markdown to HTML
    html = Renderer.render_markdown(excerpt_markdown)

    # Strip HTML tags to get plain text
    html
    |> Phoenix.HTML.raw()
    |> Phoenix.HTML.safe_to_string()
    |> strip_html_tags()
    |> String.trim()
  end

  def extract_excerpt(_), do: ""

  defp strip_html_tags(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Maps the group's post_width setting to a max-width class for the article.
  defp post_width_class("narrow"), do: "max-w-2xl"
  defp post_width_class("wide"), do: "max-w-6xl"
  defp post_width_class(_), do: "max-w-4xl"

  # Estimates reading time from the rendered HTML at ~200 words/min (min 1 min).
  defp reading_time_label(html) when is_binary(html) do
    words =
      html
      |> strip_html_tags()
      |> String.split(~r/\s+/, trim: true)
      |> length()

    minutes = max(1, ceil(words / 200))
    ngettext("%{count} min read", "%{count} min read", minutes)
  end

  defp reading_time_label(_), do: ""

  # Extracts a clean list of tag strings from a post's metadata.
  defp post_tag_list(%{metadata: %{tags: tags}}) when is_list(tags) do
    tags
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp post_tag_list(_), do: []

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
    Enum.map(translations, fn translation ->
      %{
        code: translation.code,
        display_code: translation.display_code || translation.code,
        name: translation.name,
        flag: translation.flag || "",
        url: translation.url,
        current: translation.current || false,
        status: "published",
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
