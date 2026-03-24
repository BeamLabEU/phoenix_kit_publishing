defmodule PhoenixKit.Modules.Publishing.Web.PostShow do
  @moduledoc """
  Post overview page showing metadata, versions, languages, and actions.

  Accessible at `/admin/publishing/:group/:post_uuid`.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"]
    post_uuid = params["post_uuid"]

    if connected?(socket) && group_slug do
      PublishingPubSub.subscribe_to_posts(group_slug)
    end

    date_time_settings =
      Settings.get_settings_cached(
        ["date_format", "time_format", "time_zone"],
        %{
          "date_format" => "Y-m-d",
          "time_format" => "H:i",
          "time_zone" => "0"
        }
      )

    socket =
      socket
      |> assign(:group_slug, group_slug)
      |> assign(:post_uuid, post_uuid)
      |> assign(:post, nil)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> assign(:date_time_settings, date_time_settings)
      |> assign(:enabled_languages, Publishing.enabled_language_codes())
      |> assign(:page_title, gettext("Post Overview"))

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"post_uuid" => post_uuid}, _uri, socket) do
    group_slug = socket.assigns.group_slug

    case Publishing.read_post_by_uuid(post_uuid) do
      {:ok, post} ->
        socket =
          socket
          |> assign(:post, post)
          |> assign(:post_uuid, post_uuid)
          |> assign(:page_title, post.metadata.title || gettext("Post Overview"))

        {:noreply, socket}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # PubSub handlers for live updates
  @impl true
  def handle_info({:post_updated, _group_slug, _post_slug}, socket) do
    # Reload post data
    case Publishing.read_post_by_uuid(socket.assigns.post_uuid) do
      {:ok, post} -> {:noreply, assign(socket, :post, post)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Helper functions available to template
  def format_datetime(post) do
    case {post[:date], post[:time]} do
      {%Date{} = date, %Time{} = time} ->
        {:ok, dt} = DateTime.new(date, time, "Etc/UTC")
        UtilsDate.format_datetime_with_user_format(dt)

      {%Date{} = date, _} ->
        UtilsDate.format_date_with_user_format(date)

      _ ->
        ""
    end
  end

  def version_status_badge_class("published"), do: "badge-success"
  def version_status_badge_class("draft"), do: "badge-warning"
  def version_status_badge_class("archived"), do: "badge-ghost"
  def version_status_badge_class(_), do: "badge-ghost"

  def language_status_color("published"), do: "bg-success"
  def language_status_color("draft"), do: "bg-warning"
  def language_status_color("archived"), do: "bg-base-content/20"
  def language_status_color(_), do: "bg-base-content/20"

  @impl true
  def render(assigns) do
    ~H"""
<PhoenixKitWeb.Components.LayoutWrapper.app_layout
  flash={@flash}
  phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
  page_title={@page_title}
  current_path={PhoenixKit.Utils.Routes.path("/admin/publishing/#{@group_slug}/#{@post_uuid}")}
  current_locale={assigns[:current_locale]}
