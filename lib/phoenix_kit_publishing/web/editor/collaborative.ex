defmodule PhoenixKit.Modules.Publishing.Web.Editor.Collaborative do
  @moduledoc """
  Collaborative editing functionality for the publishing editor.

  Handles presence tracking, lock management, spectator mode,
  real-time form sync, and lock expiration.
  """

  use Gettext, backend: PhoenixKitPublishing.Gettext

  alias PhoenixKit.Modules.Publishing.PresenceHelpers
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub

  require Logger

  # How long an idle editor keeps the lock, in minutes. A setting because the
  # right number is a fact about the team, not about the software: 30 minutes
  # is generous for a newsroom passing a story around and impatient for
  # someone drafting an essay over lunch. Whoever is waiting for the lock and
  # whoever is thinking are the same person's colleagues.
  @default_lock_timeout_minutes 30
  # Always warn this long before it goes, so the notice is useful at any
  # timeout rather than proportionally silly at short ones.
  @lock_warning_lead_seconds 5 * 60
  # Check every minute
  @lock_check_interval_ms 60_000

  # ============================================================================
  # Setup Functions
  # ============================================================================

  @doc """
  Sets up collaborative editing for initial load.
  old_form_key and old_post_slug should be captured BEFORE the socket is updated.
  """
  def setup_collaborative_editing(socket, form_key, opts) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    if Phoenix.LiveView.connected?(socket) && form_key && current_user do
      do_setup_collaborative_editing(socket, form_key, current_user, opts)
    else
      assign_default_editing_state(socket)
    end
  end

  defp do_setup_collaborative_editing(socket, form_key, current_user, opts) do
    old_form_key = Keyword.get(opts, :old_form_key)
    old_post_slug = Keyword.get(opts, :old_post_slug)

    try do
      cleanup_old_presence(old_form_key, form_key, socket, old_post_slug)
      track_and_subscribe(form_key, socket, current_user)
      subscribe_to_post_translations(socket)
      subscribe_to_post_versions(socket)

      # Cleared up front: switching language or version rebuilds this socket
      # around a different row, so a marker left over from the previous one
      # would make the next promotion adopt a buffer for the wrong content.
      socket
      |> clear_synced_from_owner()
      |> assign_editing_role(form_key)
      |> maybe_broadcast_editor_joined()
      |> maybe_load_spectator_state(form_key)
      |> maybe_start_lock_expiration_timer()
    rescue
      ArgumentError ->
        Logger.warning(
          "Publishing Presence not available - collaborative editing disabled. " <>
            "Ensure PhoenixKit.Supervisor starts before your Endpoint in application.ex"
        )

        assign_default_editing_state(socket)
    end
  end

  @doc """
  Used when we know the old form_key (e.g., when switching languages/versions).
  """
  def cleanup_and_setup_collaborative_editing(socket, old_form_key, new_form_key, opts) do
    current_user = socket.assigns[:phoenix_kit_current_user]
    old_post_slug = Keyword.get(opts, :old_post_slug)

    if Phoenix.LiveView.connected?(socket) && new_form_key && current_user do
      try do
        cleanup_old_presence(old_form_key, new_form_key, socket, old_post_slug)
        setup_new_presence(socket, new_form_key, current_user)
      rescue
        ArgumentError ->
          assign_default_editing_state(socket)
      end
    else
      assign_default_editing_state(socket)
    end
  end

  # ============================================================================
  # Cleanup Functions
  # ============================================================================

  defp cleanup_old_presence(old_form_key, form_key, socket, old_post_slug) do
    if old_form_key && old_form_key != form_key do
      PresenceHelpers.untrack_editing_session(old_form_key, socket)
      PresenceHelpers.unsubscribe_from_editing(old_form_key)
      PublishingPubSub.unsubscribe_from_editor_form(old_form_key)

      # Unsubscribe from old post's translation and version topics using the OLD slug
      group_slug = socket.assigns[:group_slug]

      if group_slug && old_post_slug do
        PublishingPubSub.unsubscribe_from_post_translations(group_slug, old_post_slug)
        PublishingPubSub.unsubscribe_from_post_versions(group_slug, old_post_slug)
      end

      # Broadcast editor left to group listing for the OLD post
      broadcast_editor_left_for_post(socket, old_post_slug)
    end
  end

  defp setup_new_presence(socket, form_key, current_user) do
    case PresenceHelpers.track_editing_session(form_key, socket, current_user) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _pid, _topic, _key}} -> :ok
    end

    PresenceHelpers.subscribe_to_editing(form_key)
    PublishingPubSub.subscribe_to_editor_form(form_key)
    subscribe_to_post_translations(socket)
    subscribe_to_post_versions(socket)

    # Same up-front clear as the context-switch path above: a leftover
    # synced-from-owner marker from a previous form key would make the next
    # promotion adopt a buffer that belonged to different content.
    socket
    |> clear_synced_from_owner()
    |> assign_editing_role(form_key)
    |> maybe_broadcast_editor_joined()
    |> maybe_load_spectator_state(form_key)
    |> maybe_start_lock_expiration_timer()
  end

  @doc """
  Broadcast editor left for a specific post slug (used when we've already switched posts).
  """
  def broadcast_editor_left_for_post(socket, post_slug) do
    group_slug = socket.assigns[:group_slug]

    if group_slug && post_slug do
      user_info = build_user_info(socket, nil)
      PublishingPubSub.broadcast_editor_left(group_slug, post_slug, user_info)
    end
  end

  @doc """
  Unsubscribe from current post's topics (used in terminate when LiveView closes).
  """
  def unsubscribe_from_old_post_topics(socket) do
    group_slug = socket.assigns[:group_slug]
    post_slug = socket.assigns[:post] && PublishingPubSub.broadcast_id(socket.assigns.post)

    if group_slug && post_slug do
      PublishingPubSub.unsubscribe_from_post_translations(group_slug, post_slug)
      PublishingPubSub.unsubscribe_from_post_versions(group_slug, post_slug)
    end
  end

  # ============================================================================
  # Tracking and Subscription
  # ============================================================================

  defp track_and_subscribe(form_key, socket, current_user) do
    case PresenceHelpers.track_editing_session(form_key, socket, current_user) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _pid, _topic, _key}} -> :ok
    end

    PresenceHelpers.subscribe_to_editing(form_key)
    PublishingPubSub.subscribe_to_editor_form(form_key)
  end

  defp subscribe_to_post_translations(socket) do
    case PublishingPubSub.broadcast_id(socket.assigns[:post]) do
      id when is_binary(id) ->
        PublishingPubSub.subscribe_to_post_translations(socket.assigns.group_slug, id)

      _ ->
        :ok
    end
  end

  defp subscribe_to_post_versions(socket) do
    case PublishingPubSub.broadcast_id(socket.assigns[:post]) do
      id when is_binary(id) ->
        PublishingPubSub.subscribe_to_post_versions(socket.assigns.group_slug, id)

      _ ->
        :ok
    end
  end

  # ============================================================================
  # Role Management
  # ============================================================================

  @doc """
  Assigns the editing role (owner or spectator) based on presence.
  """
  def assign_editing_role(socket, form_key) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    case PresenceHelpers.get_editing_role(form_key, socket.id, current_user.uuid) do
      {:owner, _presences} ->
        # I'm the owner - I can edit
        socket
        |> Phoenix.Component.assign(:lock_owner?, true)
        |> Phoenix.Component.assign(:readonly?, false)
        |> populate_presence_info(form_key)

      {:spectator, _owner_meta, _presences} ->
        # Different user is the owner - I'm read-only
        socket
        |> Phoenix.Component.assign(:lock_owner?, false)
        |> Phoenix.Component.assign(:readonly?, true)
        |> populate_presence_info(form_key)
    end
  end

  @doc """
  Assigns default editing state when collaborative editing is not available.
  """
  def assign_default_editing_state(socket) do
    socket
    |> Phoenix.Component.assign(:lock_owner?, true)
    |> Phoenix.Component.assign(:readonly?, false)
    |> Phoenix.Component.assign(:lock_owner_user, nil)
    |> Phoenix.Component.assign(:spectators, [])
    |> Phoenix.Component.assign(:other_viewers, [])
    |> clear_synced_from_owner()
  end

  defp populate_presence_info(socket, form_key) do
    presences = PresenceHelpers.get_sorted_presences(form_key)

    my_user_uuid =
      socket.assigns[:phoenix_kit_current_user] && socket.assigns.phoenix_kit_current_user.uuid

    {lock_owner_user, spectators, other_viewers} =
      case presences do
        [] ->
          {nil, [], []}

        [{_owner_socket_id, owner_meta} | spectator_list] ->
          spectators =
            Enum.map(spectator_list, fn {_socket_id, meta} ->
              %{
                user: meta.user,
                user_uuid: meta.user_uuid,
                user_email: meta.user_email
              }
            end)

          # Other viewers = all presences from OTHER users (not just other sockets)
          other_viewers =
            presences
            |> Enum.reject(fn {_socket_id, meta} -> meta.user_uuid == my_user_uuid end)
            |> Enum.map(fn {_socket_id, meta} ->
              %{
                user: meta.user,
                user_uuid: meta.user_uuid,
                user_email: meta.user_email
              }
            end)
            |> Enum.uniq_by(& &1.user_uuid)

          {owner_meta.user, spectators, other_viewers}
      end

    socket
    |> Phoenix.Component.assign(:lock_owner_user, lock_owner_user)
    |> Phoenix.Component.assign(:spectators, spectators)
    |> Phoenix.Component.assign(:other_viewers, other_viewers)
  end

  defp maybe_load_spectator_state(socket, form_key) do
    if socket.assigns.readonly?, do: load_spectator_state(socket, form_key), else: socket
  end

  defp load_spectator_state(socket, form_key) do
    # Request current state from the owner so we see their unsaved changes.
    # The owner handles :editor_sync_request and responds with form + content.
    PublishingPubSub.broadcast_editor_sync_request(form_key, socket.id)
    socket
  end

  # ============================================================================
  # Broadcasting
  # ============================================================================

  @doc """
  Only broadcast editor_joined if user is the owner (not a spectator).
  """
  def maybe_broadcast_editor_joined(socket) do
    if socket.assigns[:lock_owner?] do
      broadcast_editor_activity(socket, :joined)
    end

    socket
  end

  @doc """
  Broadcast editor activity to group listing (for showing who's editing).
  """
  def broadcast_editor_activity(socket, action, user \\ nil) do
    group_slug = socket.assigns[:group_slug]
    post = socket.assigns[:post]

    broadcast_id = post && post[:uuid]

    if group_slug && broadcast_id do
      user_info = build_user_info(socket, user)

      case action do
        :joined ->
          PublishingPubSub.broadcast_editor_joined(group_slug, broadcast_id, user_info)

        :left ->
          PublishingPubSub.broadcast_editor_left(group_slug, broadcast_id, user_info)
      end
    end
  end

  @doc """
  Broadcast form changes to spectators (only owners broadcast).
  """
  def broadcast_form_change(socket, type, payload) do
    form_key = socket.assigns[:form_key]
    is_owner = socket.assigns[:lock_owner?]

    if form_key && is_owner do
      PublishingPubSub.broadcast_editor_form_change(
        form_key,
        %{type: type, data: payload},
        source: socket.id
      )
    end
  end

  @doc """
  Build user info for broadcasts.
  """
  def build_user_info(socket, user) do
    user = user || socket.assigns[:phoenix_kit_current_user]
    # Include role to distinguish editors from spectators
    role = if socket.assigns[:lock_owner?], do: :owner, else: :spectator

    if user do
      %{
        id: user.uuid,
        email: user.email,
        socket_id: socket.id,
        role: role
      }
    else
      %{socket_id: socket.id, role: role}
    end
  end

  # ============================================================================
  # Form Sync
  # ============================================================================

  @doc """
  Apply remote form state (for spectators receiving initial sync).
  """
  def apply_remote_form_state(socket, form_state) do
    form = Map.get(form_state, :form) || Map.get(form_state, "form") || socket.assigns.form

    content =
      Map.get(form_state, :content) || Map.get(form_state, "content") || socket.assigns.content

    # Unlike a live edit, this sync fires for every spectator the moment they
    # arrive, whether or not the owner has touched anything. When the owner is
    # simply sitting on the post, it carries exactly what this socket already
    # read from the row — so calling that "unsaved changes" would badge a
    # watcher who is looking at saved text, and would make a later promotion
    # adopt-and-rewrite a paragraph nobody edited.
    ahead? = content != socket.assigns.content or form != socket.assigns.form

    socket
    |> Phoenix.Component.assign(:form, form)
    |> Phoenix.Component.assign(:content, content)
    |> then(fn socket ->
      if ahead? do
        socket
        |> Phoenix.Component.assign(:has_pending_changes, true)
        |> mark_synced_from_owner()
      else
        socket
      end
    end)
    |> Phoenix.LiveView.push_event("set-content", %{content: content})
    |> Phoenix.LiveView.push_event("form-updated", %{form: form})
  end

  @doc """
  Apply remote form changes (for spectators receiving updates).
  """
  def apply_remote_form_change(socket, %{type: :meta, data: new_form}) do
    # Status is version-level — all languages share the same status
    new_status = new_form["status"]
    available_langs = Map.get(socket.assigns.post, :available_languages, [])
    updated_language_statuses = Map.new(available_langs, fn lang -> {lang, new_status} end)

    updated_post =
      socket.assigns.post
      |> Map.put(:metadata, Map.merge(socket.assigns.post.metadata, %{status: new_status}))
      |> Map.put(:language_statuses, updated_language_statuses)

    socket
    |> Phoenix.Component.assign(:form, new_form)
    |> Phoenix.Component.assign(:post, updated_post)
    |> mark_synced_from_owner()
    |> Phoenix.LiveView.push_event("form-updated", %{form: new_form})
  end

  def apply_remote_form_change(socket, %{type: :content, data: %{content: content, form: form}}) do
    socket
    |> Phoenix.Component.assign(:content, content)
    |> Phoenix.Component.assign(:form, form)
    |> mark_synced_from_owner()
    |> Phoenix.LiveView.push_event("set-content", %{content: content})
    |> Phoenix.LiveView.push_event("form-updated", %{form: form})
  end

  def apply_remote_form_change(socket, _payload) do
    # Ignore unrecognized payload types
    socket
  end

  @doc """
  Records that this socket is holding the owner's unsaved buffer.

  A spectator mirrors the owner keystroke by keystroke, so between the owner's
  last autosave and their next one, this socket is the only place that text
  exists outside the owner's browser. If presence then promotes this spectator
  — the owner closed the tab, lost the network, crashed — the promotion path
  must adopt what it is already showing instead of re-reading the older saved
  row, which would silently delete the difference.

  The flag means "the buffer I hold is ahead of the database". It is set for
  exactly the window that matters — from the owner's keystroke until their
  autosave lands — because anything that brings this socket back in line with
  the row clears it: a reload after someone else's save, or a promotion that
  chose the saved copy.
  """
  def mark_synced_from_owner(socket) do
    Phoenix.Component.assign(socket, :synced_from_owner?, true)
  end

  @doc """
  Clears the ahead-of-database marker. See `mark_synced_from_owner/1`.
  """
  def clear_synced_from_owner(socket) do
    Phoenix.Component.assign(socket, :synced_from_owner?, false)
  end

  # ============================================================================
  # Lock Expiration
  # ============================================================================

  @doc """
  Update activity timestamp on user interactions.
  """
  def touch_activity(socket) do
    socket
    |> Phoenix.Component.assign(:last_activity_at, System.monotonic_time(:second))
    |> Phoenix.Component.assign(:lock_warning_shown, false)
  end

  @doc """
  Conditionally start lock expiration timer after role assignment.
  """
  def maybe_start_lock_expiration_timer(socket) do
    if socket.assigns[:lock_owner?] && !socket.assigns[:readonly?] do
      socket
      |> touch_activity()
      |> start_lock_expiration_timer()
    else
      socket
    end
  end

  @doc """
  Start lock expiration timer (only for owners).
  """
  def start_lock_expiration_timer(socket) do
    if socket.assigns[:lock_owner?] do
      cancel_lock_expiration_timer(socket)
      timer_ref = Process.send_after(self(), :check_lock_expiration, @lock_check_interval_ms)
      Phoenix.Component.assign(socket, :lock_expiration_timer, timer_ref)
    else
      socket
    end
  end

  @doc """
  Cancel lock expiration timer.
  """
  def cancel_lock_expiration_timer(socket) do
    if socket.assigns[:lock_expiration_timer] do
      Process.cancel_timer(socket.assigns.lock_expiration_timer)
    end

    Phoenix.Component.assign(socket, :lock_expiration_timer, nil)
  end

  @doc """
  Check if lock should expire or warn user.
  """
  def check_lock_expiration(socket) do
    if socket.assigns[:lock_owner?] do
      now = System.monotonic_time(:second)
      last_activity = socket.assigns[:last_activity_at] || now
      inactive_seconds = now - last_activity

      cond do
        # Lock expired - release it
        inactive_seconds >= lock_timeout_seconds() ->
          release_lock_due_to_inactivity(socket)

        # Approaching expiration - warn user
        inactive_seconds >= lock_timeout_seconds() - @lock_warning_lead_seconds &&
            !socket.assigns[:lock_warning_shown] ->
          minutes_left = div(lock_timeout_seconds() - inactive_seconds, 60)

          socket
          |> Phoenix.Component.assign(:lock_warning_shown, true)
          |> Phoenix.LiveView.put_flash(
            :warning,
            gettext("Your editing lock will expire in %{minutes} minutes due to inactivity",
              minutes: minutes_left
            )
          )
          |> start_lock_expiration_timer()

        # Still active - schedule next check
        true ->
          start_lock_expiration_timer(socket)
      end
    else
      socket
    end
  end

  # Minutes, read per check so a change takes effect without a restart. Clamped
  # low: a timeout under a minute would release the lock between keystrokes.
  defp lock_timeout_seconds do
    minutes =
      case PhoenixKit.Settings.get_setting_cached("publishing_editor_lock_minutes") do
        value when is_integer(value) and value > 0 ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {n, _} when n > 0 -> n
            _ -> @default_lock_timeout_minutes
          end

        _ ->
          @default_lock_timeout_minutes
      end

    max(minutes, 1) * 60
  end

  @doc """
  Release lock due to inactivity.
  """
  def release_lock_due_to_inactivity(socket) do
    form_key = socket.assigns[:form_key]

    if form_key do
      # Untrack from presence to release lock
      PresenceHelpers.untrack_editing_session(form_key, socket)

      # Broadcast editor left
      broadcast_editor_activity(socket, :left)

      # Keep subscribed but become a spectator
      socket
      |> Phoenix.Component.assign(:lock_owner?, false)
      |> Phoenix.Component.assign(:readonly?, true)
      |> Phoenix.Component.assign(:lock_warning_shown, false)
      |> cancel_lock_expiration_timer()
      |> Phoenix.Component.assign(:lock_released_by_timeout, true)
      |> Phoenix.LiveView.put_flash(
        :warning,
        gettext("Your editing lock was released due to inactivity. Click anywhere to reclaim it.")
      )
    else
      socket
    end
  end

  @doc """
  Attempts to reclaim the editing lock after it was released due to inactivity.

  Called on user interaction when `lock_released_by_timeout` is true.
  Re-tracks presence, reclaims ownership if no other user holds the lock,
  and restarts the expiration timer.
  """
  def try_reclaim_lock(socket) do
    form_key = socket.assigns[:form_key]
    current_user = socket.assigns[:phoenix_kit_current_user]

    if form_key && current_user && socket.assigns[:lock_released_by_timeout] do
      # Re-track in presence
      case PresenceHelpers.track_editing_session(form_key, socket, current_user) do
        {:ok, _ref} -> :ok
        {:error, {:already_tracked, _pid, _topic, _key}} -> :ok
      end

      # Re-evaluate role (will be owner if no one else took the lock)
      socket
      |> assign_editing_role(form_key)
      |> Phoenix.Component.assign(:lock_released_by_timeout, false)
      |> maybe_reclaim_success()
    else
      socket
    end
  end

  defp maybe_reclaim_success(socket) do
    if socket.assigns[:lock_owner?] do
      socket
      |> maybe_broadcast_editor_joined()
      |> maybe_start_lock_expiration_timer()
      |> Phoenix.LiveView.clear_flash()
    else
      socket
    end
  end
end
