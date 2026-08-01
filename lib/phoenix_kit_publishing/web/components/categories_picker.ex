defmodule PhoenixKit.Modules.Publishing.Web.Components.CategoriesPicker do
  @moduledoc """
  The post editor's category field: a typeahead plus a row of chips.

  Categories are **version-level** — see `PublishingVersion.get_category_uuids/1`.
  A post's subject can change between versions, and an old version keeps the
  filing it was published under. So this component doesn't persist anything
  itself: it edits `form["category_uuids"]` through the parent LiveView and
  rides the ordinary save, exactly like `featured` or the SEO fields. That
  also means a brand-new post can be filed before its first save, which the
  old post-level version couldn't do — it had nothing to attach a row to and
  showed a "save the post first" notice instead.

  The typeahead replaced a checkbox tree. A tree is the wrong shape here:
  it grows without bound, it forces the writer to scan for the one entry
  they already have in mind, and indentation is a poor way to show which of
  forty boxes are ticked. Typing narrows; the chips show the answer.

  Hierarchy still matters for picking — two categories can share a name
  under different parents — so each suggestion carries its parent chain as
  a sublabel rather than as indentation.

  Required assigns: `:id`, `:group_slug`, `:selected` (list of uuids),
  `:language`, `:disabled`. Changes are announced to the parent LiveView as
  `{:categories_changed, uuids}` — the parent owns the form, so it has to be
  the one to write to it, mark the post dirty and let the collaborative
  broadcast go out.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPublishing.Gettext

  import PhoenixKitWeb.Components.Core.SearchPicker

  alias PhoenixKit.Modules.Publishing.Categories
  alias PhoenixKit.Modules.Publishing.PublishingCategory
  alias PhoenixKit.Utils.Routes

  # Deliberately more than a writer will ever have on one post: the dropdown
  # is for finding one entry, not for browsing the whole taxonomy.
  @max_results 8

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # A stateful component's update/2 runs on EVERY parent render, and the
    # parent here is the post editor — which re-renders on each keystroke.
    # Reading the tree unconditionally put a two-table join on that path.
    # The tree is re-read where it can actually have changed: on search
    # (see the handler) and when the component is pointed at another group.
    tree =
      case {socket.assigns[:tree], socket.assigns[:tree_group]} do
        {cached, group} when is_list(cached) and group == assigns.group_slug -> cached
        _ -> Categories.list_tree(assigns.group_slug)
      end

    {:ok,
     socket
     |> assign(:tree, tree)
     |> assign(:tree_group, assigns.group_slug)
     |> assign(:selected_categories, resolve(tree, socket.assigns.selected))}
  end

  @impl true
  def handle_event("category_search", %{"q" => query}, socket) do
    # Re-read rather than search the tree loaded at mount. Making a category
    # happens in another tab, and the whole point of sending people there is
    # that they come back and use it — if this searched a stale list, the new
    # category wouldn't be findable and the trip would look like it failed.
    # One small query per search, on an admin screen.
    tree = Categories.list_tree(socket.assigns.group_slug)

    results =
      tree
      |> matching(query, socket.assigns.selected)
      |> Enum.take(@max_results)

    {:noreply,
     socket
     |> assign(:tree, tree)
     |> assign(:selected_categories, resolve(tree, socket.assigns.selected))
     |> push_event("category_results", %{
       q: query,
       results: results,
       has_more: false
     })}
  end

  def handle_event("category_pick", %{"uuid" => uuid}, socket) do
    %{selected: selected, disabled: disabled} = socket.assigns

    unless disabled or uuid in selected do
      send(self(), {:categories_changed, selected ++ [uuid]})
    end

    # Always confirm, even when the pick was a no-op, or the hook leaves the
    # typed query sitting in the input.
    {:noreply, push_event(socket, "category_staged", %{})}
  end

  def handle_event("category_remove", %{"uuid" => uuid}, socket) do
    %{selected: selected, disabled: disabled} = socket.assigns

    unless disabled do
      send(self(), {:categories_changed, Enum.reject(selected, &(&1 == uuid))})
    end

    {:noreply, socket}
  end

  # Rows for the dropdown. Already-selected categories are filtered out —
  # picking one twice does nothing, so offering it is just noise.
  defp matching(tree, query, selected) do
    needle = query |> to_string() |> String.trim() |> String.downcase()

    tree
    |> Enum.reject(fn {category, _depth} -> category.uuid in selected end)
    |> Enum.filter(fn {category, _depth} ->
      needle == "" or String.contains?(String.downcase(category.name), needle)
    end)
    |> Enum.map(fn {category, _depth} ->
      %{
        kind: "category",
        uuid: category.uuid,
        label: category.name,
        sublabel: parent_path(tree, category),
        icon: "hero-folder"
      }
    end)
  end

  # "Announcements" for a child of Announcements, "" for a root. Two
  # categories may legitimately share a name under different parents, so
  # without this the dropdown offers two identical-looking rows.
  defp parent_path(tree, category) do
    by_uuid = Map.new(tree, fn {c, _depth} -> {c.uuid, c} end)

    category
    |> ancestors(by_uuid, [])
    |> Enum.map_join(" / ", & &1.name)
  end

  defp ancestors(%{parent_uuid: nil}, _by_uuid, acc), do: acc

  defp ancestors(%{parent_uuid: parent_uuid}, by_uuid, acc) do
    case Map.get(by_uuid, parent_uuid) do
      # Cycle or a parent deleted mid-read: stop rather than loop.
      nil -> acc
      parent -> if parent in acc, do: acc, else: ancestors(parent, by_uuid, [parent | acc])
    end
  end

  defp resolve(tree, selected) do
    by_uuid = Map.new(tree, fn {c, _depth} -> {c.uuid, c} end)

    # Ordered by the writer's selection, not by tree position — chips should
    # stay put when a category is added, rather than resorting under the
    # cursor. Unknown uuids (category deleted since) drop out.
    selected
    |> Enum.map(&Map.get(by_uuid, &1))
    |> Enum.reject(&is_nil/1)
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

        <div :if={@selected_categories != []} class="mb-2 flex flex-wrap gap-1.5">
          <span
            :for={category <- @selected_categories}
            class="badge badge-soft badge-primary gap-1 py-2.5"
          >
            {PublishingCategory.translated_name(category, @language)}
            <%!-- Two things this button has to say, neither of them free.

                  `cursor-pointer`: Tailwind v4's preflight stopped giving
                  buttons a pointer, so a bare <button> reads as decoration.
                  daisyUI's `btn` sets it, which is why this only bites
                  buttons styled by hand.

                  The spinner: removing a chip is a server round trip, and
                  until it answers the x looks like it did nothing. LiveView
                  puts `phx-click-loading` on the clicked element for exactly
                  the in-flight window, so the glyph swaps for a spinner and
                  further clicks are ignored — no double-fire, and the click
                  is visibly acknowledged even when the connection is slow.
                  On a fast link this is a blink; on a bad one it's the
                  difference between "it worked" and clicking again. --%>
            <button
              :if={not @disabled}
              type="button"
              class="cursor-pointer opacity-60 hover:opacity-100 [&.phx-click-loading]:pointer-events-none [&.phx-click-loading]:opacity-100"
              aria-label={gettext("Remove %{name}", name: category.name)}
              phx-click="category_remove"
              phx-value-uuid={category.uuid}
              phx-target={@myself}
            >
              <span class="hero-x-mark-mini h-3.5 w-3.5 [.phx-click-loading_&]:hidden"></span>
              <span class="hidden loading loading-spinner loading-xs [.phx-click-loading_&]:inline-block">
              </span>
            </button>
          </span>
        </div>

        <.search_picker
          :if={not @disabled}
          id={"#{@id}-search"}
          dropdown_id={"#{@id}-dropdown"}
          {%{"phx-target" => @myself}}
          search_on_focus
          direction="up"
          search_event="category_search"
          results_event="category_results"
          pick_event="category_pick"
          staged_event="category_staged"
          placeholder={gettext("Search categories…")}
          class="input input-bordered input-sm w-full"
          searching_label={gettext("Searching…")}
          no_matches_label={gettext("No matching categories")}
        />

        <%!-- Deliberately a link to the management page rather than a
             "create" row in the dropdown. A category isn't just a name: its
             slug becomes a public archive URL, and it has a parent, a
             position and translations. A search box can only supply the
             name, so inline creation would file everything flat at the root
             and leave someone to clean up a live URL afterwards.

             New tab, because the writer is mid-post with unsaved changes —
             navigating away to make a category is the one thing this must
             not cost them. A real anchor, so cmd-click and middle-click
             behave, and it works with no JS at all. --%>
        <.link
          :if={not @disabled}
          href={Routes.path("/admin/publishing/categories/#{@group_slug}")}
          target="_blank"
          rel="noopener"
          class="link link-hover text-xs text-base-content/60 mt-1 inline-flex items-center gap-1"
        >
          <span class="hero-plus-mini h-3 w-3"></span>
          {gettext("New category")}
        </.link>

        <p :if={@selected_categories == [] and not @disabled} class="text-xs text-base-content/60 mt-1">
          {gettext("Saved with the version, so each version keeps its own filing.")}
        </p>
      </div>
    </div>
    """
  end
end
