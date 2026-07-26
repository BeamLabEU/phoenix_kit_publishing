defmodule PhoenixKit.Modules.Publishing.Web.CategoriesLive do
  @moduledoc """
  Admin management for a group's category taxonomy (WordPress-parity):
  an indented tree table (name, slug, published-post count) beside an
  add/edit form with a parent picker. Routed at
  `/admin/publishing/categories/:group`.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitPublishing.Gettext

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"group" => group_slug}, _session, socket) do
    case Publishing.get_group(group_slug) do
      {:ok, group} ->
        {:ok,
         socket
         |> assign(:project_title, Settings.get_project_title())
         |> assign(:page_title, gettext("Categories"))
         |> assign(:current_path, Routes.path("/admin/publishing/categories/#{group_slug}"))
         |> assign(:group, group)
         |> assign(:group_slug, group_slug)
         |> assign(:editing, nil)
         |> assign(:form, blank_form())
         |> reload_tree()}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("The requested group could not be found."))
         |> push_navigate(to: Routes.path("/admin/publishing"))}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"category" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :category))}
  end

  def handle_event("save", %{"category" => params}, socket) do
    attrs =
      params
      |> Map.take(["name", "slug", "parent_uuid", "description", "position"])
      # A cleared position input arrives as "" — Ecto would cast it to nil and
      # the DB rejects NULL; treat blank as the 0 default instead.
      |> Map.update("position", "0", fn
        "" -> "0"
        value -> value
      end)

    opts = [actor_uuid: Shared.actor_uuid_from_socket(socket)]

    result =
      case socket.assigns.editing do
        nil -> Categories.create_category(socket.assigns.group_slug, attrs, opts)
        uuid -> Categories.update_category(uuid, attrs, opts)
      end

    case result do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           if(socket.assigns.editing,
             do: gettext("Category updated"),
             else: gettext("Category created")
           )
         )
         |> assign(:editing, nil)
         |> assign(:form, blank_form())
         |> reload_tree()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, changeset_error_message(changeset))
         |> assign(:form, to_form(changeset, as: :category))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, parent_error_message(reason))
         |> assign(:form, to_form(params, as: :category))}
    end
  end

  def handle_event("edit", %{"uuid" => uuid}, socket) do
    case Categories.get_category(uuid) do
      {:ok, category} ->
        params = %{
          "name" => category.name,
          "slug" => category.slug,
          "parent_uuid" => category.parent_uuid || "",
          "description" => category.description || "",
          "position" => to_string(category.position || 0)
        }

        {:noreply,
         socket
         |> assign(:editing, category.uuid)
         |> assign(:form, to_form(params, as: :category))
         |> refresh_parent_options()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Category not found")) |> reload_tree()}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket |> assign(:editing, nil) |> assign(:form, blank_form()) |> refresh_parent_options()}
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Categories.delete_category(uuid, actor_uuid: Shared.actor_uuid_from_socket(socket)) do
      {:ok, _} ->
        socket = if socket.assigns.editing == uuid, do: reset_form(socket), else: socket

        {:noreply,
         socket
         |> put_flash(:info, gettext("Category deleted — its children moved to the top level"))
         |> reload_tree()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't delete this category."))}
    end
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[Publishing.CategoriesLive] unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp reset_form(socket) do
    socket |> assign(:editing, nil) |> assign(:form, blank_form()) |> refresh_parent_options()
  end

  defp blank_form do
    to_form(
      %{
        "name" => "",
        "slug" => "",
        "parent_uuid" => "",
        "description" => "",
        "position" => "0"
      },
      as: :category
    )
  end

  defp reload_tree(socket) do
    tree = Categories.list_tree(socket.assigns.group_slug)
    counts = Categories.published_post_counts(socket.assigns.group_slug)

    socket
    |> assign(:tree, tree)
    |> assign(:counts, counts)
    |> refresh_parent_options()
  end

  # Precomputed on tree/editing changes — parent_options walks the subtree in
  # the DB, which must not run per render (validate fires per keystroke).
  defp refresh_parent_options(socket) do
    assign(
      socket,
      :parent_options,
      parent_options(socket.assigns.tree, socket.assigns.group_slug, socket.assigns[:editing])
    )
  end

  # Parent options: every category except (when editing) the category itself
  # and its descendants — the context re-checks, this just keeps invalid picks
  # out of the select.
  defp parent_options(tree, group_slug, editing) do
    excluded =
      case editing do
        nil -> MapSet.new()
        uuid -> Categories.subtree_uuids(group_slug, uuid)
      end

    options =
      tree
      |> Enum.reject(fn {category, _depth} -> MapSet.member?(excluded, category.uuid) end)
      |> Enum.map(fn {category, depth} ->
        {String.duplicate("— ", depth) <> category.name, category.uuid}
      end)

    [{gettext("None (top level)"), ""} | options]
  end

  defp changeset_error_message(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :slug) || Keyword.get(errors, :group_uuid) do
      {_, _} -> gettext("That slug is already used in this group.")
      _ -> gettext("Couldn't save this category — check the fields and try again.")
    end
  end

  defp parent_error_message(:category_cycle),
    do: gettext("A category can't be moved under one of its own subcategories.")

  defp parent_error_message(:parent_wrong_group),
    do: gettext("The parent must belong to the same group.")

  defp parent_error_message(_), do: gettext("Couldn't save this category.")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container flex flex-col mx-auto px-4 py-6">
      <.admin_page_header
        back={Routes.path("/admin/publishing/#{@group_slug}")}
        title={gettext("Categories")}
        subtitle={@group["name"]}
      />

      <div class="grid gap-6 lg:grid-cols-[1fr_20rem]">
        <%!-- Tree table --%>
        <div class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body p-4">
            <%= if @tree == [] do %>
              <div class="text-center py-8 text-base-content/60">
                <.icon name="hero-tag" class="w-8 h-8 mx-auto mb-2 opacity-40" />
                <p class="text-sm">
                  {gettext("No categories yet — create the first one on the right.")}
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>{gettext("Name")}</th>
                    <th>{gettext("Slug")}</th>
                    <th class="text-right">{gettext("Posts")}</th>
                    <th class="w-px"></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{category, depth} <- @tree} class={@editing == category.uuid && "bg-base-200/60"}>
                    <td>
                      <span class="text-base-content/40">{String.duplicate("— ", depth)}</span>{category.name}
                    </td>
                    <td class="font-mono text-xs text-base-content/60">{category.slug}</td>
                    <td class="text-right tabular-nums">{Map.get(@counts, category.uuid, 0)}</td>
                    <td class="whitespace-nowrap text-right">
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs"
                        phx-click="edit"
                        phx-value-uuid={category.uuid}
                      >
                        {gettext("Edit")}
                      </button>
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="delete"
                        phx-value-uuid={category.uuid}
                        data-confirm={
                          gettext(
                            "Delete “%{name}”? Its subcategories move to the top level and posts lose this category.",
                            name: category.name
                          )
                        }
                      >
                        {gettext("Delete")}
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </div>
        </div>

        <%!-- Add / edit form --%>
        <div class="card bg-base-100 shadow-sm border border-base-200 h-fit">
          <div class="card-body p-4 space-y-4">
            <h2 class="text-sm font-semibold">
              <%= if @editing do %>
                {gettext("Edit category")}
              <% else %>
                {gettext("New category")}
              <% end %>
            </h2>
            <.form
              for={@form}
              id="category-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-3"
            >
              <.input field={@form[:name]} label={gettext("Name")} required />
              <.input
                field={@form[:slug]}
                label={gettext("Slug")}
                placeholder={gettext("auto from the name")}
              />
              <.select
                field={@form[:parent_uuid]}
                label={gettext("Parent")}
                options={@parent_options}
              />
              <.input field={@form[:position]} type="number" label={gettext("Position")} />
              <.textarea
                field={@form[:description]}
                label={gettext("Description")}
                rows="2"
              />
              <div class="flex items-center gap-2 pt-1">
                <button type="submit" class="btn btn-primary btn-sm">
                  <%= if @editing do %>
                    {gettext("Save")}
                  <% else %>
                    {gettext("Create")}
                  <% end %>
                </button>
                <button
                  :if={@editing}
                  type="button"
                  class="btn btn-ghost btn-sm"
                  phx-click="cancel_edit"
                >
                  {gettext("Cancel")}
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
