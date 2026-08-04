defmodule PhoenixKit.Modules.Publishing.Comments do
  @moduledoc """
  Optional seam to `phoenix_kit_comments` — same posture as the
  `phoenix_kit_og` plugin seam: publishing has NO dep on the comments
  package; every call is `Code.ensure_loaded?` + `function_exported?`
  guarded and rescued, so a host without the module (or with it disabled
  from `/admin/modules`) renders publishing pages with no comments UI and
  no crashes.

  Comments attach to `resource_type: "publishing_post"` with the post uuid,
  matching the ecosystem convention (staff/CRM tabs, core's media
  annotations). Public commenting is **logged-in only** for now — the
  comments schema requires a `user_uuid`; guest commenting needs a
  comments-module change (tracked in the roadmap as a cross-repo
  follow-up).
  """

  use Gettext, backend: PhoenixKitPublishing.Gettext

  require Logger

  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.DBStorage

  @comments_mod PhoenixKitComments
  @compile {:no_warn_undefined, [PhoenixKitComments, PhoenixKitComments.Web.Markdown]}

  @resource_type "publishing_post"

  @doc "True when the comments module is installed AND enabled."
  def available? do
    Code.ensure_loaded?(@comments_mod) and
      function_exported?(@comments_mod, :enabled?, 0) and
      @comments_mod.enabled?()
  rescue
    _ -> false
  end

  @doc "Published comments for a post, oldest first, with authors preloaded."
  def list(post_uuid) do
    if available?() do
      @comments_mod.list_comments(@resource_type, post_uuid,
        status: "published",
        preload: [:user]
      )
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Everything the post page needs in one read, pre-partitioned:

  - `:thread` — the main comment thread as a nested tree (each comment
    gets a `:children` list), replies attached via `parent_uuid`;
  - `:note_comments` — `%{note_id => [comments]}` for comments carrying a
    `metadata["note_id"]` (posted from a note's slide-out panel), each
    note's list a nested tree like the main thread (replies inherit the
    parent's note_id, so a whole thread lives in one panel);
  - `:count` — main-thread comment count (replies included, note
    comments excluded — the "N comments" header describes the thread the
    reader is looking at).
  """
  def for_post_page(post_uuid, known_note_ids \\ nil) do
    comments = list(post_uuid)

    # A comment only counts as note-scoped if its note still EXISTS on the
    # post. Note ids are a digest of the note's text, so rewording a note (or
    # switching the group back to footnote style, where there are no panels at
    # all) would otherwise leave its whole thread stored but rendered nowhere:
    # excluded from the main list for having a note_id, and never read by any
    # panel. Unknown ids fold back into the main thread instead — visible and
    # counted. `nil` means "caller didn't say", so trust every note_id.
    known = known_note_ids && MapSet.new(known_note_ids)

    {note_scoped, main} =
      Enum.split_with(comments, fn comment ->
        note_id = comment.metadata["note_id"]
        is_binary(note_id) and (is_nil(known) or MapSet.member?(known, note_id))
      end)

    note_comments =
      note_scoped
      |> Enum.group_by(& &1.metadata["note_id"])
      |> Map.new(fn {note_id, comments} -> {note_id, build_tree(comments)} end)

    %{
      thread: build_tree(main),
      note_comments: note_comments,
      count: length(main)
    }
  rescue
    # Every sibling in this seam degrades rather than raising, and this one runs
    # on EVERY public post render — an unrescued raise here would 500 a page
    # that used to just show no comments.
    _ -> %{thread: [], note_comments: %{}, count: 0}
  end

  @doc "Total node count of a comment tree (a panel's thread size)."
  def tree_size(comments) when is_list(comments) do
    Enum.reduce(comments, 0, fn comment, acc ->
      # `|| []`: an unpopulated :children (nil) must not crash the count.
      acc + 1 + tree_size(Map.get(comment, :children) || [])
    end)
  end

  def tree_size(_), do: 0

  # Nested tree from the flat (oldest-first) list. A reply whose parent is
  # missing from the published set (hidden/deleted parent, or a parent that
  # lives in a note panel) surfaces at the top level rather than vanishing.
  defp build_tree(comments) do
    known = MapSet.new(comments, & &1.uuid)
    by_parent = Enum.group_by(comments, & &1.parent_uuid)

    comments
    |> Enum.filter(fn c -> is_nil(c.parent_uuid) or not MapSet.member?(known, c.parent_uuid) end)
    |> Enum.map(&attach_children(&1, by_parent))
  end

  defp attach_children(comment, by_parent) do
    children =
      by_parent
      |> Map.get(comment.uuid, [])
      |> Enum.map(&attach_children(&1, by_parent))

    Map.put(comment, :children, children)
  end

  @doc "Published-comment count for a post."
  def count(post_uuid) do
    if available?() do
      @comments_mod.count_comments(@resource_type, post_uuid, status: "published")
    else
      0
    end
  rescue
    _ -> 0
  end

  @doc """
  Creates a comment on a post for a logged-in user. Returns the comments
  module's result verbatim (`{:ok, comment}` or `{:error, reason}` —
  `:content_too_long`, `:empty_comment`, `:max_depth_exceeded`, …).

  ## Options

  - `:parent_uuid` — makes this a reply. The parent must be a published
    comment on the SAME post (the comments module computes depth from the
    parent but does not check resource ownership — a crafted uuid could
    otherwise thread onto another post's comment). A reply inherits its
    parent's `note_id`, so a thread never straddles the main list and a
    note panel.
  - `:note_id` — anchors the comment to an author note (posted from the
    note's slide-out panel). Stored in `metadata["note_id"]`.
  """
  def create(post_uuid, user_uuid, content, opts \\ []) when is_binary(content) do
    if available?() do
      case resolve_threading(post_uuid, opts) do
        {:ok, attrs} ->
          @resource_type
          |> @comments_mod.create_comment(post_uuid, user_uuid, Map.put(attrs, :content, content))
          |> log_created(post_uuid, user_uuid, attrs)

        {:error, _reason} = err ->
          log_created(err, post_uuid, user_uuid, %{})
      end
    else
      {:error, :comments_unavailable}
    end
  rescue
    _ -> {:error, :comments_unavailable}
  end

  # A comment was the one publishing mutation that left no audit trail at all,
  # and the one most obviously worth telling somebody about.
  #
  # `target_uuid` is what turns an activity into a notification — core skips
  # the fan-out when it is nil, which is why publishing generated none. The
  # recipient is whoever is being replied to: the parent commenter for a
  # reply, the post's author otherwise. Never the actor, or core would skip
  # it anyway (you don't need telling that you commented).
  defp log_created({:ok, comment} = result, post_uuid, user_uuid, attrs) do
    do_log_created(comment, post_uuid, user_uuid, attrs)
    result
  rescue
    error ->
      # `create/4` wraps its whole body in a rescue that reports
      # `:comments_unavailable`, so an exception raised while writing the
      # audit row would tell the reader their comment failed — after it had
      # been saved. Audit trouble must stay audit trouble.
      Logger.warning("[Publishing] comment activity log failed: #{Exception.message(error)}")
      result
  end

  # The failed branch still leaves an audit row (db_pending) — a visitor's
  # comment vanishing without trace is exactly the mutation an admin will
  # be asked about. Content never goes in the metadata (free text); the
  # action/resource shape mirrors the success row in do_log_created/4.
  defp log_created({:error, reason} = err, post_uuid, user_uuid, attrs) do
    reply? = is_binary(Map.get(attrs, :parent_uuid))

    ActivityLog.log_failed_mutation(
      if(reply?, do: "publishing.comment.replied", else: "publishing.comment.created"),
      user_uuid,
      "publishing_post",
      post_uuid,
      %{"reason" => ActivityLog.reason_string(reason)}
    )

    err
  rescue
    error ->
      Logger.warning("[Publishing] comment activity log failed: #{Exception.message(error)}")
      err
  end

  defp log_created(other, _post_uuid, _user_uuid, _attrs), do: other

  defp do_log_created(comment, post_uuid, user_uuid, attrs) do
    post = safe_get_post(post_uuid)
    reply? = is_binary(Map.get(attrs, :parent_uuid))
    recipient = recipient_for(reply?, Map.get(attrs, :parent_uuid), post)

    ActivityLog.log(%{
      action: if(reply?, do: "publishing.comment.replied", else: "publishing.comment.created"),
      mode: "manual",
      actor_uuid: user_uuid,
      target_uuid: if(recipient && recipient != user_uuid, do: recipient),
      resource_type: "publishing_post",
      resource_uuid: post_uuid,
      metadata: %{
        "comment_uuid" => Map.get(comment, :uuid),
        # The post row carries the slug; the title lives on the per-language
        # content row, so it isn't reachable from here without another read.
        "post_slug" => post && post.slug,
        "notification_text" =>
          if(reply?,
            do: gettext("Someone replied to your comment"),
            else: gettext("New comment on your post")
          ),
        "notification_icon" => "hero-chat-bubble-left-right"
      }
    })
  end

  defp recipient_for(true, parent_uuid, post) do
    case @comments_mod.get_comment(parent_uuid) do
      %{user_uuid: uuid} when is_binary(uuid) -> uuid
      _ -> post && post.created_by_uuid
    end
  rescue
    _ -> post && post.created_by_uuid
  end

  defp recipient_for(false, _parent_uuid, post), do: post && post.created_by_uuid

  defp safe_get_post(post_uuid) do
    DBStorage.get_post_by_uuid(post_uuid)
  rescue
    _ -> nil
  end

  defp resolve_threading(post_uuid, opts) do
    case Keyword.get(opts, :parent_uuid) do
      nil ->
        {:ok, note_attrs(%{}, Keyword.get(opts, :note_id))}

      parent_uuid ->
        resolve_parent(post_uuid, parent_uuid, Keyword.get(opts, :note_id))
    end
  end

  # Cast first: repo().get raises on a non-uuid string, and the outer
  # rescue would mislabel that as :comments_unavailable.
  defp resolve_parent(post_uuid, parent_uuid, _note_id) when is_binary(parent_uuid) do
    # A reply's note anchor comes from the PARENT alone — honoring a
    # client-sent note_id here would let a crafted request split a thread
    # across the main list and a panel.
    with {:ok, _} <- Ecto.UUID.cast(parent_uuid),
         %{resource_type: @resource_type, resource_uuid: ^post_uuid, status: "published"} =
           parent <-
           @comments_mod.get_comment(parent_uuid) do
      {:ok, note_attrs(%{parent_uuid: parent.uuid}, parent.metadata["note_id"])}
    else
      _ -> {:error, :parent_not_found}
    end
  end

  defp resolve_parent(_post_uuid, _parent_uuid, _note_id), do: {:error, :parent_not_found}

  defp note_attrs(attrs, note_id) when is_binary(note_id) and note_id != "",
    do: Map.put(attrs, :metadata, %{"note_id" => note_id})

  defp note_attrs(attrs, _), do: attrs

  @doc """
  Renders a comment's markdown content — the comments module's sanitized
  `comment_markdown/1` component when available, escaped plain text with
  line breaks otherwise.
  """
  def render_content(content) when is_binary(content) do
    markdown_mod = PhoenixKitComments.Web.Markdown

    if Code.ensure_loaded?(markdown_mod) and
         function_exported?(markdown_mod, :comment_markdown, 1) do
      markdown_mod.comment_markdown(%{
        __changed__: nil,
        content: content,
        class: "",
        compact: false,
        sanitize: true
      })
    else
      escaped =
        content
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string()
        |> String.replace("\n", "<br>")

      Phoenix.HTML.raw(escaped)
    end
  rescue
    _ -> Phoenix.HTML.html_escape(content)
  end

  def render_content(_), do: Phoenix.HTML.raw("")

  @doc "The comments module's one-per-page markdown styles, or nothing."
  def content_styles do
    markdown_mod = PhoenixKitComments.Web.Markdown

    if Code.ensure_loaded?(markdown_mod) and
         function_exported?(markdown_mod, :comment_markdown_styles, 1) do
      markdown_mod.comment_markdown_styles(%{__changed__: nil})
    else
      Phoenix.HTML.raw("")
    end
  rescue
    _ -> Phoenix.HTML.raw("")
  end
end
