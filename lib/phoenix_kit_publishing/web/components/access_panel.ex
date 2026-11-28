defmodule PhoenixKit.Modules.Publishing.Web.Components.AccessPanel do
  @moduledoc """
  The "Access" panel: who may open a post, or — on a group's edit page — the
  default rules new posts of the group start with.

  Saves on its own, immediately, through `PostAccess` (rules are post-level,
  not part of a version, so they do not ride the editor's save). Shows a
  plain-language summary, the rules with their notes and end dates, and the
  forms to add one: signed-in readers, roles (core's roles), chosen users (by
  e-mail), a password (set or rotate), and secret links (post only; the link
  is shown once, right after it is made). On a group it also holds "list
  protected posts to readers who may open them" and "apply to existing
  posts", which shows how many posts it would change before it changes them.

  Required assigns: `:id`, `:owner` (`{:post, uuid}` or `{:group, uuid}`),
  `:scope` (the page's scope; every event re-checks it holds `publishing`).
  Optional: `:public_url` (the post's public URL, for the links and "preview
  as anonymous").
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitPublishing.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Modules.Publishing.PostAccess
  alias PhoenixKit.Modules.Publishing.PostAccess.Viewer
  alias PhoenixKit.Modules.Publishing.PublishingAccessRule
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Roles

  @impl true
  def update(assigns, socket) do
    reload? = socket.assigns[:owner] != assigns.owner

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:public_url, fn -> nil end)
      |> assign_new(:new_link, fn -> nil end)
      |> assign_new(:message, fn -> nil end)
      |> assign_new(:adding, fn -> nil end)
      |> assign_new(:apply_preview, fn -> nil end)
      |> assign_new(:keep_custom, fn -> true end)

    # A new owner (the same panel id showing another post) starts without
    # the previous owner's freshly made link on screen.
    {:ok, if(reload?, do: socket |> assign(:new_link, nil) |> load(), else: socket)}
  end

  defp load(socket) do
    rules = PostAccess.list_rules(socket.assigns.owner)

    roles = safe_roles()

    socket
    |> assign(:rules, rules)
    |> assign(
      :gates,
      Enum.filter(
        rules,
        &(&1.kind in PublishingAccessRule.gate_kinds())
      )
    )
    |> assign(:summary, PostAccess.summary(rules))
    |> assign(:match, PostAccess.match_of(rules))
    |> assign(:list_protected, PostAccess.list_protected?(rules))
    |> assign(:roles, roles)
    |> assign(:role_names, Map.new(roles, &{&1.uuid, &1.name}))
  end

  defp safe_roles do
    Roles.list_roles()
  rescue
    _ -> []
  end

  # ===========================================================================
  # Events — each one re-checks the scope (a form can be posted by hand).
  # ===========================================================================

  @impl true
  def handle_event(event, params, socket) do
    if Scope.can?(socket.assigns.scope, "publishing") do
      do_event(event, params, socket)
    else
      {:noreply, assign(socket, :message, {:error, gettext("You can't change access.")})}
    end
  end

  defp do_event("start_add", %{"kind" => kind}, socket),
    do: {:noreply, assign(socket, adding: kind, new_link: nil, message: nil)}

  defp do_event("cancel_add", _params, socket), do: {:noreply, assign(socket, :adding, nil)}

  defp do_event("add_rule", %{"rule" => params}, socket) do
    params = resolve_users(params)

    result =
      case params["kind"] do
        "password" ->
          PostAccess.set_password(
            socket.assigns.owner,
            params["password"] || "",
            params,
            opts(socket)
          )

        "token" ->
          create_link(socket, params)

        _ ->
          PostAccess.add_rule(socket.assigns.owner, params, opts(socket))
      end

    case result do
      {:ok, _rule, key} ->
        {:noreply,
         socket |> load() |> assign(adding: nil, new_link: link_url(socket, key), message: nil)}

      {:ok, _rule} ->
        {:noreply,
         socket |> load() |> assign(adding: nil, message: {:info, gettext("Access updated.")})}

      {:error, reason} ->
        {:noreply, assign(socket, :message, {:error, error_message(reason)})}
    end
  end

  defp do_event("delete_rule", %{"uuid" => uuid}, socket) do
    with_own_rule(socket, uuid, fn -> PostAccess.delete_rule(uuid, opts(socket)) end)
  end

  defp do_event("revoke_link", %{"uuid" => uuid}, socket) do
    with_own_rule(socket, uuid, fn -> PostAccess.revoke_link(uuid, opts(socket)) end)
  end

  defp do_event("set_match", %{"match" => match}, socket) do
    {:ok, _} = PostAccess.put_settings(socket.assigns.owner, %{"match" => match}, opts(socket))
    {:noreply, load(socket)}
  end

  defp do_event("toggle_list_protected", _params, socket) do
    {:ok, _} =
      PostAccess.put_settings(
        socket.assigns.owner,
        %{"list_protected" => not socket.assigns.list_protected},
        opts(socket)
      )

    {:noreply, load(socket)}
  end

  defp do_event("make_public", _params, socket) do
    :ok = PostAccess.clear(socket.assigns.owner, opts(socket))

    {:noreply,
     socket
     |> load()
     |> assign(new_link: nil, message: {:info, gettext("Anyone can open it now.")})}
  end

  defp do_event("dismiss_link", _params, socket), do: {:noreply, assign(socket, :new_link, nil)}

  defp do_event("preview_apply", params, %{assigns: %{owner: {:group, group_uuid}}} = socket) do
    keep = params["keep_custom"] == "true"
    count = PostAccess.preview_group_defaults(group_uuid, keep_custom: keep)
    {:noreply, assign(socket, apply_preview: count, keep_custom: keep)}
  end

  defp do_event("apply_defaults", _params, %{assigns: %{owner: {:group, group_uuid}}} = socket) do
    {:ok, count} =
      PostAccess.apply_group_defaults(
        group_uuid,
        Keyword.put(opts(socket), :keep_custom, socket.assigns.keep_custom)
      )

    {:noreply,
     assign(socket,
       apply_preview: nil,
       message:
         {:info, ngettext("Applied to %{count} post.", "Applied to %{count} posts.", count)}
     )}
  end

  defp do_event(_event, _params, socket), do: {:noreply, socket}

  # A rule uuid comes from the page; it must belong to this panel's owner.
  defp with_own_rule(socket, uuid, fun) do
    if Enum.any?(socket.assigns.rules, &(&1.uuid == uuid)) do
      fun.()
      {:noreply, socket |> load() |> assign(:message, nil)}
    else
      {:noreply, socket}
    end
  end

  defp create_link(%{assigns: %{owner: {:post, _} = owner}} = socket, params),
    do: PostAccess.create_link(owner, params, opts(socket))

  defp create_link(_socket, _params), do: {:error, :links_are_per_post}

  # "user" rules are typed as e-mail addresses; each must be an account.
  defp resolve_users(%{"kind" => "user", "emails" => emails} = params) do
    found =
      emails
      |> String.split([",", " ", "\n", ";"], trim: true)
      |> Enum.map(&Auth.get_user_by_email(String.trim(&1)))

    if Enum.any?(found, &is_nil/1) or found == [] do
      Map.put(params, "user_uuids", [])
    else
      Map.put(params, "user_uuids", Enum.map(found, & &1.uuid))
    end
  end

  defp resolve_users(params), do: params

  defp opts(socket), do: [actor_uuid: Scope.user_uuid(socket.assigns.scope)]

  defp link_url(socket, key) do
    base = socket.assigns.public_url || ""
    separator = if String.contains?(base, "?"), do: "&", else: "?"
    base <> separator <> Viewer.key_param() <> "=" <> key
  end

  defp error_message(:password_too_short),
    do: gettext("The password needs at least 4 characters.")

  defp error_message(:empty_rule),
    do: gettext("Choose at least one role, or name accounts that exist.")

  defp error_message(_), do: gettext("That didn't save. Please check the values and try again.")

  # ===========================================================================
  # Render
  # ===========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="card bg-base-100 border border-base-300" data-access-panel>
      <div class="card-body gap-3 p-4">
        <div class="flex items-center justify-between gap-2">
          <h3 class="font-semibold flex items-center gap-2">
            <.icon name={if @gates == [], do: "hero-lock-open", else: "hero-lock-closed"} class="w-4 h-4" />
            {if group?(@owner), do: gettext("Default access for new posts"), else: gettext("Access")}
          </h3>
          <a
            :if={not group?(@owner) and @public_url}
            href={@public_url <> "?pk_preview=anonymous"}
            target="_blank"
            rel="noopener"
            class="link text-xs"
          >
            {gettext("Preview as anonymous")}
          </a>
        </div>

        <p class="text-sm" data-access-summary>{@summary}</p>

        <div :if={@message} class={["alert text-sm py-2", message_class(@message)]}>
          {elem(@message, 1)}
        </div>

        <div :if={@new_link} class="alert alert-success flex-col items-stretch gap-2 text-sm" data-new-link>
          <span>{gettext("Secret link created. Copy it now — it is not shown again.")}</span>
          <input type="text" readonly value={@new_link} class="input input-sm w-full font-mono text-xs" />
          <button type="button" phx-click="dismiss_link" phx-target={@myself} class="btn btn-xs self-end">
            {gettext("Done")}
          </button>
        </div>

        <ul :if={@gates != []} class="space-y-1 text-sm">
          <li :for={rule <- @gates} class="flex items-start justify-between gap-2" data-access-rule={rule.kind}>
            <span>
              {rule_label(rule, @role_names)}
              <span :if={rule.note} class="text-base-content/60">— {rule.note}</span>
              <span :if={rule.expires_at} class="text-base-content/60">
                {gettext("until %{date}", date: Date.to_iso8601(DateTime.to_date(rule.expires_at)))}
              </span>
              <span :if={rule.revoked_at} class="badge badge-ghost badge-xs">{gettext("revoked")}</span>
            </span>
            <span class="flex gap-1">
              <button
                :if={rule.kind == "token" and is_nil(rule.revoked_at)}
                type="button"
                phx-click="revoke_link"
                phx-value-uuid={rule.uuid}
                phx-target={@myself}
                class="btn btn-ghost btn-xs"
              >
                {gettext("Revoke")}
              </button>
              <button
                type="button"
                phx-click="delete_rule"
                phx-value-uuid={rule.uuid}
                phx-target={@myself}
                class="btn btn-ghost btn-xs btn-square"
                aria-label={gettext("Remove")}
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
            </span>
          </li>
        </ul>

        <form
          :if={length(Enum.uniq_by(@gates, & &1.kind)) > 1}
          id={"#{@id}-match"}
          phx-change="set_match"
          phx-target={@myself}
        >
          <select name="match" class="select select-sm w-full">
            <option value="any" selected={@match == "any"}>{gettext("Any one rule is enough")}</option>
            <option value="all" selected={@match == "all"}>{gettext("Every kind of rule must pass")}</option>
          </select>
        </form>

        <div :if={is_nil(@adding)} class="flex flex-wrap gap-1">
          <button
            :for={{kind, label} <- add_choices(@owner)}
            type="button"
            phx-click="start_add"
            phx-value-kind={kind}
            phx-target={@myself}
            class="btn btn-outline btn-xs"
          >
            <.icon name="hero-plus" class="w-3 h-3" /> {label}
          </button>
        </div>

        <form
          :if={@adding}
          id={"#{@id}-add"}
          phx-submit="add_rule"
          phx-target={@myself}
          class="space-y-2 rounded-box bg-base-200 p-3"
        >
          <input type="hidden" name="rule[kind]" value={@adding} />
          <div :if={@adding == "role"} class="space-y-1">
            <label :for={role <- @roles} class="flex items-center gap-2 text-sm">
              <input type="checkbox" name="rule[role_uuids][]" value={role.uuid} class="checkbox checkbox-xs" />
              {role.name}
            </label>
          </div>
          <textarea
            :if={@adding == "user"}
            name="rule[emails]"
            rows="2"
            placeholder={gettext("E-mail addresses of the accounts, one per line")}
            class="textarea textarea-sm w-full"
          ></textarea>
          <input
            :if={@adding == "password"}
            type="password"
            name="rule[password]"
            autocomplete="new-password"
            placeholder={gettext("New password")}
            class="input input-sm w-full"
          />
          <input
            type="text"
            name="rule[note]"
            maxlength="255"
            placeholder={
              if @adding == "token", do: gettext("Who is it for? (e.g. ACME Ltd)"), else: gettext("Note (optional)")
            }
            class="input input-sm w-full"
          />
          <label class="flex items-center gap-2 text-xs">
            {gettext("Ends on")}
            <input type="date" name="rule[expires_at]" class="input input-xs" />
          </label>
          <%!-- A new password keeps the current end date unless one is
               typed above or this box lifts it. --%>
          <label
            :if={@adding == "password" and Enum.any?(@gates, &(&1.kind == "password" and &1.expires_at))}
            class="flex items-center gap-2 text-xs"
            data-no-end-date
          >
            <input type="checkbox" name="rule[no_end_date]" value="true" class="checkbox checkbox-xs" />
            {gettext("No end date (remove the current one)")}
          </label>
          <div class="flex justify-end gap-1">
            <button type="button" phx-click="cancel_add" phx-target={@myself} class="btn btn-ghost btn-xs">
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary btn-xs">{gettext("Add")}</button>
          </div>
        </form>

        <label :if={group?(@owner)} class="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={@list_protected}
            phx-click="toggle_list_protected"
            phx-target={@myself}
            class="checkbox checkbox-sm"
          />
          {gettext("List protected posts to the readers who may open them")}
        </label>

        <form
          :if={group?(@owner)}
          id={"#{@id}-apply"}
          phx-change="preview_apply"
          phx-submit="apply_defaults"
          phx-target={@myself}
          class="space-y-2 border-t border-base-300 pt-3"
        >
          <label class="flex items-center gap-2 text-sm">
            <input type="hidden" name="keep_custom" value="false" />
            <input type="checkbox" name="keep_custom" value="true" checked={@keep_custom} class="checkbox checkbox-sm" />
            {gettext("Keep posts that have rules of their own")}
          </label>
          <div class="flex items-center justify-between gap-2">
            <button type="button" phx-click="preview_apply" phx-value-keep_custom={to_string(@keep_custom)} phx-target={@myself} class="btn btn-outline btn-xs">
              {gettext("Apply to existing posts…")}
            </button>
            <button :if={@apply_preview} type="submit" class="btn btn-warning btn-xs" data-apply-confirm>
              {ngettext("Change %{count} post", "Change %{count} posts", @apply_preview)}
            </button>
          </div>
        </form>

        <button
          :if={@gates != [] and not group?(@owner)}
          type="button"
          phx-click="make_public"
          phx-target={@myself}
          data-confirm={gettext("Remove every rule and secret link? Anyone will be able to open this post.")}
          class="btn btn-ghost btn-xs self-start"
        >
          {gettext("Make public")}
        </button>
      </div>
    </section>
    """
  end

  defp group?({:group, _}), do: true
  defp group?(_), do: false

  defp add_choices(owner) do
    base = [
      {"signed_in", gettext("Signed-in readers")},
      {"role", gettext("Roles")},
      {"user", gettext("Users")},
      {"password", gettext("Password")}
    ]

    if group?(owner), do: base, else: base ++ [{"token", gettext("Secret link")}]
  end

  defp rule_label(%{kind: "signed_in"}, _names), do: gettext("Signed-in readers")

  defp rule_label(%{kind: "role", config: config}, names) do
    roles =
      config
      |> Map.get("role_uuids", [])
      |> Enum.map_join(", ", &Map.get_lazy(names, &1, fn -> gettext("a deleted role") end))

    gettext("Roles: %{roles}", roles: roles)
  end

  defp rule_label(%{kind: "user", config: config}, _names) do
    count = config |> Map.get("user_uuids", []) |> length()
    ngettext("%{count} user", "%{count} users", count)
  end

  defp rule_label(%{kind: "password"}, _names), do: gettext("Password")
  defp rule_label(%{kind: "token"}, _names), do: gettext("Secret link")
  defp rule_label(_rule, _names), do: ""

  defp message_class({:error, _}), do: "alert-error"
  defp message_class(_), do: "alert-info"
end
