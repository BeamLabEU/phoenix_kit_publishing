defmodule PhoenixKit.Modules.Publishing.Web.Components.CategoriesPicker do
  @moduledoc """
  The post editor's category checkboxes (WordPress-style indented tree).

  Self-contained LiveComponent: loads the group's tree + the post's current
  set in `update/2`, and **persists immediately on toggle** via
  `Categories.replace_post_categories/3` — deliberately independent of the
  editor's save pipeline, so the fragile content-save path stays untouched
  and a category change can't be lost to an unsaved draft. For a NEW post
  (no uuid yet) it renders a "save first" hint instead of checkboxes.

  Required assigns: `:id`, `:group_slug`, `:post_uuid` (nil for new posts),
  `:actor_uuid` (nil ok), `:disabled` (read-only editor states).
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPublishing.Gettext

  alias PhoenixKit.Modules.Publishing.Categories

  @impl true
  def update(assigns, socket) do
    tree = Categories.list_tree(assigns.group_slug)

    selected =
      case assigns.post_uuid do
        nil -> MapSet.new()
        uuid -> MapSet.new(Categories.category_uuids_for_post(uuid))
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:tree, tree)
     |> assign(:selected, selected)}
  end

  @impl true
  def handle_event("toggle", %{"uuid" => uuid}, socket) do
    %{post_uuid: post_uuid, selected: selected} = socket.assigns

    if is_nil(post_uuid) or socket.assigns.disabled do
      {:noreply, socket}
    else
      next =
        if MapSet.member?(selected, uuid),
          do: MapSet.delete(selected, uuid),
          else: MapSet.put(selected, uuid)

      case Categories.replace_post_categories(post_uuid, MapSet.to_list(next),
             actor_uuid: socket.assigns.actor_uuid
           ) do
        {:ok, applied} ->
          {:noreply, assign(socket, :selected, MapSet.new(applied))}

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%!-- Stateful LC rule: the root tag must be static — the no-categories
        case renders this outer div empty. --%>
      <div :if={@tree != []}>
        <p class="label-text text-sm font-semibold text-base-content mb-1">
          {gettext("Categories")}
        </p>
      <%= if @post_uuid do %>
        <div class="max-h-48 space-y-0.5 overflow-y-auto rounded-lg border border-base-300 bg-base-200/30 p-2">
          <label
            :for={{category, depth} <- @tree}
            class="label cursor-pointer justify-start gap-2 py-0.5"
            style={"padding-left: #{depth * 1.25}rem"}
          >
            <input
              type="checkbox"
              class="checkbox checkbox-primary checkbox-xs"
              checked={MapSet.member?(@selected, category.uuid)}
              disabled={@disabled}
              phx-click="toggle"
              phx-value-uuid={category.uuid}
              phx-target={@myself}
            />
            <span class="label-text text-sm">{category.name}</span>
          </label>
        </div>
        <p class="text-xs text-base-content/60 mt-1">
          {gettext("Applied immediately — categories are shared by every version of the post.")}
        </p>
      <% else %>
        <p class="text-xs text-base-content/60 rounded-lg border border-dashed border-base-300 p-2">
          {gettext("Save the post first, then assign categories.")}
        </p>
      <% end %>
      </div>
    </div>
    """
  end
end
