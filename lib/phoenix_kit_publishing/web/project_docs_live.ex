defmodule PhoenixKit.Modules.Publishing.Web.ProjectDocsLive do
  @moduledoc """
  The publishing **Docs** tab for the `phoenix_kit_projects` hub — this
  module's `phoenix_kit_project_extensions/0` contribution (see that
  function in `PhoenixKit.Modules.Publishing`).

  Rendered by the projects hub via `live_render` with the hub's
  embed-session contract: `"project_uuid"`, `"config"` (`group_slug`
  links ONE publishing group — groups are slug-keyed everywhere in this
  package), `"current_user_uuid"` / `"locale"`. Linkage is CONFIG-based —
  no FK, no dependency on the projects package; the unconfigured state
  lists group slugs to copy from.

  Read-only: the group's PUBLISHED entries (title/date) with link-outs to
  the publishing admin editor; writing stays in publishing.
  Off-router-mountable: no `handle_params/3` (the hub's hard requirement).
  """

  use Phoenix.LiveView

  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Utils.Routes

  @posts_limit 25

  @impl true
  def mount(_params, session, socket) do
    group_slug = get_in(session, ["config", "group_slug"])

    group =
      case group_slug && safe(fn -> Groups.get_group(group_slug) end) do
        {:ok, group} -> group
        _ -> nil
      end

    {posts, total} =
      if group do
        posts =
          safe(fn ->
            Posts.list_posts_by_status(group_slug, Constants.status_published())
          end) || []

        {Enum.take(posts, @posts_limit), length(posts)}
      else
        {[], 0}
      end

    candidates = if group, do: [], else: safe(fn -> Groups.list_groups() end) || []

    {:ok,
     assign(socket,
       project_uuid: session["project_uuid"],
       group_slug: group_slug,
       group: group,
       posts: posts,
       total: total,
       candidates: candidates
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%= if @group do %>
        <div class="flex items-center gap-3">
          <span class="hero-document-text w-5 h-5 opacity-70"></span>
          <div class="min-w-0 grow">
            <h3 class="font-semibold truncate">{@group["name"] || @group_slug}</h3>
            <p class="text-xs opacity-60">{published_label(@total)}</p>
          </div>
          <.link
            navigate={Routes.path("/admin/publishing/#{@group_slug}/new")}
            class="btn btn-primary btn-sm gap-1"
          >
            New entry
          </.link>
          <.link
            navigate={Routes.path("/admin/publishing/#{@group_slug}")}
            class="btn btn-ghost btn-sm gap-1"
          >
            Open in Publishing
          </.link>
        </div>

        <%= if @posts == [] do %>
          <div class="card border border-dashed border-base-300 bg-base-100">
            <div class="card-body items-center text-center py-8">
              <p class="text-sm opacity-70">Nothing published in this group yet.</p>
            </div>
          </div>
        <% else %>
          <div class="divide-y divide-base-200 rounded-lg border border-base-200">
            <div :for={post <- @posts} class="flex items-baseline gap-3 px-3 py-2">
              <.link
                navigate={Routes.path("/admin/publishing/#{@group_slug}/#{post.uuid}/edit")}
                class="link link-hover text-sm font-medium truncate min-w-0"
              >
                {post_title(post)}
              </.link>
              <span class="text-xs opacity-50 ml-auto shrink-0 whitespace-nowrap">
                {post_date(post)}
              </span>
            </div>
          </div>
          <p :if={@total > length(@posts)} class="text-xs opacity-50">
            Showing {length(@posts)} of {@total} — the full list lives in the Publishing admin.
          </p>
        <% end %>
      <% else %>
        <div class="card border border-dashed border-base-300 bg-base-100">
          <div class="card-body py-6 gap-2">
            <p class="text-sm opacity-70 text-center">
              No publishing group linked to this project yet.
            </p>
            <p class="text-xs opacity-50 text-center">
              Paste a group slug into this tab's settings in the project's
              Modules &amp; features panel.
            </p>
            <div :if={@candidates != []} class="mt-2">
              <p class="text-xs font-semibold opacity-60 mb-1">Available groups:</p>
              <div class="flex flex-col gap-1">
                <div
                  :for={candidate <- @candidates}
                  class="flex items-baseline gap-2 text-xs bg-base-200/60 rounded px-2 py-1"
                >
                  <span class="font-medium shrink-0">{candidate["name"]}</span>
                  <code class="opacity-60">{candidate["slug"]}</code>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp published_label(0), do: "Nothing published"
  defp published_label(1), do: "1 published entry"
  defp published_label(n), do: "#{n} published entries"

  # Listing maps carry the human title under metadata; fall back through
  # the slugs so a metadata gap never renders a blank row.
  defp post_title(post) do
    metadata = post_field(post, :metadata) || %{}

    map_field(metadata, :title) ||
      post_field(post, :url_slug) || post_field(post, :slug) || "(untitled)"
  end

  defp post_date(post) do
    metadata = post_field(post, :metadata) || %{}

    case map_field(metadata, :published_at) || post_field(post, :date) do
      %Date{} = date -> Calendar.strftime(date, "%b %-d, %Y")
      formatted when is_binary(formatted) -> formatted
      _ -> ""
    end
  end

  defp post_field(post, key) when is_map(post), do: map_field(post, key)

  defp map_field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  # A publishing DB hiccup degrades the tab to its empty state — a
  # contributed extension tab must never crash the host project page.
  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
