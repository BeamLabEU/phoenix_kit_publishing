defmodule PhoenixKit.Modules.Publishing.PubSub do
  @moduledoc """
  PubSub integration for real-time publishing updates.

  Provides broadcasting and subscription for post changes,
  enabling live updates across all connected admin clients.

  ## Features

  - Post lifecycle events (create, update, delete, status change)
  - Collaborative editing with real-time form state sync
  - Owner/spectator model for concurrent editing
  """

  alias PhoenixKit.PubSub.Manager

  @topic_prefix "publishing"
  @topic_editor_forms "publishing:editor_forms"
  @topic_groups "publishing:groups"

  @typep broadcast_result :: :ok | {:error, term()}
  @typep subscription_result :: :ok | {:error, term()}

  # ============================================================================
  # Post Identifier Resolution
  # ============================================================================

  @doc """
  Returns the broadcast identifier for a post.

  Always uses uuid — it's present on every post regardless of mode.
  """
  @spec broadcast_id(map()) :: String.t() | nil
  def broadcast_id(post) do
    post[:uuid]
  end

  # ============================================================================
  # Group-Level Updates (group creation/deletion)
  # ============================================================================

  @doc """
  Returns the topic for global group updates (create, delete).
  """
  @spec groups_topic() :: String.t()
  def groups_topic, do: @topic_groups

  @doc """
  Subscribes the current process to group updates (creation/deletion).
  """
  @spec subscribe_to_groups() :: subscription_result
  def subscribe_to_groups do
    Manager.subscribe(groups_topic())
  end

  @doc """
  Unsubscribes the current process from group updates.
  """
  @spec unsubscribe_from_groups() :: :ok
  def unsubscribe_from_groups do
    Manager.unsubscribe(groups_topic())
  end

  @doc """
  Broadcasts a group created event.
  """
  @spec broadcast_group_created(map()) :: broadcast_result
  def broadcast_group_created(group) do
    Manager.broadcast(groups_topic(), {:group_created, group})
  end

  @doc """
  Broadcasts a group deleted event.
  """
  @spec broadcast_group_deleted(String.t()) :: broadcast_result
  def broadcast_group_deleted(group_slug) do
    Manager.broadcast(groups_topic(), {:group_deleted, group_slug})
  end

  @doc """
  Broadcasts a group updated event.
  """
  @spec broadcast_group_updated(map()) :: broadcast_result
  def broadcast_group_updated(group) do
    Manager.broadcast(groups_topic(), {:group_updated, group})
  end

  # ============================================================================
  # Post List Updates (simple refresh)
  # ============================================================================

  @doc """
  Returns the topic for a specific group's posts.
  """
  @spec posts_topic(String.t()) :: String.t()
  def posts_topic(group_slug) do
    "#{@topic_prefix}:#{group_slug}:posts"
  end

  @doc """
  Subscribes the current process to post updates for a group.
  """
  @spec subscribe_to_posts(String.t()) :: subscription_result
  def subscribe_to_posts(group_slug) do
    Manager.subscribe(posts_topic(group_slug))
  end

  @doc """
  Unsubscribes the current process from post updates for a group.
  """
  @spec unsubscribe_from_posts(String.t()) :: :ok
  def unsubscribe_from_posts(group_slug) do
    Manager.unsubscribe(posts_topic(group_slug))
  end

  @doc """
  Broadcasts a post created event with a minimal payload (uuid + slug).

  Receivers only need the identifier to refresh their views — sending the
  full post map risks leaking title/body/metadata into pubsub trace logs.
  """
  @spec broadcast_post_created(String.t(), map()) :: broadcast_result
  def broadcast_post_created(group_slug, post) do
    Manager.broadcast(posts_topic(group_slug), {:post_created, minimal_payload(post)})
  end

  @doc """
  Broadcasts a post updated event with a minimal payload (uuid + slug).

  See `broadcast_post_created/2` for rationale on the trimmed payload.
  """
  @spec broadcast_post_updated(String.t(), map()) :: broadcast_result
  def broadcast_post_updated(group_slug, post) do
    Manager.broadcast(posts_topic(group_slug), {:post_updated, minimal_payload(post)})
  end

  # Strips a post map to the only fields receivers actually use, so
  # broadcasts don't leak title/body/version metadata into PubSub traces.
  defp minimal_payload(post) when is_map(post) do
    %{uuid: post[:uuid] || post["uuid"], slug: post[:slug] || post["slug"]}
  end

  defp minimal_payload(other), do: other

  @doc """
  Broadcasts a post deleted event.
  """
  @spec broadcast_post_deleted(String.t(), String.t()) :: broadcast_result
  def broadcast_post_deleted(group_slug, post_identifier) do
    Manager.broadcast(posts_topic(group_slug), {:post_deleted, post_identifier})
  end

  @doc """
  Broadcasts a post status changed event with a minimal payload (uuid + slug).

  Receivers refresh the post by slug/uuid; the full record never crosses
  PubSub. See `broadcast_post_created/2` for the trust rationale.
  """
  @spec broadcast_post_status_changed(String.t(), map()) :: broadcast_result
  def broadcast_post_status_changed(group_slug, post) do
    Manager.broadcast(posts_topic(group_slug), {:post_status_changed, minimal_payload(post)})
  end

  @doc """
  Broadcasts that a new version was created for a post.

  Payload is trimmed to `%{uuid:, slug:}` — receivers re-fetch the post
  to get the new `available_versions`/`version_statuses`/etc.
  """
  @spec broadcast_version_created(String.t(), map()) :: broadcast_result
  def broadcast_version_created(group_slug, post) do
    Manager.broadcast(posts_topic(group_slug), {:version_created, minimal_payload(post)})
  end

  @doc """
  Broadcasts that the live version changed for a post.
  """
  @spec broadcast_version_live_changed(String.t(), String.t(), pos_integer() | nil) ::
          broadcast_result
  def broadcast_version_live_changed(group_slug, post_identifier, version) do
    Manager.broadcast(posts_topic(group_slug), {:version_live_changed, post_identifier, version})
  end

  @doc """
  Broadcasts that a version was deleted from a post.
  """
  @spec broadcast_version_deleted(String.t(), String.t(), pos_integer()) :: broadcast_result
  def broadcast_version_deleted(group_slug, post_identifier, version) do
    Manager.broadcast(posts_topic(group_slug), {:version_deleted, post_identifier, version})
  end

  # ============================================================================
  # Post-Level Updates (version and translation changes)
  # ============================================================================

  @doc """
  Returns the topic for a specific post's version updates.
  This allows editors to receive notifications when versions are created/deleted.
  """
  @spec post_versions_topic(String.t(), String.t()) :: String.t()
  def post_versions_topic(group_slug, post_slug) do
    "#{@topic_prefix}:#{group_slug}:post:#{post_slug}:versions"
  end

  @doc """
  Subscribes to version updates for a specific post.
  """
  @spec subscribe_to_post_versions(String.t(), String.t()) :: subscription_result
  def subscribe_to_post_versions(group_slug, post_slug) do
    Manager.subscribe(post_versions_topic(group_slug, post_slug))
  end

  @doc """
  Unsubscribes from version updates for a specific post.
  """
  @spec unsubscribe_from_post_versions(String.t(), String.t()) :: :ok
  def unsubscribe_from_post_versions(group_slug, post_slug) do
    Manager.unsubscribe(post_versions_topic(group_slug, post_slug))
  end

  @doc """
  Broadcasts that a new version was created for a post (to post-level topic).
  """
  @spec broadcast_post_version_created(String.t(), String.t(), map()) :: broadcast_result
  def broadcast_post_version_created(group_slug, post_slug, version_info) do
    Manager.broadcast(
      post_versions_topic(group_slug, post_slug),
      {:post_version_created, group_slug, post_slug, version_info}
    )
  end

  @doc """
  Broadcasts that a version was deleted from a post (to post-level topic).
  """
  @spec broadcast_post_version_deleted(String.t(), String.t(), pos_integer()) :: broadcast_result
  def broadcast_post_version_deleted(group_slug, post_slug, version) do
    Manager.broadcast(
      post_versions_topic(group_slug, post_slug),
      {:post_version_deleted, group_slug, post_slug, version}
    )
  end

  @doc """
  Broadcasts that the live/published version changed (to post-level topic).
  Includes source_id so receivers can ignore their own broadcasts.
  """
  @spec broadcast_post_version_published(
          String.t(),
          String.t(),
          pos_integer() | nil,
          String.t() | nil
        ) :: broadcast_result
  def broadcast_post_version_published(group_slug, post_slug, version, source_id \\ nil) do
    Manager.broadcast(
      post_versions_topic(group_slug, post_slug),
      {:post_version_published, group_slug, post_slug, version, source_id}
    )
  end

  @doc """
  Returns the topic for a specific post's translation updates.
  This allows all editors of different language versions to receive updates
  when new translations are added.
  """
  @spec post_translations_topic(String.t(), String.t()) :: String.t()
  def post_translations_topic(group_slug, post_slug) do
    "#{@topic_prefix}:#{group_slug}:post:#{post_slug}:translations"
  end

  @doc """
  Subscribes to translation updates for a specific post.
  """
  @spec subscribe_to_post_translations(String.t(), String.t()) :: subscription_result
  def subscribe_to_post_translations(group_slug, post_slug) do
    Manager.subscribe(post_translations_topic(group_slug, post_slug))
  end

  @doc """
  Unsubscribes from translation updates for a specific post.
  """
  @spec unsubscribe_from_post_translations(String.t(), String.t()) :: :ok
  def unsubscribe_from_post_translations(group_slug, post_slug) do
    Manager.unsubscribe(post_translations_topic(group_slug, post_slug))
  end

  @doc """
  Broadcasts that a new translation was created for a post.
  """
  @spec broadcast_translation_created(String.t(), String.t(), String.t()) :: broadcast_result
  def broadcast_translation_created(group_slug, post_slug, language) do
    Manager.broadcast(
      post_translations_topic(group_slug, post_slug),
      {:translation_created, group_slug, post_slug, language}
    )
  end

  @doc """
  Broadcasts that a translation was deleted from a post.
  """
  @spec broadcast_translation_deleted(String.t(), String.t(), String.t()) :: broadcast_result
  def broadcast_translation_deleted(group_slug, post_slug, language) do
    Manager.broadcast(
      post_translations_topic(group_slug, post_slug),
      {:translation_deleted, group_slug, post_slug, language}
    )
  end

  # ============================================================================
  # Editor Save Sync (last-save-wins model)
  # ============================================================================

  @doc """
  Broadcasts that a post was saved, so other editors can reload.

  The `source` is the socket.id of the saver, so they don't reload their own save.
  """
  @spec broadcast_editor_saved(String.t(), String.t() | nil) :: broadcast_result
  def broadcast_editor_saved(form_key, source) do
    Manager.broadcast(
      editor_form_topic(form_key),
      {:editor_saved, form_key, source}
    )
  end

  # ============================================================================
  # Collaborative Editor (real-time form sync)
  # ============================================================================

  @doc """
  Returns the topic for a specific editor form.

  The form_key uniquely identifies a post being edited:
  - For existing posts: "group_slug:post_path" or "group_slug:slug"
  - For new posts: "group_slug:new:language"
  """
  @spec editor_form_topic(String.t()) :: String.t()
  def editor_form_topic(form_key) do
    "#{@topic_editor_forms}:#{form_key}"
  end

  @doc """
  Returns the presence topic for tracking editors of a post.
  """
  @spec editor_presence_topic(String.t()) :: String.t()
  def editor_presence_topic(form_key) do
    "publishing:presence:editor:#{form_key}"
  end

  @doc """
  Subscribes to collaborative events for a specific editor form.
  """
  @spec subscribe_to_editor_form(String.t()) :: subscription_result
  def subscribe_to_editor_form(form_key) do
    Manager.subscribe(editor_form_topic(form_key))
  end

  @doc """
  Unsubscribes from collaborative events for a specific editor form.
  """
  @spec unsubscribe_from_editor_form(String.t()) :: :ok
  def unsubscribe_from_editor_form(form_key) do
    Manager.unsubscribe(editor_form_topic(form_key))
  end

  @doc """
  Broadcasts a form state change to all subscribers.

  Options:
  - `:source` - The source identifier to prevent self-echoing
  """
  @spec broadcast_editor_form_change(String.t(), map(), keyword()) :: broadcast_result
  def broadcast_editor_form_change(form_key, payload, opts \\ []) do
    Manager.broadcast(
      editor_form_topic(form_key),
      {:editor_form_change, form_key, payload, Keyword.get(opts, :source)}
    )
  end

  @doc """
  Broadcasts a sync request for new joiners to get current state.
  """
  @spec broadcast_editor_sync_request(String.t(), String.t()) :: broadcast_result
  def broadcast_editor_sync_request(form_key, requester_socket_id) do
    Manager.broadcast(
      editor_form_topic(form_key),
      {:editor_sync_request, form_key, requester_socket_id}
    )
  end

  @doc """
  Broadcasts a sync response with current form state.
  """
  @spec broadcast_editor_sync_response(String.t(), String.t(), map()) :: broadcast_result
  def broadcast_editor_sync_response(form_key, requester_socket_id, state) do
    Manager.broadcast(
      editor_form_topic(form_key),
      {:editor_sync_response, form_key, requester_socket_id, state}
    )
  end

  # ============================================================================
  # Cache Updates (for live admin UI updates)
  # ============================================================================

  @doc """
  Returns the topic for cache updates for a specific group.
  """
  @spec cache_topic(String.t()) :: String.t()
  def cache_topic(group_slug) do
    "#{@topic_prefix}:#{group_slug}:cache"
  end

  @doc """
  Subscribes the current process to cache updates for a group.
  """
  @spec subscribe_to_cache(String.t()) :: subscription_result
  def subscribe_to_cache(group_slug) do
    Manager.subscribe(cache_topic(group_slug))
  end

  @doc """
  Unsubscribes the current process from cache updates for a group.
  """
  @spec unsubscribe_from_cache(String.t()) :: :ok
  def unsubscribe_from_cache(group_slug) do
    Manager.unsubscribe(cache_topic(group_slug))
  end

  @doc """
  Broadcasts that the cache state has changed (cache regenerated, memory loaded, etc).
  """
  @spec broadcast_cache_changed(String.t()) :: broadcast_result
  def broadcast_cache_changed(group_slug) do
    Manager.broadcast(cache_topic(group_slug), {:cache_changed, group_slug})
  end

  # ============================================================================
  # AI Translation Progress
  # ============================================================================

  @doc """
  Broadcasts that AI translation has started.
  Sent to both posts_topic (for group listing) and post_translations_topic (for editor).
  """
  @spec broadcast_translation_started(String.t(), String.t(), [String.t()]) :: broadcast_result
  def broadcast_translation_started(group_slug, post_slug, target_languages) do
    payload = {:translation_started, group_slug, post_slug, target_languages}

    # Broadcast to group listing
    Manager.broadcast(
      posts_topic(group_slug),
      {:translation_started, post_slug, length(target_languages)}
    )

    # Broadcast to editor (more detailed info)
    Manager.broadcast(post_translations_topic(group_slug, post_slug), payload)
  end

  @doc """
  Broadcasts AI translation progress (after each language completes).
  Sent to both posts_topic (for group listing) and post_translations_topic (for editor).
  """
  @spec broadcast_translation_progress(
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: broadcast_result
  def broadcast_translation_progress(group_slug, post_slug, completed, total, last_language) do
    # Broadcast to group listing
    Manager.broadcast(
      posts_topic(group_slug),
      {:translation_progress, post_slug, completed, total}
    )

    # Broadcast to editor (more detailed info)
    Manager.broadcast(
      post_translations_topic(group_slug, post_slug),
      {:translation_progress, group_slug, post_slug, completed, total, last_language}
    )
  end

  @doc """
  Broadcasts that AI translation has completed (success or partial failure).
  Sent to both posts_topic (for group listing) and post_translations_topic (for editor).
  """
  @spec broadcast_translation_completed(String.t(), String.t(), map()) :: broadcast_result
  def broadcast_translation_completed(group_slug, post_slug, results) do
    # Broadcast to group listing
    Manager.broadcast(
      posts_topic(group_slug),
      {:translation_completed, post_slug, results}
    )

    # Broadcast to editor
    Manager.broadcast(
      post_translations_topic(group_slug, post_slug),
      {:translation_completed, group_slug, post_slug, results}
    )
  end

  # ============================================================================
  # Editor Presence for Group Listing
  # ============================================================================

  @doc """
  Returns the global topic for editor activity across a group.
  Used by group listing to show who's editing what.
  """
  @spec group_editors_topic(String.t()) :: String.t()
  def group_editors_topic(group_slug) do
    "#{@topic_prefix}:#{group_slug}:editors"
  end

  @doc """
  Subscribes to editor activity for a group (used by group listing).
  """
  @spec subscribe_to_group_editors(String.t()) :: subscription_result
  def subscribe_to_group_editors(group_slug) do
    Manager.subscribe(group_editors_topic(group_slug))
  end

  @doc """
  Unsubscribes from editor activity for a group.
  """
  @spec unsubscribe_from_group_editors(String.t()) :: :ok
  def unsubscribe_from_group_editors(group_slug) do
    Manager.unsubscribe(group_editors_topic(group_slug))
  end

  @doc """
  Broadcasts that a user started editing a post.
  """
  @spec broadcast_editor_joined(String.t(), String.t(), map()) :: broadcast_result
  def broadcast_editor_joined(group_slug, post_slug, user_info) do
    Manager.broadcast(
      group_editors_topic(group_slug),
      {:editor_joined, post_slug, user_info}
    )
  end

  @doc """
  Broadcasts that a user stopped editing a post.
  """
  @spec broadcast_editor_left(String.t(), String.t(), map()) :: broadcast_result
  def broadcast_editor_left(group_slug, post_slug, user_info) do
    Manager.broadcast(
      group_editors_topic(group_slug),
      {:editor_left, post_slug, user_info}
    )
  end

  # ============================================================================
  # Form Key Helpers
  # ============================================================================

  @doc """
  Generates a form key for a post being edited.

  The form key includes the language to allow concurrent editing of different
  translations of the same post.

  ## Examples

      generate_form_key("blog", %{path: "blog/my-post/v1/en"})
      # => "blog:blog/my-post/v1/en"

      generate_form_key("blog", %{slug: "my-post", language: "en"})
      # => "blog:my-post:en"

      generate_form_key("blog", %{slug: "my-post", language: "en"}, :new)
      # => "blog:new:en"
  """
  @spec generate_form_key(String.t(), map(), :edit | :new) :: String.t()
  def generate_form_key(group_slug, post, mode \\ :edit)

  # UUID-based form key (preferred for DB posts)
  def generate_form_key(group_slug, %{uuid: uuid, language: lang}, :edit)
      when is_binary(uuid) and is_binary(lang) do
    "#{group_slug}:#{uuid}:#{lang}"
  end

  # Path already includes language (e.g., "blog/my-post/v1/en")
  def generate_form_key(group_slug, %{path: path}, :edit) when is_binary(path) do
    "#{group_slug}:#{path}"
  end

  # Slug mode - include language for per-language locking
  def generate_form_key(group_slug, %{slug: slug, language: lang}, :edit)
      when is_binary(slug) and is_binary(lang) do
    "#{group_slug}:#{slug}:#{lang}"
  end

  # Fallback for slug without language (shouldn't happen in practice)
  def generate_form_key(group_slug, %{slug: slug}, :edit) when is_binary(slug) do
    "#{group_slug}:#{slug}"
  end

  def generate_form_key(group_slug, %{language: lang}, :new) do
    "#{group_slug}:new:#{lang}"
  end

  def generate_form_key(group_slug, _post, :new) do
    "#{group_slug}:new"
  end

  def generate_form_key(group_slug, _, _) do
    "#{group_slug}:unknown"
  end
end
