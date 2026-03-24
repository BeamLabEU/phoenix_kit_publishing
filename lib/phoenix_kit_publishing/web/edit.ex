defmodule PhoenixKit.Modules.Publishing.Web.Edit do
  @moduledoc """
  LiveView for editing publishing group metadata such as display name and slug.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias Phoenix.Component
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(%{"group" => group_slug} = _params, _session, socket) do
    case find_group(group_slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("The requested group could not be found."))
         |> push_navigate(to: Routes.path("/admin/publishing"))}

      group ->
        form =
          Component.to_form(%{"name" => group["name"], "slug" => group["slug"]}, as: :group)

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

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("validate", %{"group" => params}, socket) do
    {:noreply, assign(socket, :form, Component.to_form(params, as: :group))}
  end

  def handle_event("save", %{"group" => params}, socket) do
    case Publishing.update_group(socket.assigns.group["slug"], params) do
      {:ok, updated_group} ->
        # Broadcast group updated for live dashboard updates
        PublishingPubSub.broadcast_group_updated(updated_group)

        updated_form =
          Component.to_form(
            %{"name" => updated_group["name"], "slug" => updated_group["slug"]},
            as: :group
          )

        {:noreply,
         socket
         |> assign(:group, updated_group)
         |> assign(:form, updated_form)
         |> put_flash(:info, gettext("Group updated"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{updated_group["slug"]}"))}

      {:error, :already_exists} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Another group already uses that slug."))
         |> assign(:form, Component.to_form(params, as: :group))}

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

      {:error, :destination_exists} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Another group already uses that slug."))
         |> assign(:form, Component.to_form(params, as: :group))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Failed to update group: %{reason}", reason: inspect(reason))
         )
         |> assign(:form, Component.to_form(params, as: :group))}
    end
  rescue
    e ->
      Logger.error("[Publishing.Edit] Group save failed: #{Exception.message(e)}")
      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/publishing"))}
  end

  defp find_group(slug) do
    Publishing.list_groups()
    |> Enum.find(&(&1["slug"] == slug))
  end

  def render(assigns) do
    ~H"""
<PhoenixKitWeb.Components.LayoutWrapper.app_layout
  flash={@flash}
  phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
  page_title={@page_title}
  current_path={@current_path}
  project_title={@project_title}
  current_locale={@current_locale}
>
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
                    {gettext("Slug-based")} · {gettext(
                      "Semantic URLs ideal for evergreen content."
                    )}
                  <% _ -> %>
                    {gettext("Timestamp-based")} · {gettext(
                      "Chronological URLs ideal for news and updates."
                    )}
                <% end %>
              </p>
            </div>

            <div class="flex flex-wrap gap-3 justify-end">
              <button type="submit" class="btn btn-primary btn-sm">
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
</PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
