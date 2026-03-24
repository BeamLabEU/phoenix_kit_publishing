defmodule PhoenixKit.Modules.Publishing.Web.Preview do
  @moduledoc """
  Preview rendering for publishing posts.

  Shows the full public-facing interface with a preview banner,
  allowing editors to see exactly what visitors will see.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostRendering
  alias PhoenixKit.Modules.Publishing.Web.Controller.Translations
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.LanguageSwitcher

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"] || params["category"] || params["type"]

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Preview"))
      |> assign(:group_slug, group_slug)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> assign(
        :current_path,
        Routes.path("/admin/publishing/#{group_slug}/preview")
      )
      |> assign(:post, nil)
      |> assign(:html_content, nil)
      |> assign(:translations, [])
      |> assign(:breadcrumbs, [])
      |> assign(:version_dropdown, nil)
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"post_uuid" => post_uuid} = params, _uri, socket) do
    group_slug = socket.assigns.group_slug
    language = params["lang"]
    version = params["v"]

    case Publishing.read_post_by_uuid(post_uuid, language, version) do
      {:ok, post} ->
        case render_markdown_content(post.content) do
          {:ok, rendered_html} ->
            post = Map.put(post, :uuid, post_uuid)

            # Build the same data as the public controller
            canonical_language = post.language

            translations =
              Translations.build_translation_links(group_slug, post, canonical_language)

            breadcrumbs = PostRendering.build_breadcrumbs(group_slug, post, canonical_language)

            version_dropdown =
              PostRendering.build_version_dropdown(group_slug, post, canonical_language)

            {:noreply,
             socket
             |> assign(:post, post)
             |> assign(:group_slug, post.group)
             |> assign(:group_name, Publishing.group_name(post.group) || post.group)
             |> assign(:html_content, rendered_html)
             |> assign(:current_language, canonical_language)
             |> assign(:translations, translations)
             |> assign(:breadcrumbs, breadcrumbs)
             |> assign(:version_dropdown, version_dropdown)
             |> assign(:page_title, post.metadata.title || Constants.default_title())
             |> assign(:error, nil)}

          {:error, error_message} ->
            {:noreply,
             socket
             |> assign(:post, Map.put(post, :uuid, post_uuid))
             |> assign(:group_slug, post.group)
             |> assign(:group_name, Publishing.group_name(post.group) || post.group)
             |> assign(:html_content, nil)
             |> assign(:error, error_message)}
        end

      {:error, reason} ->
        Logger.warning("[Publishing.Preview] Preview failed for #{post_uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("No post specified"))
     |> push_navigate(to: Routes.path("/admin/publishing/#{socket.assigns.group_slug}"))}
  end

  @impl true
  def handle_event("back_to_editor", _params, socket) do
    post = socket.assigns[:post]
    group_slug = socket.assigns.group_slug

    destination =
      if post && post[:uuid] do
        Helpers.build_edit_url(group_slug, post,
          lang: post[:language],
          version: post[:version]
        )
      else
        Routes.path("/admin/publishing/#{group_slug}")
      end

    {:noreply, push_navigate(socket, to: destination)}
  end

  # Delegate to PublishingHTML helpers used in the template
  defdelegate has_publication_date?(post), to: PublishingHTML
  defdelegate format_post_date(post, group_slug), to: PublishingHTML

  @doc false
  def build_preview_translations(translations, post, group_slug) do
    post_uuid = post[:uuid]
    version = post[:version]

    Enum.map(translations, fn translation ->
      code = translation[:code] || translation.code
      query_params = %{"lang" => code}
      query_params = if version, do: Map.put(query_params, "v", version), else: query_params
      query = URI.encode_query(query_params)

      %{
        code: code,
        display_code: translation[:display_code] || code,
        name: translation[:name] || translation.name,
        flag: translation[:flag] || "",
        url: Routes.path("/admin/publishing/#{group_slug}/#{post_uuid}/preview?#{query}"),
        status: "published",
        exists: true
      }
    end)
  end

  defp render_markdown_content(content) when is_binary(content) do
    content
    |> Renderer.render_markdown()
    |> then(&{:ok, &1})
  rescue
    error ->
      Logger.error("[Publishing.Preview] Markdown rendering failed: #{inspect(error)}")
      {:error, gettext("Failed to render preview.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
  <div class="min-h-screen bg-base-100">
    <%!-- Preview Banner --%>
    <div class="bg-warning text-warning-content py-2 px-4 sticky top-0 z-50 shadow-lg">
      <div class="container mx-auto flex items-center justify-between">
        <div class="flex items-center gap-3">
          <.icon name="hero-eye" class="w-5 h-5" />
          <span class="font-semibold text-sm">{gettext("Preview Mode")}</span>
          <span class="text-xs opacity-80">
            — {gettext("This is how the post will appear to visitors")}
          </span>
        </div>
        <div class="flex gap-2">
          <button type="button" class="btn btn-sm btn-ghost" phx-click="back_to_editor">
            <.icon name="hero-pencil-square" class="w-4 h-4 mr-1" />
            {gettext("Back to Editor")}
          </button>
        </div>
      </div>
    </div>

    <%!-- Content --%>
    <%= if @error do %>
      <div class="container mx-auto px-4 py-12">
        <div class="alert alert-error">
          <.icon name="hero-exclamation-triangle" class="w-6 h-6" />
          <div>
            <h3 class="font-bold">{gettext("Preview Error")}</h3>
            <p class="text-sm">{@error}</p>
          </div>
        </div>
      </div>
    <% else %>
      <%= if @post && @html_content do %>
        <%!-- Public post interface --%>
        <article class="post-container max-w-4xl mx-auto px-6 py-8">
          <%!-- Breadcrumb Navigation (non-interactive in preview) --%>
          <div class="breadcrumbs text-sm mb-6">
            <ul>
              <%= for breadcrumb <- @breadcrumbs do %>
                <li>{breadcrumb.label}</li>
              <% end %>
            </ul>
          </div>

          <%!-- Post Header --%>
          <header class="mb-8 border-b pb-6">
            <%= if has_publication_date?(@post) do %>
              <div class="flex items-center gap-2 text-sm text-base-content/70">
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
            <% end %>
            <div class="flex flex-wrap items-center gap-4 mt-4">
              <%!-- Language Switcher (links to preview URLs) --%>
              <%= if length(@translations) > 1 do %>
                <.language_switcher
                  languages={build_preview_translations(@translations, @post, @group_slug)}
                  current_language={@current_language}
                  show_status={false}
                  size={:sm}
                />
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
                        <span class={"flex items-center justify-between #{if v.is_current, do: "active"}"}>
                          <span>v{v.version}</span>
                          <%= if v.is_live do %>
                            <span class="badge badge-success badge-xs h-auto">live</span>
                          <% end %>
                        </span>
                      </li>
                    <% end %>
                  </ul>
                </div>
              <% end %>
            </div>
            <h1 class="text-3xl font-bold mt-4">
              {@post.metadata.title || PhoenixKit.Modules.Publishing.Constants.default_title()}
            </h1>
          </header>

          <%!-- Post Content --%>
          <div class="prose prose-lg max-w-none">
            {raw(@html_content)}
          </div>

          <%!-- Post Footer --%>
          <footer class="mt-12 pt-6 border-t">
            <span class="btn btn-ghost btn-sm opacity-60 cursor-not-allowed">
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> {gettext("Back to %{group}",
                group: String.capitalize(@group_slug)
              )}
            </span>
          </footer>
        </article>
      <% else %>
        <div class="container mx-auto px-4 py-12">
          <div class="flex items-center justify-center">
            <span class="loading loading-spinner loading-lg"></span>
          </div>
        </div>
      <% end %>
    <% end %>
  </div>
    """
  end
end
