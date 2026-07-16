defmodule PhoenixKit.Modules.Publishing.Web.Edit do
  @moduledoc """
  LiveView for editing publishing group metadata such as display name and slug.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitPublishing.Gettext

  require Logger

  alias Phoenix.Component
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Errors
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

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
         |> assign(:form, form)}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"group" => params}, socket) do
    {:noreply, assign(socket, :form, Component.to_form(params, as: :group))}
  end

  def handle_event("save", %{"group" => params}, socket) do
    case Publishing.update_group(socket.assigns.group["slug"], params,
           actor_uuid: Shared.actor_uuid_from_socket(socket)
         ) do
      {:ok, updated_group} ->
        # Broadcast group updated for live dashboard updates
        PublishingPubSub.broadcast_group_updated(updated_group)

        updated_form = Component.to_form(group_form_params(updated_group), as: :group)

        {:noreply,
         socket
         |> assign(:group, updated_group)
         |> assign(:form, updated_form)
         |> put_flash(:info, gettext("Group updated"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{updated_group["slug"]}"))}

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

  defp find_group(slug) do
    Publishing.list_groups()
    |> Enum.find(&(&1["slug"] == slug))
  end

  defp group_form_params(group) do
    %{
      "name" => group["name"],
      "slug" => group["slug"],
      "listing_sort" => group["listing_sort"],
      "show_breadcrumbs" => group["show_breadcrumbs"],
      "post_date_position" => group["post_date_position"],
      "post_width" => group["post_width"],
      "show_featured_image" => group["show_featured_image"],
      "show_reading_time" => group["show_reading_time"],
      "show_tags" => group["show_tags"],
      "featured_enabled" => group["featured_enabled"],
      "featured_layout" => group["featured_layout"],
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
              <.input
                field={@form[:name]}
                type="text"
                label={gettext("Group Name")}
                placeholder={gettext("e.g. Product Updates")}
                required
              />

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

                <.checkbox field={@form[:featured_enabled]}>
                  {gettext("Highlight featured posts")}
                  <:description>
                    {gettext(
                      "Posts marked featured in the editor are pinned to the top and shown larger."
                    )}
                  </:description>
                </.checkbox>

                <div :if={checked?(@form[:featured_enabled].value)} class="pl-8">
                  <.select
                    field={@form[:featured_layout]}
                    label={gettext("Featured layout")}
                    options={featured_layout_options()}
                  />
                </div>

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
                <button
                  type="submit"
                  class="btn btn-primary btn-sm"
                  phx-disable-with={gettext("Saving…")}
                >
                  <.icon name="hero-check" class="w-4 h-4 mr-1" /> {gettext("Save Changes")}
                </button>
                <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel">
                  <.icon name="hero-x-mark" class="w-4 h-4 mr-1" /> {gettext("Cancel")}
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
