defmodule PhoenixKit.Modules.Publishing.Web.Index do
  @moduledoc """
  Publishing module overview dashboard.
  Provides high-level stats, quick actions, and guidance for administrators.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers

  @group_statuses Constants.group_statuses()
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.LanguageSwitcher

  @impl true
  def mount(_params, _session, socket) do
    # Load date/time format settings once for performance
    date_time_settings =
      Settings.get_settings_cached(
        ["date_format", "time_format", "time_zone"],
        %{
          "date_format" => "Y-m-d",
          "time_format" => "H:i",
          "time_zone" => "0"
        }
      )

    {groups, insights, summary} =
      dashboard_snapshot(
        socket.assigns.current_locale_base,
        socket.assigns[:phoenix_kit_current_user],
        date_time_settings
      )

    # Subscribe to PubSub for live updates when connected
    if connected?(socket) do
      # Subscribe to all groups' post updates
      Enum.each(groups, fn group ->
        PublishingPubSub.subscribe_to_posts(group["slug"])
      end)

      # Subscribe to global groups topic (for group creation/deletion)
      PublishingPubSub.subscribe_to_groups()
    end

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Publishing"))
      |> assign(
        :current_path,
        Routes.path("/admin/publishing")
      )
      |> assign(:groups, groups)
      |> assign(:dashboard_insights, insights)
      |> assign(:dashboard_summary, summary)
      |> assign(:empty_state?, groups == [])
      |> assign(:enabled_languages, Publishing.enabled_language_codes())
      |> assign(:endpoint_url, "")
      |> assign(:date_time_settings, date_time_settings)
      |> assign(
        :primary_language_name,
        Helpers.get_language_name(Publishing.get_primary_language())
      )
      |> assign(:dashboard_refresh_timer, nil)
      |> assign(:view_mode, "active")
      |> assign(:loading, false)
      |> assign(:trashed_count, length(Publishing.list_groups("trashed")))

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :endpoint_url, extract_endpoint_url(uri))}
  end

  # PubSub handlers for live updates — debounced to prevent rapid re-renders
  @dashboard_debounce_ms 500

  @impl true
  def handle_info({:deferred_view_switch, _mode}, socket) do
    {:noreply,
     socket
     |> refresh_dashboard()
     |> assign(:loading, false)}
  end

  def handle_info({:post_created, _post}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:post_updated, _post}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:post_status_changed, _post}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:post_deleted, _post_identifier}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:group_created, _group}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:group_deleted, _group_slug}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:group_updated, _group}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:version_created, _post}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:version_live_changed, _uuid, _version}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info({:version_deleted, _slug, _version}, socket),
    do: {:noreply, schedule_dashboard_refresh(socket)}

  def handle_info(:debounced_dashboard_refresh, socket),
    do: {:noreply, socket |> assign(:dashboard_refresh_timer, nil) |> refresh_dashboard()}

  # Primary language update completed (from this page or elsewhere)
  def handle_info(
        {:primary_language_migration_completed, _group_slug, count, _errors, primary_language},
        socket
      ) do
    {:noreply,
     socket
     |> refresh_dashboard()
     |> put_flash(
       :info,
       gettext("Updated %{count} posts to primary language: %{lang}",
         count: count,
         lang: Helpers.get_language_name(primary_language)
       )
     )}
  end

  # Catch-all for other PubSub messages (translation progress, cache changes, etc.)
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("update_primary_language", %{"slug" => group_slug}, socket) do
    case Publishing.update_posts_primary_language(group_slug) do
      {:ok, 0} ->
        {:noreply, put_flash(socket, :info, gettext("All posts already up to date"))}

      {:ok, count} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(
           :info,
           gettext("Updated %{count} posts to primary language: %{lang}",
             count: count,
             lang: Helpers.get_language_name(Publishing.get_primary_language())
           )
         )}
    end
  rescue
    e ->
      Logger.error("[Publishing.Index] Primary language update failed: #{Exception.message(e)}")
      {:noreply, put_flash(socket, :error, gettext("Failed to update primary language"))}
  end

  def handle_event("switch_view", %{"mode" => mode}, socket) when mode in @group_statuses do
    send(self(), {:deferred_view_switch, mode})

    {:noreply,
     socket
     |> assign(:view_mode, mode)
     |> assign(:dashboard_insights, [])
     |> assign(:empty_state?, false)
     |> assign(:loading, true)}
  end

  def handle_event("trash_group", %{"slug" => slug}, socket) do
    case Publishing.trash_group(slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, gettext("Group moved to trash"))}

      {:error, reason} ->
        Logger.warning("[Publishing.Index] Trash group failed for #{slug}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, gettext("Failed to trash group"))}
    end
  end

  def handle_event("restore_group", %{"slug" => slug}, socket) do
    case Publishing.restore_group(slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, gettext("Group restored"))}

      {:error, reason} ->
        Logger.warning("[Publishing.Index] Restore group failed for #{slug}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, gettext("Failed to restore group"))}
    end
  end

  def handle_event("delete_group", %{"slug" => slug}, socket) do
    case Publishing.remove_group(slug, force: true) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, gettext("Group permanently deleted"))}

      {:error, reason} ->
        Logger.warning("[Publishing.Index] Delete group failed for #{slug}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, gettext("Failed to delete group"))}
    end
  end

  defp schedule_dashboard_refresh(socket) do
    if timer = socket.assigns[:dashboard_refresh_timer] do
      Process.cancel_timer(timer)
    end

    timer = Process.send_after(self(), :debounced_dashboard_refresh, @dashboard_debounce_ms)
    assign(socket, :dashboard_refresh_timer, timer)
  end

  defp refresh_dashboard(socket) do
    view_mode = socket.assigns[:view_mode] || "active"

    {groups, insights, summary} =
      dashboard_snapshot(
        socket.assigns.current_locale_base,
        socket.assigns[:phoenix_kit_current_user],
        socket.assigns.date_time_settings,
        view_mode
      )

    trashed_count = length(Publishing.list_groups("trashed"))

    # Resubscribe to any new groups that may have been created
    Enum.each(groups, fn group ->
      PublishingPubSub.subscribe_to_posts(group["slug"])
    end)

    assign(socket,
      groups: groups,
      dashboard_insights: insights,
      dashboard_summary: summary,
      empty_state?: groups == [] and view_mode == "active",
      trashed_count: trashed_count
    )
  end

  defp dashboard_snapshot(_locale, current_user, date_time_settings, view_mode \\ "active") do
    # Admin side reads from database only
    db_groups = Publishing.list_groups(view_mode)

    groups = db_groups

    insights =
      Enum.map(db_groups, &build_group_insight(&1, current_user, date_time_settings))

    summary = build_summary(groups, insights)

    {groups, insights, summary}
  end

  defp build_group_insight(db_group, current_user, date_time_settings) do
    group_slug = db_group["slug"]

    # Use ListingCache when available (sub-microsecond), fall back to DB
    posts =
      case ListingCache.read(group_slug) do
        {:ok, cached_posts} -> cached_posts
        {:error, _} -> Publishing.list_posts(group_slug)
      end

    status_counts = Enum.frequencies_by(posts, &Map.get(&1[:metadata] || %{}, :status, "draft"))

    languages =
      posts
      |> Enum.flat_map(&(&1[:available_languages] || []))
      |> Enum.uniq()
      |> Enum.sort()

    latest_published_at = find_latest_published_at(posts)

    # Reuse already-loaded posts for primary language check (avoids redundant DB query)
    global_primary = Publishing.get_primary_language()

    primary_lang_status =
      Publishing.count_primary_language_status(posts, global_primary)

    lang_migration_count =
      if primary_lang_status,
        do: primary_lang_status.needs_backfill + primary_lang_status.needs_migration,
        else: 0

    %{
      name: db_group["name"],
      slug: group_slug,
      mode: db_group["mode"],
      posts_count: length(posts),
      published_count: Map.get(status_counts, "published", 0),
      draft_count: Map.get(status_counts, "draft", 0),
      archived_count: Map.get(status_counts, "archived", 0),
      languages: languages,
      last_published_at: latest_published_at,
      last_published_at_text:
        format_datetime(latest_published_at, current_user, date_time_settings),
      primary_language_status: primary_lang_status,
      needs_primary_language_migration: lang_migration_count > 0,
      needs_migration_count: lang_migration_count
    }
  end

  defp find_latest_published_at(posts) do
    posts
    |> Enum.map(&get_in(&1, [:metadata, :published_at]))
    |> Enum.reduce(nil, &update_latest_datetime/2)
  end

  defp update_latest_datetime(value, acc) do
    case parse_datetime(value) do
      {:ok, dt} -> compare_and_select_latest(dt, acc)
      :error -> acc
    end
  end

  defp compare_and_select_latest(datetime, nil), do: datetime

  defp compare_and_select_latest(datetime, current) do
    if DateTime.compare(datetime, current) == :gt, do: datetime, else: current
  end

  defp build_summary(groups, insights) do
    Enum.reduce(
      insights,
      %{
        total_groups: length(groups),
        total_posts: 0,
        published_posts: 0,
        draft_posts: 0,
        archived_posts: 0
      },
      fn insight, acc ->
        %{
          acc
          | total_posts: acc.total_posts + insight.posts_count,
            published_posts: acc.published_posts + insight.published_count,
            draft_posts: acc.draft_posts + insight.draft_count,
            archived_posts: acc.archived_posts + insight.archived_count
        }
      end
    )
  end

  defp parse_datetime(nil), do: :error

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp format_datetime(nil, _user, _settings), do: nil

  defp format_datetime(%DateTime{} = datetime, current_user, date_time_settings) do
    # Fallback to dummy user if current_user is nil
    user = current_user || %{user_timezone: nil}

    # Convert DateTime to NaiveDateTime (assuming stored as UTC)
    naive_dt = DateTime.to_naive(datetime)

    # Format date part with timezone conversion
    date_str = UtilsDate.format_date_with_user_timezone_cached(naive_dt, user, date_time_settings)

    # Format time part with timezone conversion
    time_str = UtilsDate.format_time_with_user_timezone_cached(naive_dt, user, date_time_settings)

    "#{date_str} #{time_str}"
  rescue
    _ -> nil
  end

  defp extract_endpoint_url(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, port: port} when not is_nil(scheme) and not is_nil(host) ->
        port_string = if port in [80, 443], do: "", else: ":#{port}"
        "#{scheme}://#{host}#{port_string}"

      _ ->
        ""
    end
  end

  defp extract_endpoint_url(_), do: ""

  defp build_language_pills(language_codes) when is_list(language_codes) do
    Enum.map(language_codes, fn lang ->
      info = LanguageHelpers.get_language_info(lang)

      %{
        code: lang,
        short_code: String.upcase(lang),
        name: if(info, do: info.name, else: lang),
        exists: true
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
  <div class="container flex-col mx-auto px-4 py-6">
    <%!-- Header Section --%>
    <.admin_page_header
      back={Routes.path("/admin")}
      title={gettext("Publishing")}
    >
      <:actions>
        <.link
          navigate={Routes.path("/admin/publishing/new-group")}
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Create Group")}
        </.link>
      </:actions>
    </.admin_page_header>

    <div class="space-y-2 sm:space-y-3">
      <%= if @empty_state? do %>
        <div class="card bg-base-100 border border-dashed border-base-300 shadow-sm">
          <div class="card-body p-4 sm:p-8 items-center text-center space-y-3 sm:space-y-4">
            <div class="rounded-full bg-base-200 p-3 text-primary">
              <.icon name="hero-document-text" class="w-8 h-8" />
            </div>
            <h2 class="text-xl sm:text-2xl font-semibold text-base-content">
              {gettext("No publishing groups yet")}
            </h2>
            <p class="text-sm sm:text-base text-base-content/70 max-w-xl">
              {gettext("Create your first publishing group to start drafting posts.")}
            </p>
            <div class="flex flex-wrap justify-center gap-3">
              <.link
                href={Routes.path("/admin/publishing/new-group")}
                class="btn btn-primary btn-sm"
              >
                <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext(
                  "Create Publishing Group"
                )}
              </.link>
            </div>
          </div>
        </div>
      <% else %>
        <%!-- Active / Trashed Tabs — only show if there are trashed groups --%>
        <%= if @trashed_count > 0 or @view_mode == "trashed" do %>
          <div class="flex items-center gap-0.5 border-b border-base-200">
            <button
              type="button"
              phx-click="switch_view"
              phx-value-mode="active"
              class={"px-3 py-1 text-xs font-medium border-b-2 transition-colors cursor-pointer #{if @view_mode == "active", do: "border-primary text-primary", else: "border-transparent text-base-content/50 hover:text-base-content"}"}
            >
              {gettext("Active")}
            </button>
            <button
              type="button"
              phx-click="switch_view"
              phx-value-mode="trashed"
              class={"px-3 py-1 text-xs font-medium border-b-2 transition-colors cursor-pointer #{if @view_mode == "trashed", do: "border-error text-error", else: "border-transparent text-base-content/50 hover:text-base-content"}"}
            >
              {gettext("Trash")}
            </button>
          </div>
        <% end %>

        <%= if @loading do %>
          <div class="grid gap-3 sm:gap-4 md:grid-cols-2 xl:grid-cols-3 animate-pulse">
            <%= for _i <- 1..3 do %>
              <div class="card bg-base-100 shadow-sm border border-base-200 h-full">
                <div class="card-body p-3 sm:p-6 space-y-3 sm:space-y-4">
                  <div class="flex items-center justify-between">
                    <div class="bg-base-200 h-6 w-40 rounded"></div>
                    <div class="bg-base-200 h-5 w-20 rounded-full"></div>
                  </div>
                  <div class="bg-base-200 h-3 w-32 rounded"></div>
                  <div class="grid grid-cols-2 gap-3">
                    <div class="bg-base-200 h-14 rounded-lg"></div>
                    <div class="bg-base-200 h-14 rounded-lg"></div>
                  </div>
                  <div class="flex gap-2">
                    <div class="bg-base-200 h-8 w-20 rounded-lg"></div>
                    <div class="bg-base-200 h-8 w-20 rounded-lg"></div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="grid gap-3 sm:gap-4 md:grid-cols-2 xl:grid-cols-3">
            <%= for insight <- @dashboard_insights do %>
              <div class={"card bg-base-100 shadow-sm border transition h-full #{if @view_mode == "trashed", do: "border-base-200 opacity-60", else: "border-base-200 hover:border-primary/60"}"}>
                <div class="card-body p-3 sm:p-6 space-y-1.5 sm:space-y-4 h-full flex flex-col">
                  <div class="flex flex-wrap items-center sm:items-start justify-between gap-1 sm:gap-3">
                    <div class="sm:space-y-2 min-w-0 flex-1">
                      <h3 class="text-lg sm:text-xl font-semibold text-base-content">
                        <%= if @view_mode == "active" do %>
                          <.link
                            navigate={Routes.path("/admin/publishing/#{insight.slug}")}
                            class="hover:text-primary transition-colors"
                          >
                            {insight.name}
                          </.link>
                        <% else %>
                          {insight.name}
                        <% end %>
                      </h3>
                      <p class="hidden sm:block text-xs text-base-content/60 truncate">
                        {gettext("Slug")}: <code class="font-mono">{insight.slug}</code>
                      </p>
                      <p class="hidden sm:block text-xs text-base-content/60">
                        <span class="whitespace-nowrap">{gettext("Last published")}: </span>
                        <%= if insight.last_published_at_text do %>
                          <span class="whitespace-nowrap">{insight.last_published_at_text}</span>
                        <% else %>
                          {gettext("No published posts yet")}
                        <% end %>
                      </p>
                    </div>
                    <span class="badge badge-ghost badge-sm text-[10px] px-2 py-1 whitespace-nowrap">
                      <%= if insight.mode == "slug" do %>
                        {gettext("Slug-based")}
                      <% else %>
                        {gettext("Timestamp-based")}
                      <% end %>
                    </span>
                  </div>

                  <div class="grid grid-cols-2 gap-1.5 sm:gap-3">
                    <div class="rounded-lg bg-base-200/60 px-1.5 py-1 sm:px-3 sm:py-2 text-center">
                      <p class="text-[10px] sm:text-xs uppercase tracking-wide text-base-content/60">
                        {gettext("Posts")}
                      </p>
                      <p class="text-sm sm:text-base font-semibold text-base-content">
                        {insight.posts_count}
                      </p>
                    </div>
                    <div class="rounded-lg bg-success/10 px-1.5 py-1 sm:px-3 sm:py-2 text-center">
                      <p class="text-[10px] sm:text-xs uppercase tracking-wide text-success">
                        {gettext("Published")}
                      </p>
                      <p class="text-sm sm:text-base font-semibold text-success">
                        {insight.published_count}
                      </p>
                    </div>
                  </div>

                  <div class="hidden sm:block">
                    <details class="group">
                      <summary class="text-xs font-medium uppercase text-base-content/60 cursor-pointer select-none list-none flex items-center gap-1 hover:text-base-content transition-colors">
                        <.icon
                          name="hero-chevron-right"
                          class="w-3 h-3 transition-transform group-open:rotate-90"
                        />
                        {gettext("Languages used")}:
                        <span class="font-semibold text-base-content/80">
                          {length(insight.languages)}
                        </span>
                      </summary>
                      <%= if insight.languages != [] do %>
                        <div class="pl-4">
                          <.language_switcher
                            languages={build_language_pills(insight.languages)}
                            show_status={false}
                            variant={:pills}
                            size={:xs}
                          />
                        </div>
                      <% else %>
                        <p class="text-xs text-base-content/50 mt-1 pl-4">{gettext("None")}</p>
                      <% end %>
                    </details>
                  </div>

                  <%!-- Primary Language Update Warning --%>
                  <%= if insight.needs_primary_language_migration do %>
                    <div class="flex flex-wrap items-center gap-2 px-3 py-2 rounded-lg bg-warning/10 border border-warning/20">
                      <.icon name="hero-language" class="w-4 h-4 text-warning shrink-0" />
                      <span class="text-xs text-warning flex-1 min-w-0">
                        {ngettext(
                          "%{count} post needs primary language update",
                          "%{count} posts need primary language update",
                          insight.needs_migration_count,
                          count: insight.needs_migration_count
                        )}
                      </span>
                      <button
                        type="button"
                        class="btn btn-warning btn-xs"
                        phx-click="update_primary_language"
                        phx-value-slug={insight.slug}
                        data-confirm={
                          gettext(
                            "Update %{count} posts to use the current primary language?",
                            count: insight.needs_migration_count
                          )
                        }
                      >
                        {gettext("Update")}
                      </button>
                    </div>
                  <% end %>

                  <div class="flex flex-wrap gap-1.5 sm:gap-2 mt-auto">
                    <%= if @view_mode == "active" do %>
                      <.link
                        navigate={Routes.path("/admin/publishing/#{insight.slug}")}
                        class="btn btn-outline btn-sm btn-xs sm:btn-sm flex-1 sm:flex-none min-w-0"
                      >
                        <.icon name="hero-arrow-right" class="w-4 h-4 sm:mr-1" />
                        <span class="hidden sm:inline">{gettext("Open")}</span>
                      </.link>
                      <.link
                        navigate={Routes.path("/admin/publishing/edit-group/#{insight.slug}")}
                        class="btn btn-outline btn-sm btn-xs sm:btn-sm flex-1 sm:flex-none min-w-0"
                      >
                        <.icon name="hero-cog-6-tooth" class="w-4 h-4 sm:mr-1" />
                        <span class="hidden sm:inline">{gettext("Settings")}</span>
                      </.link>
                      <%= if insight.published_count > 0 do %>
                        <% group_slug = insight.slug %>
                        <% url_prefix =
                          PhoenixKit.Config.get_url_prefix()
                          |> case do
                            "/" -> ""
                            prefix -> prefix
                          end %>
                        <% default_language = List.first(@enabled_languages) %>
                        <% public_url =
                          if length(@enabled_languages) == 1 do
                            @endpoint_url <> url_prefix <> "/" <> group_slug
                          else
                            @endpoint_url <> url_prefix <> "/#{default_language}/" <> group_slug
                          end %>
                        <a
                          href={public_url}
                          target="_blank"
                          rel="noopener"
                          class="btn btn-outline btn-sm btn-xs sm:btn-sm flex-1 sm:flex-none min-w-0"
                          aria-label={gettext("View public site")}
                        >
                          <.icon name="hero-eye" class="w-4 h-4 sm:mr-1" />
                          <span class="hidden sm:inline">{gettext("Public")}</span>
                        </a>
                      <% end %>
                      <button
                        type="button"
                        phx-click="trash_group"
                        phx-value-slug={insight.slug}
                        class="btn btn-outline btn-sm btn-xs sm:btn-sm min-w-0 text-error hover:bg-error hover:text-error-content"
                        data-confirm={gettext("Move this group to trash?")}
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    <% else %>
                      <button
                        type="button"
                        phx-click="restore_group"
                        phx-value-slug={insight.slug}
                        class="btn btn-outline btn-sm btn-xs sm:btn-sm flex-1 sm:flex-none min-w-0 text-success"
                      >
                        <.icon name="hero-arrow-uturn-left" class="w-4 h-4 sm:mr-1" />
                        <span class="hidden sm:inline">{gettext("Restore")}</span>
                      </button>
                      <button
                        type="button"
                        phx-click="delete_group"
                        phx-value-slug={insight.slug}
                        class="btn btn-outline btn-sm btn-xs sm:btn-sm flex-1 sm:flex-none min-w-0 text-error hover:bg-error hover:text-error-content"
                        data-confirm={
                          gettext(
                            "Permanently delete this group and all its posts? This cannot be undone."
                          )
                        }
                      >
                        <.icon name="hero-trash" class="w-4 h-4 sm:mr-1" />
                        <span class="hidden sm:inline">{gettext("Delete Forever")}</span>
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if not @loading and @dashboard_insights == [] and @view_mode == "trashed" do %>
          <div class="text-center py-8 text-base-content/60">
            <.icon name="hero-trash" class="w-8 h-8 mx-auto mb-2 opacity-40" />
            <p class="text-sm">{gettext("Trash is empty")}</p>
          </div>
        <% end %>
      <% end %>
    </div>
  </div>
    """
  end
end
