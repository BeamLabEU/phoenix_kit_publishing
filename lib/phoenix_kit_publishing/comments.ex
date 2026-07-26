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
  Creates a top-level comment on a post for a logged-in user. Returns the
  comments module's result verbatim (`{:ok, comment}` or `{:error, reason}`
  — `:content_too_long`, `:empty_comment`, …).
  """
  def create(post_uuid, user_uuid, content) when is_binary(content) do
    if available?() do
      @comments_mod.create_comment(@resource_type, post_uuid, user_uuid, %{content: content})
    else
      {:error, :comments_unavailable}
    end
  rescue
    _ -> {:error, :comments_unavailable}
  end

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
