defmodule PhoenixKit.Modules.Publishing.API.Tools do
  @moduledoc false
  # The 20 tool declarations of the publishing API (spec §6.2). `Publishing.api_tools/0`
  # returns them through `API.tools/1`; core's registry validates each struct.
  #
  # Scope -> role permission, all permission "publishing":
  #   publishing.posts:read          list_posts, get_post
  #   publishing.posts:write         create_post, update_post, create_version, set_translation
  #   publishing.posts:publish       publish_post, unpublish_post, schedule_post
  #   publishing.posts:delete        trash_posts, restore_posts
  #   publishing.categories:read     list_categories
  #   publishing.categories:write    upsert_categories
  #   publishing.categories:delete   delete_categories
  #   publishing.groups:read         list_groups, get_group_settings_schema
  #   publishing.groups:write        upsert_groups
  #   publishing.groups:delete       trash_groups, restore_groups
  #   publishing.translations:ai     translate_post

  alias PhoenixKit.API.Tool
  alias PhoenixKit.Modules.Publishing.API.Schemas

  @permission "publishing"

  @spec all() :: [PhoenixKit.API.Tool.t()]
  def all do
    [
      list_groups(),
      get_group_settings_schema(),
      list_posts(),
      get_post(),
      list_categories(),
      create_post(),
      update_post()
    ]
  end

  defp list_groups do
    Tool.new!(
      name: "publishing.list_groups",
      audience: :admin,
      scope: "publishing.groups:read",
      permission: @permission,
      title: "List groups",
      description:
        "Lists the publishing groups (blogs, pages, legal sections) with their mode, type, item names, " <>
          "display settings and the number of posts. status is active (default) or trashed. Not paginated.",
      input_schema: Schemas.list_groups(),
      output_schema: Schemas.list_groups_output(),
      handler: {PhoenixKit.Modules.Publishing.API.ListGroups, :call},
      annotations: %{read_only: true, idempotent: true}
    )
  end

  defp get_group_settings_schema do
    Tool.new!(
      name: "publishing.get_group_settings_schema",
      audience: :admin,
      scope: "publishing.groups:read",
      permission: @permission,
      title: "Get the group settings schema",
      description:
        "The machine-readable list of the per-group display settings (key, type, allowed values, default, " <>
          "scope, label) and their defaults: the vocabulary for the settings object of upsert_groups.",
      input_schema: Schemas.get_group_settings_schema(),
      output_schema: Schemas.get_group_settings_schema_output(),
      handler: {PhoenixKit.Modules.Publishing.API.GetGroupSettingsSchema, :call},
      annotations: %{read_only: true, idempotent: true}
    )
  end

  defp list_posts do
    Tool.new!(
      name: "publishing.list_posts",
      audience: :admin,
      scope: "publishing.posts:read",
      permission: @permission,
      title: "List posts",
      description:
        "Lists the posts of one group, paginated. status is all (default, not trashed), published (live now), " <>
          "scheduled (live but dated ahead), draft or trashed. category_id limits the list to a category and its " <>
          "subtree. limit defaults to 20 and is trimmed to 100; next_cursor is opaque, pass it back as cursor. " <>
          "A timestamp-mode post has no slug: address it by the id of its row.",
      input_schema: Schemas.list_posts(),
      output_schema: Schemas.list_posts_output(),
      handler: {PhoenixKit.Modules.Publishing.API.ListPosts, :call},
      annotations: %{read_only: true, idempotent: true}
    )
  end

  defp get_post do
    Tool.new!(
      name: "publishing.get_post",
      audience: :admin,
      scope: "publishing.posts:read",
      permission: @permission,
      title: "Get a post",
      description:
        "Reads one post by id or by group and slug: the Markdown body, the fields (description, seo_title, " <>
          "excerpt, featured image, og, derived read-only tags, categories, url_slug), the versions and the " <>
          "public paths. version defaults to the active one, else the latest; language defaults to the primary " <>
          "language, and a language without text falls back with a language_missing warning. include_content " <>
          "false omits the Markdown. title is the title of the language shown. Pass the returned revision as " <>
          "if_revision to the write tools. Like the admin editor, a read may repair a stale active-version " <>
          "pointer, and the answer describes the repaired post. A trashed post is not found here: use " <>
          "list_posts with status trashed.",
      input_schema: Schemas.get_post(),
      output_schema: Schemas.get_post_output(),
      handler: {PhoenixKit.Modules.Publishing.API.GetPost, :call},
      annotations: %{read_only: true, idempotent: true}
    )
  end

  defp list_categories do
    Tool.new!(
      name: "publishing.list_categories",
      audience: :admin,
      scope: "publishing.categories:read",
      permission: @permission,
      title: "List categories",
      description:
        "Lists the categories of one group as a flat list in tree order: id, slug, name, name_i18n, " <>
          "description, position, parent_id, depth (0 for a root) and published_post_count, the number " <>
          "of live posts filed in the category itself. Not paginated.",
      input_schema: Schemas.list_categories(),
      output_schema: Schemas.list_categories_output(),
      handler: {PhoenixKit.Modules.Publishing.API.ListCategories, :call},
      annotations: %{read_only: true, idempotent: true}
    )
  end

  defp create_post do
    Tool.new!(
      name: "publishing.create_post",
      audience: :admin,
      scope: "publishing.posts:write",
      permission: @permission,
      title: "Create a post",
      description:
        "Creates a post: a draft version 1 with the primary-language title and body. title is required; " <>
          "content is Markdown. HTML, components, post links or non-http link destinations in content make " <>
          "the call a confirmed write: send it with dry_run first and confirm the preview. A slug is for " <>
          "slug-mode groups only; a timestamp-mode post has no slug and is addressed by id. The answer " <>
          "does not carry the slug: read it with get_post. Not idempotent: send an idempotency_key when " <>
          "retrying.",
      input_schema: Schemas.create_post(),
      output_schema: Schemas.create_post_output(),
      handler: {PhoenixKit.Modules.Publishing.API.CreatePost, :call},
      danger: {PhoenixKit.Modules.Publishing.API.Danger, :create_post},
      annotations: %{idempotent: false}
    )
  end

  defp update_post do
    Tool.new!(
      name: "publishing.update_post",
      audience: :admin,
      scope: "publishing.posts:write",
      permission: @permission,
      title: "Update a post",
      description:
        "Edits ONE version of a post in ONE language; it never publishes and never renames unless slug is " <>
          "sent. version defaults to the highest draft; language defaults to the primary language and must " <>
          "already have text (use set_translation to add a language). description, seo_title, excerpt, " <>
          "featured_image_id, featured, sitemap_exclude and category_ids apply to every language of the " <>
          "version (language de with description also changes English); title, content and og_* are per " <>
          "language; slug is post-level. null clears a text field other than title; an absent field is kept. " <>
          "featured_image_id and og_image_id are media file ids (UUID) or null. Tags come from " <>
          "#hashtags in the body and cannot be set. Edits to the live or an archived version, a slug change " <>
          "on a live post, and body text with HTML, components, post links or link destinations other than " <>
          "http, https, mailto or tel need a confirmation: send dry_run first and confirm the preview. " <>
          "if_revision is the revision of get_post.",
      input_schema: Schemas.update_post(),
      output_schema: Schemas.update_post_output(),
      handler: {PhoenixKit.Modules.Publishing.API.UpdatePost, :call},
      danger: {PhoenixKit.Modules.Publishing.API.Danger, :update_post},
      annotations: %{idempotent: true}
    )
  end

  # Each tool task adds its `defp` below this line and one entry to `all/0`, in the order of
  # spec §6.2. `permission/0` is the one place the permission string lives.
  @doc false
  def permission, do: @permission
end
