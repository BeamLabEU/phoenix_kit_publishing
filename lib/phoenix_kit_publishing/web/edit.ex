defmodule PhoenixKit.Modules.Publishing.Web.Edit do
  @moduledoc """
  LiveView for editing publishing group metadata such as display name and slug.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitPublishing.Gettext
  # Injects the six ai_* handle_event delegates + the {:ai_translation, …}
  # handle_info as composing lifecycle hooks (see the Embed moduledoc).
  use PhoenixKitAI.Components.AITranslate.Embed

  import PhoenixKitAI.Components.AITranslate,
    only: [
      ai_translate_button: 1,
      ai_translate_hint: 1,
      ai_translate_modal: 1,
      ai_translate_progress: 1
    ]

  import PhoenixKitWeb.Components.MultilangForm,
    only: [
      multilang_tabs: 1,
      multilang_fields_wrapper: 1,
      mount_multilang: 1,
      handle_switch_language: 2
    ]

  require Logger

  alias Phoenix.Component
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Errors
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI.Components.AITranslate.FormGlue

  @impl true
  def mount(%{"group" => group_slug} = _params, _session, socket) do
    case find_group(group_slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("The requested group could not be found."))
         |> push_navigate(to: Routes.path("/admin/publishing"))}

      group ->
        form = Component.to_form(group_form_params(group), as: :group)

        {:ok,
         socket
         |> assign(:project_title, Settings.get_project_title())
         |> assign(:page_title, gettext("Edit Group"))
         |> assign(
           :current_path,
           Routes.path("/admin/publishing/edit-group/#{group_slug}")
         )
         |> assign(:group, group)
         |> assign(:form, form)
         |> mount_multilang()
         |> FormGlue.assign_ai_translation(
           "publishing_group",
           # The glue only reads .uuid; a minimal struct satisfies its
           # struct-typed contract without a second group fetch.
           %Publishing.PublishingGroup{uuid: group["uuid"]},
           PhoenixKitPublishing.GroupAITranslateBinding
         )}
    end
  end

  # The AITranslate.Embed hook re-syncs the form after a translation merges.
  # This form is a plain params map behind `to_form(as: :group)` (no Ecto
  # changeset), so override the default changeset-shaped re-assign.
  def ai_translate_assign_form(socket, params) when is_map(params) do
    Component.assign(socket, :form, Component.to_form(params, as: :group))
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"group" => params}, socket) do
    {:noreply, assign(socket, :form, Component.to_form(params, as: :group))}
  end

  # Language tab switch from the tabs component. handle_switch_language/2 debounces
  # and, via the hook mount_multilang/1 attached, flips :current_lang — which
  # re-renders the name inputs so the active language's field is shown.
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("save", %{"group" => params} = all_params, socket) do
    # The "Save and exit" submit button rides `name="exit" value="true"` into
    # the params (entities-form pattern); the plain Save button omits it.
    exit? = all_params["exit"] == "true"
    previous_slug = socket.assigns.group["slug"]

    case Publishing.update_group(previous_slug, params,
           actor_uuid: Shared.actor_uuid_from_socket(socket)
         ) do
      {:ok, updated_group} ->
        # No broadcast here — Groups.update_group/3 already broadcasts
        # {:group_updated, group} after the DB write; a second one from the LV
        # made every subscriber refresh twice per save.
        updated_form = Component.to_form(group_form_params(updated_group), as: :group)

        socket =
          socket
          |> assign(:group, updated_group)
          |> assign(:form, updated_form)
          |> put_flash(:info, gettext("Group updated"))

        cond do
          exit? ->
            {:noreply,
             push_navigate(socket, to: Routes.path("/admin/publishing/#{updated_group["slug"]}"))}

          updated_group["slug"] != previous_slug ->
            # Staying, but this page's URL embeds the (now old) slug — remount
            # the editor at its new address so a reload doesn't 404.
            {:noreply,
             push_navigate(socket,
               to: Routes.path("/admin/publishing/edit-group/#{updated_group["slug"]}")
             )}

          true ->
            {:noreply, socket}
        end

      {:error, :invalid_name} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Please provide a valid group name."))
         |> assign(:form, Component.to_form(params, as: :group))}

      {:error, :invalid_slug} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-group-name)"
           )
         )
         |> assign(:form, Component.to_form(params, as: :group))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Group not found"))
         |> push_navigate(to: Routes.path("/admin/publishing"))}
    end
  rescue
    # Narrow to the realistic failure classes (DB errors, optimistic-lock
    # races, query construction). Leaves system errors / programmer mistakes
    # / ArithmeticError etc. to crash the LV with a useful stacktrace.
    e in [
      Ecto.QueryError,
      Ecto.ConstraintError,
      Ecto.StaleEntryError,
      DBConnection.ConnectionError
    ] ->
      Logger.error(
        "[Publishing.Edit] Group save failed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Something went wrong while saving this group.") <>
           " " <> Errors.truncate_for_log(Exception.message(e), 200)
       )}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/publishing"))}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[Publishing.Web.Edit] unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Forward-compat dodge (the document_creator/projects `function_exported?`
  # pattern): `ai_multilang_tabs/1` ships in the NEXT phoenix_kit_ai release —
  # the published 0.16.0 this module's `~> 0.4` pin can resolve does not have
  # it, and importing a missing function is a hard compile error for Hex
  # consumers. Until the floor includes the release, dispatch at runtime and
  # fall back to the identical hand-placed layout built from components that
  # DO exist in 0.16.0.
  #
  # Cleanup at floor-bump (tracked in AGENTS.md): when mix.exs raises the
  # phoenix_kit_ai floor past the release that ships ai_multilang_tabs, delete
  # ai_tabs/1 + ai_tabs_fallback/1 and call <.ai_multilang_tabs> directly
  # (import it in `only:`). The dynamic-module call keeps the compiler from
  # warning about the function's absence in the published 0.16.0.
  defp ai_tabs(assigns) do
    mod = PhoenixKitAI.Components.AITranslate

    if Code.ensure_loaded?(mod) and function_exported?(mod, :ai_multilang_tabs, 1) do
      # apply/3, not a direct call — the compiler would warn (and
      # warnings-as-errors fail) on the function's absence in the published
      # phoenix_kit_ai 0.16.0. Same shape as the document_creator/projects
      # forward-compat dodges.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(mod, :ai_multilang_tabs, [assigns])
    else
      ai_tabs_fallback(assigns)
    end
  end

  # Mirrors ai_multilang_tabs' anatomy 1:1 (tabs + button/progress/hint row
  # gated on the tabs' own visibility condition) so both dispatch paths render
  # identically.
  defp ai_tabs_fallback(assigns) do
    ~H"""
    <.multilang_tabs
      multilang_enabled={@multilang_enabled}
      language_tabs={@language_tabs}
      current_lang={@current_lang}
      class={@class}
    />
    <div
      :if={
        @ai_translate[:enabled] == true and @multilang_enabled and
          match?([_, _ | _], @language_tabs)
      }
      class={@ai_row_class}
    >
      <.ai_translate_button ai_translate={@ai_translate} />
      <.ai_translate_progress ai_translate={@ai_translate} />
      <.ai_translate_hint ai_translate={@ai_translate} />
    </div>
    """
  end

  defp find_group(slug) do
    Publishing.list_groups()
    |> Enum.find(&(&1["slug"] == slug))
  end

  defp group_form_params(group) do
    %{
      "name" => group["name"],
      "name_i18n" => group["name_i18n"] || %{},
      "slug" => group["slug"],
      "listing_sort" => group["listing_sort"],
      "show_post_count" => group["show_post_count"],
      "show_breadcrumbs" => group["show_breadcrumbs"],
      "post_date_position" => group["post_date_position"],
      "post_width" => group["post_width"],
      "show_featured_image" => group["show_featured_image"],
      "show_reading_time" => group["show_reading_time"],
      "show_tags" => group["show_tags"],
      "featured_enabled" => group["featured_enabled"],
      "featured_layout" => group["featured_layout"],
      "featured_style" => group["featured_style"],
      "newest_enabled" => group["newest_enabled"],
      "newest_layout" => group["newest_layout"],
      "newest_style" => group["newest_style"],
      "show_top_back_link" => group["show_top_back_link"],
      "listing_image_links" => group["listing_image_links"],
      "listing_animations" => group["listing_animations"],
      "scrollbar_style" => group["scrollbar_style"],
      "scroll_progress_enabled" => group["scroll_progress_enabled"],
      "scroll_headings_enabled" => group["scroll_headings_enabled"],
      "scroll_timeline_enabled" => group["scroll_timeline_enabled"],
      "scroll_timeline_granularity" => group["scroll_timeline_granularity"]
    }
  end

  # A form value is "on" whether it arrives as a boolean (initial mount, from the
  # group map) or a string (a "validate" round-trip serializes checkboxes to
  # "true"/"false"). Used to reveal a dependent field only when its toggle is on.
  defp checked?(value), do: value in [true, "true"]

  # The non-primary language tabs — one translatable name input each.
  defp secondary_language_tabs(tabs), do: Enum.reject(tabs, & &1.is_primary)

  # Current value of a per-language name override out of the form params. The
  # form carries `name_i18n` as a `%{lang => name}` map (seeded on mount, echoed
  # back on every "validate"), so a tab switch never loses a typed translation.
  defp name_i18n_value(form, code) do
    case form[:name_i18n].value do
      %{} = map -> Map.get(map, code, "")
      _ -> ""
    end
  end

  # Label/value pairs for the timeline-granularity <select>. Values must match
  # Publishing.Constants.timeline_granularities/0.
  defp timeline_granularity_options do
    [
      {gettext("Automatic (fit to the posts)"), "auto"},
      {gettext("By year"), "year"},
      {gettext("By month"), "month"},
      {gettext("By day"), "day"}
    ]
  end

  # Label/value pairs for the featured-layout <select>. Values must match
  # Publishing.Constants.featured_layouts/0.
  defp featured_layout_options do
    [
      {gettext("Hero band — a large banner above the list"), "hero"},
      {gettext("Highlighted card — a larger card within the grid"), "card"}
    ]
  end

  # Same vocabulary for the latest-post <select> — values must match
  # Publishing.Constants.newest_layouts/0, which mirrors featured_layouts/0.
  defp newest_layout_options, do: featured_layout_options()

  # Label/value pairs for the band-style <select>s (Featured + Latest share
  # the vocabulary). Values must match Publishing.Constants.band_styles/0.
  defp band_style_options do
    [
      {gettext("Classic — image beside or above the text"), "classic"},
      {gettext("Cover — the image is the background, text overlaid"), "cover"},
      {gettext("Cover panel — background image with a solid text panel"), "cover_panel"},
      {gettext("Minimal — text only, no image"), "minimal"},
      {gettext("Top image — a wide image banner above the text"), "top"}
    ]
  end

  # Label/value pairs for the listing-sort <select>. Values must match
  # Publishing.Constants.listing_sorts/0.
  defp listing_sort_options do
    [
      {gettext("Newest first (by publish date)"), "newest"},
      {gettext("Oldest first (by publish date)"), "oldest"}
    ]
  end

  # Label/value pairs for the post-date-position <select>. Values must match
  # Publishing.Constants.post_date_positions/0.
  defp post_date_position_options do
    [
      {gettext("Below the title"), "below"},
      {gettext("Above the title"), "above"},
      {gettext("Hidden"), "hidden"}
    ]
  end

  # Label/value pairs for the post-width <select>. Values must match
  # Publishing.Constants.post_widths/0.
  defp post_width_options do
    [
      {gettext("Narrow"), "narrow"},
      {gettext("Normal"), "normal"},
      {gettext("Wide"), "wide"}
    ]
  end

  # Label/value pairs for the scrollbar-style <select>. Values must match
  # Publishing.Constants.scrollbar_styles/0.
  defp scrollbar_style_options do
    [
      {gettext("Default — the browser's native scrollbar"), "default"},
      {gettext("Branded — recolored to match the theme"), "branded"},
      {gettext("Thin — branded and slimmer"), "thin"}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container flex flex-col mx-auto px-4 py-6">
      <%!-- Header Section --%>
      <.admin_page_header
        back={Routes.path("/admin/publishing")}
        title={gettext("Edit Group")}
      />

      <div class="max-w-2xl mx-auto space-y-6">
        <div class="card bg-base-100 shadow-xl border border-base-200">
          <div class="card-body space-y-6">
            <.form
              for={@form}
              id="group-edit-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-6"
            >
              <%!-- Group Name — translatable per language. The primary-language
                    name is the required `name` column; other languages are
                    optional overrides stored in data["name_i18n"], falling back
                    to the primary name when blank. All inputs stay in the DOM
                    (only the active language's is visible) so switching tabs
                    never drops a typed translation. --%>
              <%!-- When multiple languages are active, the group name is
                    translatable — set it apart in a tinted, bordered region (like
                    the reference multilang forms) so it's clear which field is
                    language-scoped and which (slug, settings) are not. --%>
              <div class={
                @show_multilang_tabs && "rounded-lg border border-base-200 bg-base-200/40 p-4"
              }>
                <%!-- Bundled tabs + AI-translate row (canonical placement:
                  a compact row tucked under the tabs). Rendered through a
                  forward-compat dodge — see ai_tabs/1. --%>
                <.ai_tabs
                  :if={@show_multilang_tabs}
                  multilang_enabled={@multilang_enabled}
                  language_tabs={@language_tabs}
                  current_lang={@current_lang}
                  class=""
                  ai_row_class="flex items-center gap-3 -mt-3"
                  ai_translate={FormGlue.ai_translate_config(assigns)}
                />

                <.multilang_fields_wrapper
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                >
                  <:skeleton>
                    <div class="space-y-2">
                      <div class="bg-base-content/15 rounded h-4 w-24 animate-pulse"></div>
                      <div class="bg-base-content/15 rounded h-12 w-full animate-pulse"></div>
                    </div>
                  </:skeleton>

                  <%!-- The primary-language name is the required `name` column;
                        other languages are optional overrides in data["name_i18n"].
                        All inputs stay in the DOM (only the active language's is
                        visible) so switching tabs never drops a typed value. --%>
                  <div class={@multilang_enabled && @current_lang != @primary_language && "hidden"}>
                    <.input
                      field={@form[:name]}
                      type="text"
                      label={gettext("Group Name")}
                      placeholder={gettext("e.g. Product Updates")}
                    />
                  </div>

                  <div
                    :for={tab <- secondary_language_tabs(@language_tabs)}
                    class={@current_lang != tab.code && "hidden"}
                  >
                    <.input
                      id={"group_name_i18n_#{tab.code}"}
                      name={"group[name_i18n][#{tab.code}]"}
                      value={name_i18n_value(@form, tab.code)}
                      type="text"
                      label={gettext("Group Name (%{lang})", lang: tab.name)}
                      placeholder={@form[:name].value}
                    />
                    <p class="text-xs text-base-content/60 mt-1">
                      {gettext("Leave blank to use the primary-language name.")}
                    </p>
                  </div>
                </.multilang_fields_wrapper>
              </div>

              <div class="space-y-2">
                <.input
                  field={@form[:slug]}
                  type="text"
                  label={gettext("Slug")}
                  placeholder={gettext("e.g. product-updates")}
                  required
                />
                <div class="space-y-1">
                  <p class="text-xs text-base-content/60">
                    {gettext("The slug is used in URLs for this group's public pages.")}
                  </p>
                  <p class="text-xs font-medium text-base-content/70">
                    <span class="font-semibold">{gettext("Format")}:</span>
                    {gettext(
                      "Only lowercase letters (a-z), numbers (0-9), and hyphens (-) are allowed. Must not start or end with a hyphen."
                    )}
                  </p>
                  <p class="text-xs text-success">
                    ✓ {gettext("Valid examples")}: <code class="font-mono">blog</code>, <code class="font-mono">product-updates</code>,
                    <code class="font-mono">news-2025</code>
                  </p>
                  <p class="text-xs text-error">
                    ✗ {gettext("Invalid examples")}: <code class="font-mono">Blog</code>, <code class="font-mono">product_updates</code>, <code class="font-mono">-news</code>,
                    <code class="font-mono">my blog</code>
                  </p>
                </div>
              </div>

              <div class="rounded-lg border border-base-200 bg-base-200/40 px-4 py-3 text-sm text-base-content/70">
                <p>
                  <span class="font-semibold">{gettext("URL mode")}:</span>
                  <%= case @group["mode"] do %>
                    <% "slug" -> %>
                      {gettext("Slug-based")} · {gettext("Semantic URLs ideal for evergreen content.")}
                    <% _ -> %>
                      {gettext("Timestamp-based")} · {gettext(
                        "Chronological URLs ideal for news and updates."
                      )}
                  <% end %>
                </p>
              </div>

              <%!-- Listing page: the public index that lists this group's posts --%>
              <div class="space-y-4 rounded-lg border border-base-200 p-4">
                <div>
                  <h3 class="text-sm font-semibold text-base-content">
                    {gettext("Listing page")}
                  </h3>
                  <p class="text-xs text-base-content/60 mt-1">
                    {gettext("The public page that lists this group's posts (e.g. /blog).")}
                  </p>
                </div>

                <.select
                  field={@form[:listing_sort]}
                  label={gettext("Post order")}
                  options={listing_sort_options()}
                />

                <.checkbox field={@form[:show_post_count]}>
                  {gettext("Show the post count")}
                  <:description>
                    {gettext("The total number of posts, shown under the listing title.")}
                  </:description>
                </.checkbox>

                <.checkbox field={@form[:featured_enabled]}>
                  {gettext("Highlight featured posts")}
                  <:description>
                    {gettext(
                      "Posts marked featured in the editor are pinned to the top and shown larger."
                    )}
                  </:description>
                </.checkbox>

                <div :if={checked?(@form[:featured_enabled].value)} class="pl-8 space-y-4">
                  <.select
                    field={@form[:featured_layout]}
                    label={gettext("Featured layout")}
                    options={featured_layout_options()}
                  />
                  <.select
                    field={@form[:featured_style]}
                    label={gettext("Featured style")}
                    options={band_style_options()}
                  />
                </div>

                <.checkbox field={@form[:newest_enabled]}>
                  {gettext("Highlight the latest post")}
                  <:description>
                    {gettext(
                      "The most recent post is pinned into its own 'Latest' band under any featured posts and shown larger."
                    )}
                  </:description>
                </.checkbox>

                <div :if={checked?(@form[:newest_enabled].value)} class="pl-8 space-y-4">
                  <.select
                    field={@form[:newest_layout]}
                    label={gettext("Latest layout")}
                    options={newest_layout_options()}
                  />
                  <.select
                    field={@form[:newest_style]}
                    label={gettext("Latest style")}
                    options={band_style_options()}
                  />
                </div>

                <.checkbox field={@form[:listing_image_links]}>
                  {gettext("Clickable card images")}
                  <:description>
                    {gettext("A post card's image clicks through to the post, same as the title.")}
                  </:description>
                </.checkbox>

                <.checkbox field={@form[:listing_animations]}>
                  {gettext("Card hover animations")}
                  <:description>
                    {gettext("Cards lift slightly on hover as a click cue.")}
                  </:description>
                </.checkbox>

                <.checkbox field={@form[:scroll_timeline_enabled]}>
                  {gettext("Show a date-timeline rail")}
                  <:description>
                    {gettext("A clickable date rail down the side to jump through the archive.")}
                  </:description>
                </.checkbox>

                <div :if={checked?(@form[:scroll_timeline_enabled].value)} class="pl-8">
                  <.select
                    field={@form[:scroll_timeline_granularity]}
                    label={gettext("Timeline markers")}
                    options={timeline_granularity_options()}
                  />
                </div>
              </div>

              <%!-- Post page: an individual article --%>
              <div class="space-y-4 rounded-lg border border-base-200 p-4">
                <div>
                  <h3 class="text-sm font-semibold text-base-content">
                    {gettext("Post page")}
                  </h3>
                  <p class="text-xs text-base-content/60 mt-1">
                    {gettext("What shows on an individual post and how it's laid out.")}
                  </p>
                </div>

                <.select
                  field={@form[:post_width]}
                  label={gettext("Content width")}
                  options={post_width_options()}
                />

                <.select
                  field={@form[:post_date_position]}
                  label={gettext("Post date position")}
                  options={post_date_position_options()}
                />

                <.checkbox field={@form[:show_breadcrumbs]}>
                  {gettext("Show the breadcrumb trail")}
                  <:description>
                    {gettext("The 'Home / Blog / …' navigation trail above the title.")}
                  </:description>
                </.checkbox>

                <.checkbox field={@form[:show_featured_image]}>
                  {gettext("Show the featured image")}
                  <:description>
                    {gettext("A large hero image above the title.")}
                  </:description>
                </.checkbox>

                <.checkbox field={@form[:show_top_back_link]}>
                  {gettext("Show the top back link")}
                  <:description>
                    {gettext(
                      "A subtle 'Back to %{group}' link above the post, mirroring the footer button.",
                      group: @group["name"]
                    )}
                  </:description>
                </.checkbox>

                <.checkbox field={@form[:show_reading_time]}>
                  {gettext("Show the reading time")}
                  <:description>
                    {gettext("An estimated 'N min read' under the title.")}
                  </:description>
                </.checkbox>

                <.checkbox field={@form[:show_tags]}>
                  {gettext("Show the post's tags")}
                  <:description>
                    {gettext("The post's tags as chips under the header.")}
                  </:description>
                </.checkbox>

                <.checkbox field={@form[:scroll_progress_enabled]}>
                  {gettext("Show a reading-progress bar")}
                  <:description>
                    {gettext("A thin bar at the top that fills as the reader scrolls.")}
                  </:description>
                </.checkbox>

                <.checkbox field={@form[:scroll_headings_enabled]}>
                  {gettext("Show a heading navigation rail")}
                  <:description>
                    {gettext("A side rail of the post's headings; hidden on short posts.")}
                  </:description>
                </.checkbox>
              </div>

              <%!-- Appearance: applies to every public page in this group --%>
              <div class="space-y-4 rounded-lg border border-base-200 p-4">
                <div>
                  <h3 class="text-sm font-semibold text-base-content">
                    {gettext("Appearance")}
                  </h3>
                  <p class="text-xs text-base-content/60 mt-1">
                    {gettext("Applies to every public page in this group.")}
                  </p>
                </div>

                <.select
                  field={@form[:scrollbar_style]}
                  label={gettext("Scrollbar style")}
                  options={scrollbar_style_options()}
                />
                <p class="text-xs text-base-content/60 -mt-2">
                  {gettext(
                    "Only recolors the real scrollbar — keyboard and touch scrolling stay normal."
                  )}
                </p>
              </div>

              <div class="flex flex-wrap gap-3 justify-end">
                <%!-- Two submits, entities-form pattern: the exit button rides a
                  name/value pair into the params; plain Save stays on the page. --%>
                <button
                  type="submit"
                  class="btn btn-primary btn-outline btn-sm"
                  phx-disable-with={gettext("Saving…")}
                >
                  <.icon name="hero-check" class="w-4 h-4 mr-1" /> {gettext("Save")}
                </button>
                <button
                  type="submit"
                  name="exit"
                  value="true"
                  class="btn btn-primary btn-sm"
                  phx-disable-with={gettext("Saving…")}
                >
                  <.icon name="hero-check" class="w-4 h-4 mr-1" /> {gettext("Save and exit")}
                </button>
                <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel">
                  <.icon name="hero-x-mark" class="w-4 h-4 mr-1" /> {gettext("Cancel")}
                </button>
              </div>
            </.form>
            <%!-- Outside the group form — the modal carries its own selector
              <form>s and HTML forbids nesting them. --%>
            <.ai_translate_modal ai_translate={FormGlue.ai_translate_config(assigns)} />
          </div>
        </div>
      </div>
    </div>
    """
  end
end