>
  <%= if @post do %>
    <div class="max-w-4xl mx-auto p-4 md:p-6">
      <%!-- Breadcrumb --%>
      <div class="text-sm breadcrumbs mb-4">
        <ul>
          <li>
            <.pk_link navigate="/admin/publishing">{gettext("Publishing")}</.pk_link>
          </li>
          <li>
            <.pk_link navigate={"/admin/publishing/#{@group_slug}"}>{@group_name}</.pk_link>
          </li>
          <li>{@post.metadata.title || gettext("Untitled")}</li>
        </ul>
      </div>

      <%!-- Header with title and actions --%>
      <div class="flex items-start justify-between gap-4 mb-6">
        <div class="min-w-0">
          <h1 class="text-2xl font-bold text-base-content truncate">
            {@post.metadata.title || gettext("Untitled post")}
          </h1>
          <div class="flex items-center gap-2 mt-1">
            <span class={"badge #{version_status_badge_class(@post.metadata[:status] || "draft")}"}>
              {@post.metadata[:status] || "draft"}
            </span>
            <span class="text-sm text-base-content/60">
              {gettext("Slug")}: <code class="font-mono">{@post.slug}</code>
            </span>
          </div>
        </div>

        <div class="flex gap-2 shrink-0">
          <.pk_link
            navigate={"/admin/publishing/#{@group_slug}/#{@post_uuid}/edit"}
            class="btn btn-primary btn-sm"
          >
            <span class="hero-pencil-square w-4 h-4" />{gettext("Edit")}
          </.pk_link>
          <.pk_link
            navigate={"/admin/publishing/#{@group_slug}/#{@post_uuid}/preview"}
            class="btn btn-ghost btn-sm"
          >
            <span class="hero-eye w-4 h-4" />{gettext("Preview")}
          </.pk_link>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <%!-- Versions card --%>
        <div class="card bg-base-100 border border-base-200 shadow-sm">
          <div class="card-body p-4">
            <h2 class="card-title text-base">{gettext("Versions")}</h2>
            <div class="space-y-2 mt-2">
              <%= for version <- @post.available_versions do %>
                <% status = Map.get(@post.version_statuses || %{}, version, "draft") %>
                <% date = Map.get(@post.version_dates || %{}, version) %>
                <.pk_link
                  navigate={"/admin/publishing/#{@group_slug}/#{@post_uuid}/edit?v=#{version}"}
                  class="flex items-center justify-between p-2 rounded-lg hover:bg-base-200 transition-colors"
                >
                  <div class="flex items-center gap-2">
                    <span class="font-mono text-sm">v{version}</span>
                    <span class={"badge badge-xs #{version_status_badge_class(status)}"}>
                      {status}
                    </span>
                  </div>
                  <%= if date do %>
                    <span class="text-xs text-base-content/50">{date}</span>
                  <% end %>
                </.pk_link>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Languages card --%>
        <div class="card bg-base-100 border border-base-200 shadow-sm">
          <div class="card-body p-4">
            <h2 class="card-title text-base">{gettext("Languages")}</h2>
            <div class="flex flex-wrap gap-2 mt-2">
              <%= for lang <- @post.available_languages do %>
                <% status = Map.get(@post.language_statuses || %{}, lang) %>
                <% is_primary = lang == @post.primary_language %>
                <.pk_link
                  navigate={"/admin/publishing/#{@group_slug}/#{@post_uuid}/edit?lang=#{lang}"}
                  class={
                    if is_primary,
                      do:
                        "flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg transition-colors bg-primary/10 border border-primary/20 hover:bg-primary/20",
                      else:
                        "flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg transition-colors bg-base-200 hover:bg-base-300"
                  }
                >
                  <span class={"rounded-full inline-block w-2 h-2 #{language_status_color(status)}"} />
                  <span class="text-sm font-medium">{lang}</span>
                  <%= if is_primary do %>
                    <span class="text-xs text-primary/70">{gettext("Primary")}</span>
                  <% end %>
                </.pk_link>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Metadata card --%>
        <div class="card bg-base-100 border border-base-200 shadow-sm">
          <div class="card-body p-4">
            <h2 class="card-title text-base">{gettext("Details")}</h2>
            <dl class="space-y-2 mt-2 text-sm">
              <div class="flex justify-between">
                <dt class="text-base-content/60">{gettext("Mode")}</dt>
                <dd class="font-medium">{@post.mode}</dd>
              </div>
              <%= if @post[:date] do %>
                <div class="flex justify-between">
                  <dt class="text-base-content/60">{gettext("Date")}</dt>
                  <dd class="font-medium font-mono">{Date.to_iso8601(@post.date)}</dd>
                </div>
              <% end %>
              <div class="flex justify-between">
                <dt class="text-base-content/60">{gettext("Primary Language")}</dt>
                <dd class="font-medium">{@post.primary_language}</dd>
              </div>
              <%= if @post.metadata[:description] do %>
                <div>
                  <dt class="text-base-content/60 mb-1">{gettext("Description")}</dt>
                  <dd class="text-base-content/80">{@post.metadata.description}</dd>
                </div>
              <% end %>
            </dl>
          </div>
        </div>

        <%!-- Future stats placeholder --%>
        <div class="card bg-base-100 border border-base-200 shadow-sm">
          <div class="card-body p-4">
            <h2 class="card-title text-base">{gettext("Stats")}</h2>
            <p class="text-sm text-base-content/50 mt-2">
              {gettext("Post analytics will appear here.")}
            </p>
          </div>
        </div>
      </div>
    </div>
  <% end %>
</PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
