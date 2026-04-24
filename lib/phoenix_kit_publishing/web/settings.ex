defmodule PhoenixKit.Modules.Publishing.Web.Settings do
  @moduledoc """
  Admin configuration for publishing groups.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # Settings keys
  @default_language_no_prefix_key "publishing_default_language_no_prefix"
  @memory_cache_key "publishing_memory_cache_enabled"
  @render_cache_key "publishing_render_cache_enabled"

  def mount(_params, _session, socket) do
    # Subscribe to group changes for live updates
    if connected?(socket) do
      PublishingPubSub.subscribe_to_groups()
    end

    cache_groups = db_groups_to_maps()

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Publishing Settings"))
      |> assign(
        :current_path,
        Routes.path("/admin/settings/publishing")
      )
      |> assign(:module_enabled, Publishing.enabled?())
      |> assign(:cache_groups, cache_groups)
      |> assign(
        :default_language_no_prefix,
        Settings.get_boolean_setting(@default_language_no_prefix_key, false)
      )
      |> assign(
        :memory_cache_enabled,
        Settings.get_setting(@memory_cache_key, "true") == "true"
      )
      |> assign(
        :render_cache_enabled,
        Settings.get_setting(@render_cache_key, "true") == "true"
      )
      |> assign(:cache_status, build_cache_status(cache_groups))
      |> assign(:render_cache_stats, get_render_cache_stats())
      |> assign(:render_cache_per_group, build_render_cache_per_group(cache_groups))

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("regenerate_cache", %{"slug" => slug}, socket) do
    case ListingCache.regenerate(slug) do
      :ok ->
        {:noreply,
         socket
         |> assign(:cache_status, build_cache_status(socket.assigns.cache_groups))
         |> put_flash(:info, gettext("Cache regenerated for %{group}", group: slug))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to regenerate cache"))}
    end
  end

  def handle_event("invalidate_cache", %{"slug" => slug}, socket) do
    ListingCache.invalidate(slug)

    {:noreply,
     socket
     |> assign(:cache_status, build_cache_status(socket.assigns.cache_groups))
     |> put_flash(:info, gettext("Cache cleared for %{group}", group: slug))}
  end

  def handle_event("regenerate_all_caches", _params, socket) do
    results =
      Enum.map(socket.assigns.cache_groups, fn group ->
        {group["slug"], ListingCache.regenerate(group["slug"])}
      end)

    success_count = Enum.count(results, fn {_, result} -> result == :ok end)

    {:noreply,
     socket
     |> assign(:cache_status, build_cache_status(socket.assigns.cache_groups))
     |> put_flash(:info, gettext("Regenerated %{count} caches", count: success_count))}
  end

  def handle_event("toggle_memory_cache", _params, socket) do
    new_value = !socket.assigns.memory_cache_enabled
    Settings.update_setting(@memory_cache_key, to_string(new_value))

    # If disabling memory cache, clear all :persistent_term entries
    if !new_value do
      Enum.each(socket.assigns.cache_groups, fn group ->
        try do
          :persistent_term.erase(ListingCache.persistent_term_key(group["slug"]))
        rescue
          ArgumentError -> :ok
        end
      end)
    end

    {:noreply,
     socket
     |> assign(:memory_cache_enabled, new_value)
     |> assign(:cache_status, build_cache_status(socket.assigns.cache_groups))
     |> put_flash(:info, memory_cache_toggle_message(new_value))}
  end

  def handle_event("toggle_default_language_no_prefix", _params, socket) do
    new_value = !socket.assigns.default_language_no_prefix
    Settings.update_boolean_setting(@default_language_no_prefix_key, new_value)

    {:noreply,
     socket
     |> assign(:default_language_no_prefix, new_value)
     |> put_flash(
       :info,
       if(new_value,
         do: gettext("Default language public URLs now omit the locale prefix"),
         else: gettext("Default language public URLs now include the locale prefix")
       )
     )}
  end

  def handle_event("clear_render_cache", _params, socket) do
    Renderer.clear_all_cache()

    {:noreply,
     socket
     |> assign(:render_cache_stats, get_render_cache_stats())
     |> put_flash(:info, gettext("Render cache cleared"))}
  end

  def handle_event("clear_group_render_cache", %{"slug" => slug}, socket) do
    case Renderer.clear_group_cache(slug) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:render_cache_stats, get_render_cache_stats())
         |> put_flash(
           :info,
           gettext("Cleared %{count} cached posts for %{group}", count: count, group: slug)
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to clear cache"))}
    end
  end

  def handle_event("toggle_render_cache", _params, socket) do
    new_value = !socket.assigns.render_cache_enabled
    Settings.update_setting(@render_cache_key, to_string(new_value))

    {:noreply,
     socket
     |> assign(:render_cache_enabled, new_value)
     |> put_flash(:info, render_cache_toggle_message(new_value))}
  end

  def handle_event("toggle_group_render_cache", %{"slug" => slug}, socket) do
    # Use Renderer helper to get the new key for writes
    per_group_key = Renderer.per_group_cache_key(slug)
    current_value = Renderer.group_render_cache_enabled?(slug)
    new_value = !current_value
    Settings.update_setting(per_group_key, to_string(new_value))

    {:noreply,
     socket
     |> assign(:render_cache_per_group, build_render_cache_per_group(socket.assigns.cache_groups))
     |> put_flash(:info, render_cache_group_toggle_message(slug, new_value))}
  end

  # ============================================================================
  # PubSub Handlers - Live updates when groups change elsewhere
  # ============================================================================

  def handle_info({:group_created, _group}, socket) do
    {:noreply, refresh_groups(socket)}
  end

  def handle_info({:group_deleted, _slug}, socket) do
    {:noreply, refresh_groups(socket)}
  end

  def handle_info({:group_updated, _group}, socket) do
    {:noreply, refresh_groups(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_groups(socket) do
    groups = db_groups_to_maps()

    socket
    |> assign(:cache_groups, groups)
    |> assign(:cache_status, build_cache_status(groups))
    |> assign(:render_cache_per_group, build_render_cache_per_group(groups))
  end

  defp db_groups_to_maps do
    Publishing.list_groups()
  end

  defp memory_cache_toggle_message(true), do: gettext("Memory cache enabled")
  defp memory_cache_toggle_message(false), do: gettext("Memory cache disabled")

  defp render_cache_toggle_message(true), do: gettext("Render cache enabled")
  defp render_cache_toggle_message(false), do: gettext("Render cache disabled")

  defp render_cache_group_toggle_message(slug, true),
    do: gettext("Render cache for %{group} enabled", group: slug)

  defp render_cache_group_toggle_message(slug, false),
    do: gettext("Render cache for %{group} disabled", group: slug)

  # Build cache status for all groups
  defp build_cache_status(groups) do
    Map.new(groups, fn group ->
      slug = group["slug"]
      {slug, get_cache_info(slug)}
    end)
  end

  defp get_cache_info(group_slug) do
    get_cache_info_db(group_slug)
  end

  defp get_cache_info_db(group_slug) do
    in_memory =
      case :persistent_term.get(ListingCache.persistent_term_key(group_slug), :not_found) do
        :not_found -> false
        _ -> true
      end

    post_count =
      case :persistent_term.get(ListingCache.persistent_term_key(group_slug), :not_found) do
        :not_found -> length(Publishing.list_posts(group_slug))
        posts -> length(posts)
      end

    %{
      exists: in_memory,
      content_size: 0,
      modified_at: nil,
      post_count: post_count,
      in_memory: in_memory
    }
  end

  defp get_render_cache_stats do
    PhoenixKit.Cache.stats(:publishing_posts)
  rescue
    _ -> %{hits: 0, misses: 0, puts: 0, invalidations: 0, hit_rate: 0.0}
  end

  defp build_render_cache_per_group(groups) do
    Map.new(groups, fn group ->
      slug = group["slug"]
      {slug, Renderer.group_render_cache_enabled?(slug)}
    end)
  end

  def render(assigns) do
    ~H"""
    <div class="container flex flex-col mx-auto px-4 py-6">
    <%!-- Header Section --%>
    <.admin_page_header
      back={PhoenixKit.Utils.Routes.path("/admin")}
      title={gettext("Publishing Settings")}
      subtitle={gettext("Manage caching and performance settings for the publishing module.")}
    />

    <div class="max-w-2xl mx-auto space-y-6">
      <div class="card bg-base-100 shadow-xl border border-base-200">
        <div class="card-body space-y-4">
          <div>
            <h2 class="text-2xl font-semibold text-base-content">
              <.icon name="hero-language" class="w-6 h-6 inline-block mr-2" />
              {gettext("Public URL Language")}
            </h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "Control whether the default language keeps its locale segment in public URLs."
              )}
            </p>
          </div>

          <div class="flex items-center justify-between p-4 bg-base-200 rounded-lg">
            <div class="flex items-center gap-3">
              <.icon name="hero-link" class="w-5 h-5 text-base-content/70" />
              <div>
                <p class="font-medium">{gettext("Default Language Without Prefix")}</p>
                <p class="text-xs text-base-content/60">
                  {gettext("Use /group/post instead of /en/group/post for the default language")}
                </p>
              </div>
            </div>
            <input
              type="checkbox"
              class="toggle toggle-primary"
              checked={@default_language_no_prefix}
              phx-click="toggle_default_language_no_prefix"
            />
          </div>

          <div class="text-xs text-base-content/50">
            <p>
              <.icon name="hero-information-circle" class="w-3 h-3 inline" />
              {gettext(
                "When enabled, default-language public URLs become prefixless and prefixed default-language URLs redirect to the canonical prefixless version."
              )}
            </p>
          </div>
        </div>
      </div>

      <%!-- Cache Management Section --%>
      <div class="card bg-base-100 shadow-xl border border-base-200">
        <div class="card-body space-y-6">
          <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-4">
            <div>
              <h2 class="text-2xl font-semibold text-base-content">
                <.icon name="hero-bolt" class="w-6 h-6 inline-block mr-2" />
                {gettext("Listing Cache")}
              </h2>
              <p class="text-sm text-base-content/70">
                {gettext(
                  "Cached listing data speeds up listing pages. Cache is automatically updated when posts change."
                )}
              </p>
            </div>
            <% any_listing_cache = @memory_cache_enabled %>
            <%= if @cache_groups != [] and any_listing_cache do %>
              <button
                type="button"
                phx-click="regenerate_all_caches"
                class="btn btn-primary btn-sm whitespace-nowrap"
              >
                <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" />
                {gettext("Regenerate All")}
              </button>
            <% end %>
          </div>

          <%!-- Cache Settings Toggles --%>
          <div class="grid grid-cols-1 gap-4">
            <%!-- Memory Cache Toggle --%>
            <div class="flex items-center justify-between p-4 bg-base-200 rounded-lg">
              <div class="flex items-center gap-3">
                <.icon name="hero-cpu-chip" class="w-5 h-5 text-base-content/70" />
                <div>
                  <p class="font-medium">{gettext("Memory Cache")}</p>
                  <p class="text-xs text-base-content/60">
                    {gettext("Store in :persistent_term for sub-microsecond reads")}
                  </p>
                </div>
              </div>
              <input
                type="checkbox"
                class="toggle toggle-primary"
                checked={@memory_cache_enabled}
                phx-click="toggle_memory_cache"
              />
            </div>
          </div>

          <%= if not @memory_cache_enabled do %>
            <div class="alert alert-warning">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>
                {gettext(
                  "Memory cache is disabled. Listing pages will query the database on every request."
                )}
              </span>
            </div>
          <% end %>

          <%= if @cache_groups == [] do %>
            <div class="alert">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span>{gettext("Create a publishing group to manage its cache.")}</span>
            </div>
          <% else %>
            <% any_cache_enabled = @memory_cache_enabled %>
            <%= if any_cache_enabled do %>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>{gettext("Group")}</th>
                      <th class="text-center">{gettext("Posts")}</th>
                      <%= if @memory_cache_enabled do %>
                        <th class="text-center">
                          <span class="flex items-center justify-center gap-1">
                            <.icon name="hero-cpu-chip" class="w-4 h-4" />
                            {gettext("Memory")}
                          </span>
                        </th>
                      <% end %>
                      <th class="text-right">{gettext("Actions")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for group <- @cache_groups do %>
                      <% cache = @cache_status[group["slug"]] %>
                      <tr>
                        <td class="font-medium">{group["name"]}</td>
                        <td class="text-center">
                          <%= if cache.post_count do %>
                            <span class="font-mono text-sm">{cache.post_count}</span>
                          <% else %>
                            <span class="text-base-content/50">—</span>
                          <% end %>
                        </td>
                        <%= if @memory_cache_enabled do %>
                          <td class="text-center">
                            <%= if cache.in_memory do %>
                              <.icon name="hero-check-circle" class="w-5 h-5 text-success" />
                            <% else %>
                              <.icon name="hero-x-circle" class="w-5 h-5 text-base-content/30" />
                            <% end %>
                          </td>
                        <% end %>
                        <td class="text-right">
                          <div class="flex justify-end gap-2">
                            <%= if cache.exists or cache.in_memory do %>
                              <button
                                type="button"
                                phx-click="invalidate_cache"
                                phx-value-slug={group["slug"]}
                                class="btn btn-outline btn-xs text-error tooltip tooltip-bottom"
                                data-tip={gettext("Clear cache")}
                              >
                                <.icon name="hero-trash" class="w-4 h-4 hidden sm:inline" />
                                <span class="sm:hidden whitespace-nowrap">
                                  {gettext("Clear cache")}
                                </span>
                              </button>
                            <% end %>
                            <button
                              type="button"
                              phx-click="regenerate_cache"
                              phx-value-slug={group["slug"]}
                              class="btn btn-outline btn-xs tooltip tooltip-bottom"
                              data-tip={gettext("Regenerate cache")}
                            >
                              <.icon name="hero-arrow-path" class="w-4 h-4 hidden sm:inline" />
                              <span class="sm:hidden whitespace-nowrap">
                                {gettext("Regenerate cache")}
                              </span>
                            </button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>

              <div class="text-xs text-base-content/50 space-y-1">
                <p>
                  <.icon name="hero-information-circle" class="w-3 h-3 inline" />
                  {gettext(
                    "\"In Memory\" means the cache is loaded into :persistent_term for sub-microsecond reads."
                  )}
                </p>
                <p>
                  <.icon name="hero-arrow-path" class="w-3 h-3 inline" />
                  {gettext("Regenerate scans all posts and rebuilds the cache.")}
                </p>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>

      <%!-- Render Cache Section --%>
      <div class="card bg-base-100 shadow-xl border border-base-200">
        <div class="card-body space-y-4">
          <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-4">
            <div>
              <h2 class="text-2xl font-semibold text-base-content">
                <.icon name="hero-document-text" class="w-6 h-6 inline-block mr-2" />
                {gettext("Render Cache")}
              </h2>
              <p class="text-sm text-base-content/70">
                {gettext(
                  "Cached rendered HTML for published posts. Uses content-hash keys so edits auto-invalidate."
                )}
              </p>
            </div>
            <%= if @render_cache_enabled do %>
              <button
                type="button"
                phx-click="clear_render_cache"
                class="btn btn-outline btn-error btn-sm whitespace-nowrap"
                data-confirm={
                  gettext(
                    "Clear all cached rendered posts? They will be re-rendered on next view."
                  )
                }
              >
                <.icon name="hero-trash" class="w-4 h-4 mr-1" />
                {gettext("Clear All")}
              </button>
            <% end %>
          </div>

          <%!-- Global Render Cache Toggle --%>
          <div class="flex items-center justify-between p-4 bg-base-200 rounded-lg">
            <div class="flex items-center gap-3">
              <.icon name="hero-bolt" class="w-5 h-5 text-base-content/70" />
              <div>
                <p class="font-medium">{gettext("Render Cache")}</p>
                <p class="text-xs text-base-content/60">
                  {gettext("Cache rendered HTML for published posts (6-hour TTL)")}
                </p>
              </div>
            </div>
            <input
              type="checkbox"
              class="toggle toggle-primary"
              checked={@render_cache_enabled}
              phx-click="toggle_render_cache"
            />
          </div>

          <%= if not @render_cache_enabled do %>
            <div class="alert alert-warning">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>
                {gettext("Render cache is disabled. Posts will be rendered on every request.")}
              </span>
            </div>
          <% else %>
            <%!-- Stats Display --%>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
              <div class="stat bg-base-200 rounded-lg p-4">
                <div class="stat-title text-xs">{gettext("Cache Hits")}</div>
                <div class="stat-value text-lg font-mono">{@render_cache_stats[:hits] || 0}</div>
              </div>
              <div class="stat bg-base-200 rounded-lg p-4">
                <div class="stat-title text-xs">{gettext("Cache Misses")}</div>
                <div class="stat-value text-lg font-mono">
                  {@render_cache_stats[:misses] || 0}
                </div>
              </div>
              <div class="stat bg-base-200 rounded-lg p-4">
                <div class="stat-title text-xs">{gettext("Entries Cached")}</div>
                <div class="stat-value text-lg font-mono">{@render_cache_stats[:puts] || 0}</div>
              </div>
              <div class="stat bg-base-200 rounded-lg p-4">
                <div class="stat-title text-xs">{gettext("Hit Rate")}</div>
                <div class="stat-value text-lg font-mono">
                  <%= if @render_cache_stats[:hit_rate] do %>
                    {Float.round(@render_cache_stats[:hit_rate] * 100, 1)}%
                  <% else %>
                    0%
                  <% end %>
                </div>
              </div>
            </div>

            <%!-- Per-Group Render Cache Table --%>
            <%= if @cache_groups != [] do %>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>{gettext("Group")}</th>
                      <th class="text-center">{gettext("Enabled")}</th>
                      <th class="text-right">{gettext("Actions")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for group <- @cache_groups do %>
                      <% slug = group["slug"] %>
                      <% enabled = @render_cache_per_group[slug] %>
                      <tr>
                        <td class="font-medium">{group["name"]}</td>
                        <td class="text-center">
                          <input
                            type="checkbox"
                            class="toggle toggle-primary toggle-sm"
                            checked={enabled}
                            phx-click="toggle_group_render_cache"
                            phx-value-slug={slug}
                          />
                        </td>
                        <td class="text-right">
                          <%= if enabled do %>
                            <button
                              type="button"
                              phx-click="clear_group_render_cache"
                              phx-value-slug={slug}
                              class="btn btn-outline btn-xs text-error tooltip tooltip-bottom"
                              data-tip={gettext("Clear cache for this group")}
                            >
                              <.icon name="hero-trash" class="w-4 h-4 hidden sm:inline" />
                              <span class="sm:hidden whitespace-nowrap">
                                {gettext("Clear cache for this group")}
                              </span>
                            </button>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% end %>

          <div class="text-xs text-base-content/50">
            <p>
              <.icon name="hero-information-circle" class="w-3 h-3 inline" />
              {gettext(
                "Render cache stores pre-rendered HTML for published posts. Cache keys include content hashes, so edits automatically use fresh renders. TTL: 6 hours."
              )}
            </p>
          </div>
        </div>
      </div>
    </div>
    </div>
    """
  end
end
