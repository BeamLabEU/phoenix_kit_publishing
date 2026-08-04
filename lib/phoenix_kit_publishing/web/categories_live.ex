defmodule PhoenixKit.Modules.Publishing.Web.CategoriesLive do
  @moduledoc """
  Admin management for a group's category taxonomy (WordPress-parity),
  in the house folder-tree style (catalogue/entities patterns): a
  full-width indented tree table with handle-only drag reorder among
  siblings (SortableGrid), kebab row menus, a "Move to…" dialog for
  re-parenting (depth-indented picker, self + descendants excluded),
  and a modal add/edit form. Routed at
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
         |> assign(:form_open, false)
         |> assign(:move, nil)
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

  # ===========================================================================
  # Form (modal)
  # ===========================================================================

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:form, blank_form())
     |> assign(:form_open, true)
     |> assign(:move, nil)
     |> refresh_parent_options()}
  end

  def handle_event("new_child", %{"uuid" => parent_uuid}, socket) do
    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:form, blank_form(parent_uuid))
     |> assign(:form_open, true)
     |> assign(:move, nil)
     |> refresh_parent_options()}
  end

  def handle_event("edit", %{"uuid" => uuid}, socket) do
    case get_group_category(socket, uuid) do
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
         |> assign(:form_open, true)
         |> assign(:move, nil)
         |> refresh_parent_options()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Category not found")) |> reload_tree()}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, close_form(socket)}
  end

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
         |> close_form()
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

  # ===========================================================================
  # Move to… (re-parent dialog)
  # ===========================================================================

  def handle_event("open_move", %{"uuid" => uuid}, socket) do
    case get_group_category(socket, uuid) do
      {:ok, category} ->
        excluded = Categories.subtree_uuids(socket.assigns.group_slug, uuid)

        options =
          [{gettext("None (top level)"), ""}] ++
            (socket.assigns.tree
             |> Enum.reject(fn {node, _depth} -> MapSet.member?(excluded, node.uuid) end)
             |> Enum.map(fn {node, depth} ->
               {String.duplicate("— ", depth) <> node.name, node.uuid}
             end))

        {:noreply,
         socket
         |> assign(:form_open, false)
         |> assign(:editing, nil)
         |> assign(:move, %{
           uuid: uuid,
           name: category.name,
           parent_uuid: category.parent_uuid || "",
           options: options
         })}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Category not found")) |> reload_tree()}
    end
  end

  def handle_event("cancel_move", _params, socket) do
    {:noreply, assign(socket, :move, nil)}
  end

  def handle_event("confirm_move", %{"move" => %{"parent_uuid" => parent_uuid}}, socket) do
    case socket.assigns.move do
      # The select is pre-filled with the current parent, so submitting the
      # dialog untouched must do nothing. Without this, moving to the parent a
      # row already has appends it at the end of its own sibling group — a
      # silent reorder from one careless click on the DEFAULT state.
      %{parent_uuid: current} when current == parent_uuid ->
        {:noreply, assign(socket, :move, nil)}

      %{uuid: uuid} ->
        opts = [actor_uuid: Shared.actor_uuid_from_socket(socket)]

        case Categories.move_category(uuid, parent_uuid, opts) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Category moved"))
             |> assign(:move, nil)
             |> reload_tree()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, put_flash(socket, :error, changeset_error_message(changeset))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, parent_error_message(reason))}
        end

      nil ->
        {:noreply, socket}
    end
  end

  # Defensive: malformed payloads from a misbehaving client.
  def handle_event("confirm_move", _params, socket) do
    {:noreply, socket}
  end

  # ===========================================================================
  # Drag reorder (SortableGrid)
  # ===========================================================================

  def handle_event("reorder_categories", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    moved_id = params["moved_id"]
    opts = [actor_uuid: Shared.actor_uuid_from_socket(socket)]

    case Categories.reorder_categories(socket.assigns.group_slug, ordered_ids, opts) do
      # changed == 0 means nothing moved — most often a drop ACROSS parents,
      # which the context discards by design. Flashing green there tells the
      # user a reparent happened while the row snaps back.
      {:ok, 0} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Order unchanged — use “Move to…” to change a parent."))
         |> reload_tree()}

      {:ok, _changed} ->
        {:noreply,
         socket
         |> reload_tree()
         |> flash_reorder(moved_id, :ok)}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to save the new order"))
         |> reload_tree()
         |> flash_reorder(moved_id, :error)}
    end
  end

  # Defensive: malformed payloads from a misbehaving client.
  def handle_event("reorder_categories", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Failed to save the new order"))}
  end

  # ===========================================================================
  # Delete
  # ===========================================================================

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with {:ok, _category} <- get_group_category(socket, uuid),
         {:ok, _} <-
           Categories.delete_category(uuid, actor_uuid: Shared.actor_uuid_from_socket(socket)) do
      socket = if socket.assigns.editing == uuid, do: close_form(socket), else: socket

      socket =
        case socket.assigns.move do
          %{uuid: ^uuid} -> assign(socket, :move, nil)
          _ -> socket
        end

      {:noreply,
       socket
       |> put_flash(:info, gettext("Category deleted — its children moved to the top level"))
       |> reload_tree()}
    else
      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't delete this category."))}
    end
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[Publishing.CategoriesLive] unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp close_form(socket) do
    socket
    |> assign(:editing, nil)
    |> assign(:form, blank_form())
    |> assign(:form_open, false)
    |> refresh_parent_options()
  end

  # Page-scope guard: every uuid arriving from the client must belong to
  # THIS group — a crafted event can't touch another group's taxonomy.
  defp get_group_category(socket, uuid) do
    group_uuid = socket.assigns.group["uuid"]

    case Categories.get_category(uuid) do
      {:ok, %{group_uuid: ^group_uuid} = category} -> {:ok, category}
      {:ok, _foreign} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp flash_reorder(socket, moved_id, status) when is_binary(moved_id) do
    push_event(socket, "sortable:flash", %{uuid: moved_id, status: to_string(status)})
  end

  # nil (no moved row reported) or a crafted non-binary value — no flash.
  defp flash_reorder(socket, _moved_id, _status), do: socket

  defp blank_form(parent_uuid \\ "") do
    to_form(
      %{
        "name" => "",
        "slug" => "",
        "parent_uuid" => parent_uuid,
        "description" => "",
        "position" => "0"
      },
      as: :category
    )
  end

  defp reload_tree(socket) do
    tree = Categories.list_tree(socket.assigns.group_slug)
    counts = Categories.published_post_counts(socket.assigns.group_slug)

    # Drag handles only show where dragging can do something: >1 sibling.
    sibling_counts =
      tree
      |> Enum.map(fn {category, _depth} -> category.parent_uuid end)
      |> Enum.frequencies()

    # Categories with children get a folder icon.
    parents_with_children =
      tree
      |> Enum.map(fn {category, _depth} -> category.parent_uuid end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    socket
    |> assign(:tree, tree)
    |> assign(:counts, counts)
    |> assign(:sibling_counts, sibling_counts)
    |> assign(:parents_with_children, parents_with_children)
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
      >
        <:actions>
          <button type="button" class="btn btn-primary btn-sm" phx-click="new">
            <.icon name="hero-plus" class="w-4 h-4" />
            {gettext("New category")}
          </button>
        </:actions>
      </.admin_page_header>

      <div class="card bg-base-100 shadow-sm border border-base-200">
        <div class="card-body p-4">
          <%= if @tree == [] do %>
            <div class="text-center py-8 text-base-content/60">
              <.icon name="hero-tag" class="w-8 h-8 mx-auto mb-2 opacity-40" />
              <p class="text-sm">
                {gettext("No categories yet — create the first one.")}
              </p>
              <button type="button" class="btn btn-primary btn-sm mt-4" phx-click="new">
                <.icon name="hero-plus" class="w-4 h-4" />
                {gettext("New category")}
              </button>
            </div>
          <% else %>
            <table class="table table-sm">
              <thead>
                <tr>
                  <.drag_handle_header_cell />
                  <th>{gettext("Name")}</th>
                  <th>{gettext("Slug")}</th>
                  <th class="text-right">{gettext("Posts")}</th>
                  <th class="w-px"></th>
                </tr>
              </thead>
              <.sortable_tbody
                id="categories-tree"
                event="reorder_categories"
                enabled={length(@tree) > 1}
              >
                <.sortable_row :for={{category, depth} <- @tree} item_id={category.uuid}>
                  <%= if Map.get(@sibling_counts, category.parent_uuid, 0) > 1 do %>
                    <.drag_handle_cell title={gettext("Drag to reorder (among siblings)")} />
                  <% else %>
                    <td class="w-8"></td>
                  <% end %>
                  <td>
                    <div
                      class="flex items-center gap-2"
                      style={depth > 0 && "padding-left: #{depth * 1.25}rem"}
                    >
                      <%= if MapSet.member?(@parents_with_children, category.uuid) do %>
                        <.icon name="hero-folder" class="w-4 h-4 shrink-0 text-warning" />
                      <% else %>
                        <.icon name="hero-tag" class="w-4 h-4 shrink-0 text-base-content/40" />
                      <% end %>
                      <span class="font-medium">{category.name}</span>
                    </div>
                  </td>
                  <td class="font-mono text-xs text-base-content/60">{category.slug}</td>
                  <td class="text-right tabular-nums">{Map.get(@counts, category.uuid, 0)}</td>
                  <td class="text-right">
                    <.table_row_menu mode="auto" id={"cat-menu-#{category.uuid}"}>
                      <.table_row_menu_button
                        phx-click="edit"
                        phx-value-uuid={category.uuid}
                        icon="hero-pencil-square"
                        label={gettext("Edit")}
                      />
                      <.table_row_menu_button
                        phx-click="new_child"
                        phx-value-uuid={category.uuid}
                        icon="hero-plus"
                        label={gettext("New subcategory")}
                      />
                      <.table_row_menu_button
                        phx-click="open_move"
                        phx-value-uuid={category.uuid}
                        icon="hero-folder-arrow-down"
                        label={gettext("Move to…")}
                        variant="secondary"
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="delete"
                        phx-value-uuid={category.uuid}
                        phx-disable-with={gettext("Deleting…")}
                        icon="hero-trash"
                        label={gettext("Delete")}
                        variant="error"
                        data-confirm={
                          gettext(
                            "Delete “%{name}”? Its subcategories move to the top level and posts lose this category.",
                            name: category.name
                          )
                        }
                      />
                    </.table_row_menu>
                  </td>
                </.sortable_row>
              </.sortable_tbody>
            </table>
          <% end %>
        </div>
      </div>

      <%!-- Add / edit form (modal) --%>
      <.modal show={@form_open} on_close="cancel_form" id="category-form-modal">
        <:title>
          <%= if @editing do %>
            {gettext("Edit category")}
          <% else %>
            {gettext("New category")}
          <% end %>
        </:title>
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
          <.select field={@form[:parent_uuid]} label={gettext("Parent")} options={@parent_options} />
          <.input field={@form[:position]} type="number" label={gettext("Position")} />
          <.textarea field={@form[:description]} label={gettext("Description")} rows="2" />
          <div class="flex items-center justify-end gap-2 pt-2">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_form">
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              phx-disable-with={gettext("Saving…")}
            >
              <%= if @editing do %>
                {gettext("Save")}
              <% else %>
                {gettext("Create")}
              <% end %>
            </button>
          </div>
        </.form>
      </.modal>

      <%!-- Move to… (re-parent dialog) --%>
      <.modal show={@move != nil} on_close="cancel_move" id="category-move-modal">
        <:title>
          <.icon name="hero-folder-arrow-down" class="w-5 h-5" />
          {gettext("Move “%{name}”", name: @move && @move.name)}
        </:title>
        <.form for={to_form(%{}, as: :move)} id="category-move-form" phx-submit="confirm_move">
          <.select
            name="move[parent_uuid]"
            value={(@move && @move.parent_uuid) || ""}
            label={gettext("New parent")}
            options={(@move && @move.options) || []}
          />
          <div class="flex items-center justify-end gap-2 pt-4">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_move">
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              phx-disable-with={gettext("Moving…")}
            >
              {gettext("Move")}
            </button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end
end
