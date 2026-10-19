defmodule PhoenixKit.Modules.Publishing.API.Tools do
  @moduledoc false
  # The 20 tool declarations of the Publishing API. `Publishing.api_tools/0`
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
      update_post(),
      create_version(),
      set_translation(),
      translate_post(),
      publish_post(),
      unpublish_post(),
      schedule_post(),
      trash_posts(),
      restore_posts(),
      upsert_categories(),
      delete_categories(),
      upsert_groups(),
      trash_groups(),
      restore_groups()
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
          "false omits the Markdown. title is the title of the language shown. The revision covers the version and " <>
          "language returned: pass it as if_revision together with that same version, because the write " <>
          "tools default to the highest draft, which is not the version a plain read shows when one is live; " <>
          "publish_post and schedule_post compare the primary-language text, so read the primary language " <>
          "for them. Like the admin editor, a read may repair a stale active-version " <>
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

  defp create_version do
    Tool.new!(
      name: "publishing.create_version",
      audience: :admin,
      scope: "publishing.posts:write",
      permission: @permission,
      title: "Create a version",
      description:
        "Creates a new DRAFT version of a post. By default it is a copy of the latest version with every " <>
          "language; from_version copies that version instead; blank true builds an empty draft with only " <>
          "the primary-language row (publishing it needs a title). blank and from_version exclude each " <>
          "other. It never changes which version is live. Not idempotent.",
      input_schema: Schemas.create_version(),
      output_schema: Schemas.create_version_output(),
      handler: {PhoenixKit.Modules.Publishing.API.CreateVersion, :call},
      annotations: %{idempotent: false}
    )
  end

  defp set_translation do
    Tool.new!(
      name: "publishing.set_translation",
      audience: :admin,
      scope: "publishing.posts:write",
      permission: @permission,
      title: "Set a translation",
      description:
        "Adds or updates ONE non-primary language of a version: title and body are required and must not " <>
          "be blank (a published version with an empty language row would show an empty page). The primary " <>
          "language is edited with update_post. version defaults to the highest draft. A new language row " <>
          "is created first; if the write then fails an empty row stays (the API deletes nothing) and the " <>
          "error says so. og_title, og_description and og_image_id are optional; null clears. Writing to " <>
          "the live version or an archived one, or body text with HTML, components, post links or link " <>
          "destinations other than http, https, mailto or tel, needs a confirmation: send dry_run first and " <>
          "confirm the preview. if_revision is the revision of get_post of the same language and version; for " <>
          "a language without text yet it is the revision get_post showed for the text it fell back to.",
      input_schema: Schemas.set_translation(),
      output_schema: Schemas.set_translation_output(),
      handler: {PhoenixKit.Modules.Publishing.API.SetTranslation, :call},
      danger: {PhoenixKit.Modules.Publishing.API.Danger, :set_translation},
      annotations: %{idempotent: true}
    )
  end

  defp translate_post do
    Tool.new!(
      name: "publishing.translate_post",
      audience: :admin,
      scope: "publishing.translations:ai",
      permission: @permission,
      title: "Translate a post with AI",
      description:
        "Queues AI translation jobs of the primary-language text into other languages. It costs money: " <>
          "one paid job per language, and each job OVERWRITES the language it translates. Always needs a " <>
          "confirmation; the preview lists the targets, the languages skipped, the languages whose existing " <>
          "text will be overwritten, the endpoint and the prompt. version defaults to the highest draft; " <>
          "languages (up to 50) defaults to every enabled language except the primary; a language that " <>
          "already has text is skipped unless overwrite_existing is true. The endpoint and the prompt come " <>
          "from the site's settings, not from the request. The answer reports QUEUED work (enqueued, " <>
          "conflicts, in_flight), never 'translated': poll get_post, a language appears in languages with " <>
          "its title once its job wrote the row. A second identical call is de-duplicated (conflicts). " <>
          "Not idempotent.",
      input_schema: Schemas.translate_post(),
      output_schema: Schemas.translate_post_output(),
      handler: {PhoenixKit.Modules.Publishing.API.TranslatePost, :call},
      danger: :always,
      cost: 5,
      annotations: %{open_world: true, idempotent: false}
    )
  end

  defp publish_post do
    Tool.new!(
      name: "publishing.publish_post",
      audience: :admin,
      scope: "publishing.posts:publish",
      permission: @permission,
      title: "Publish a post",
      description:
        "Makes a version the live one: the highest draft by default, or any existing version (a rollback " <>
          "to an archived one). Always needs a confirmation; the preview lists the languages that go live " <>
          "with the first 300 characters of each body, the version that is archived, any HTML in the " <>
          "stored text, and an empty-language warning. A version already live answers unchanged, also when " <>
          "no version is named and the post has no draft.",
      input_schema: Schemas.publish_post(),
      output_schema: Schemas.publish_post_output(),
      handler: {PhoenixKit.Modules.Publishing.API.PublishPost, :call},
      danger: :always,
      annotations: %{idempotent: true}
    )
  end

  defp unpublish_post do
    Tool.new!(
      name: "publishing.unpublish_post",
      audience: :admin,
      scope: "publishing.posts:publish",
      permission: @permission,
      title: "Unpublish a post",
      description:
        "Takes the live version down: its public URLs stop resolving and the version returns to draft " <>
          "(it keeps its published date). Always needs a confirmation; the preview lists the paths that " <>
          "stop resolving. A post with nothing live is refused with not_published, so a second call is " <>
          "an error.",
      input_schema: Schemas.unpublish_post(),
      output_schema: Schemas.unpublish_post_output(),
      handler: {PhoenixKit.Modules.Publishing.API.UnpublishPost, :call},
      danger: :always,
      annotations: %{destructive: true, idempotent: true}
    )
  end

  defp schedule_post do
    Tool.new!(
      name: "publishing.schedule_post",
      audience: :admin,
      scope: "publishing.posts:publish",
      permission: @permission,
      title: "Schedule a post",
      description:
        "Publishes a version at a future time in a timestamp-mode group. publish_at is " <>
          "YYYY-MM-DDTHH:MM on the site clock (the answer carries time_zone), without seconds or a zone, " <>
          "and must be later than now; the minute must be free (another post, also a trashed one, holding " <>
          "it answers slot_taken). The post's date and time move to publish_at, so its public URL " <>
          "changes with its date, and a post that is live now disappears until then. version defaults " <>
          "to the highest draft, or the live version when there is no draft. Always needs a confirmation; " <>
          "the preview says all of this and shows the text that goes live. Repeating the call is safe: " <>
          "a post already scheduled for that minute answers unchanged.",
      input_schema: Schemas.schedule_post(),
      output_schema: Schemas.schedule_post_output(),
      handler: {PhoenixKit.Modules.Publishing.API.SchedulePost, :call},
      danger: :always,
      annotations: %{idempotent: true}
    )
  end

  defp trash_posts do
    Tool.new!(
      name: "publishing.trash_posts",
      audience: :admin,
      scope: "publishing.posts:delete",
      permission: @permission,
      title: "Trash posts",
      description:
        "Moves up to 50 posts to the trash; restore_posts brings them back, and a live post keeps its " <>
          "live version, so a restore shows the same text again. Always needs a confirmation; the preview " <>
          "lists each post's title, languages and the public paths that stop resolving. A post already " <>
          "in the trash answers unchanged. The same post twice in one request is an invalid_ref row; one " <>
          "bad row never stops the others.",
      input_schema: Schemas.trash_posts(),
      output_schema: Schemas.trash_posts_output(),
      handler: {PhoenixKit.Modules.Publishing.API.TrashPosts, :call},
      danger: :always,
      max_items: 50,
      annotations: %{destructive: true, idempotent: true}
    )
  end

  defp restore_posts do
    Tool.new!(
      name: "publishing.restore_posts",
      audience: :admin,
      scope: "publishing.posts:delete",
      permission: @permission,
      title: "Restore posts",
      description:
        "Restores up to 50 posts from the trash, by id or {group, slug}. A restored post that has a live " <>
          "version becomes visible again and needs a confirmation; the preview says for each post whether " <>
          "it becomes visible and what its status will be. A post that is not in the trash answers " <>
          "unchanged, a post in a trashed group is a group_trashed row (restore the group first), and " <>
          "the same post twice in one request is an invalid_ref row; one bad row never stops the others.",
      input_schema: Schemas.restore_posts(),
      output_schema: Schemas.restore_posts_output(),
      handler: {PhoenixKit.Modules.Publishing.API.RestorePosts, :call},
      danger: {PhoenixKit.Modules.Publishing.API.Danger, :restore_posts},
      max_items: 50,
      annotations: %{idempotent: true}
    )
  end

  defp upsert_categories do
    Tool.new!(
      name: "publishing.upsert_categories",
      audience: :admin,
      scope: "publishing.categories:write",
      permission: @permission,
      title: "Create or update categories",
      description:
        "Creates or updates up to 100 categories of one group. A row names its category by id or slug: " <>
          "found, it is updated; a slug that does not exist is created (name is required, the slug is " <>
          "lowercase letters, digits and single hyphens and never changes later). parent is {id} or {slug} " <>
          "of a category of the same group, or null for the top level; a later row may name a category " <>
          "created earlier in the same request as its parent. name_i18n REPLACES the stored map: send " <>
          "every language you want to keep. Creating categories runs at once; changing an existing one " <>
          "(name, name_i18n, description, parent or position) needs a confirmation, and so does a request " <>
          "of more than 50 rows. Rows that change nothing answer unchanged; one bad row never stops the others.",
      input_schema: Schemas.upsert_categories(),
      output_schema: Schemas.upsert_categories_output(),
      handler: {PhoenixKit.Modules.Publishing.API.UpsertCategories, :call},
      danger: {PhoenixKit.Modules.Publishing.API.Danger, :upsert_categories},
      max_items: 100,
      annotations: %{idempotent: true}
    )
  end

  defp delete_categories do
    Tool.new!(
      name: "publishing.delete_categories",
      audience: :admin,
      scope: "publishing.categories:delete",
      permission: @permission,
      title: "Delete categories",
      description:
        "Permanently deletes categories. There is no trash and no undo. Posts, their versions and content " <>
          "stay; only their filing under the category is removed from every version of the group, and child " <>
          "categories move to the top level. refs is up to 100 {id} or {slug} entries of one group. Always " <>
          "needs a confirmation; the preview lists for each category the children that move up, the live " <>
          "posts filed in it and the versions that name it. A category that is already gone answers a " <>
          "not_found row, the same category twice is an invalid_ref row, and one bad row never stops the " <>
          "others. If the unfiling of some version failed after the delete, the row carries an " <>
          "unfile_incomplete warning with the count.",
      input_schema: Schemas.delete_categories(),
      output_schema: Schemas.delete_categories_output(),
      handler: {PhoenixKit.Modules.Publishing.API.DeleteCategories, :call},
      danger: :always,
      max_items: 100,
      annotations: %{destructive: true, idempotent: true}
    )
  end

  defp upsert_groups do
    Tool.new!(
      name: "publishing.upsert_groups",
      audience: :admin,
      scope: "publishing.groups:write",
      permission: @permission,
      title: "Create or update groups",
      description:
        "Creates or updates up to 20 publishing groups, each named by slug. A slug that does not exist is " <>
          "created (name is required; mode, type, item_singular and item_plural are fixed at creation and " <>
          "default as the admin form does); a slug that exists is updated: name, name_i18n and settings only, " <>
          "never the slug. settings is a closed object with one property per key of " <>
          "get_group_settings_schema; a value outside its allowed values is an invalid_setting row. name_i18n " <>
          "MERGES per language and a blank value removes that language. Repeating mode, type or the item names " <>
          "of an existing group is ignored when they equal the stored ones (so a retried call is unchanged), " <>
          "and a different value is a mode_locked or immutable_field row. A group in the trash is a " <>
          "group_trashed row (restore it first). Creating groups runs at once; changing an existing group " <>
          "needs a confirmation, and the preview shows each change as from and to with the group's post " <>
          "count. Rows that change nothing answer unchanged; one bad row never stops the others.",
      input_schema: Schemas.upsert_groups(),
      output_schema: Schemas.upsert_groups_output(),
      handler: {PhoenixKit.Modules.Publishing.API.UpsertGroups, :call},
      danger: {PhoenixKit.Modules.Publishing.API.Danger, :upsert_groups},
      max_items: 20,
      annotations: %{idempotent: true}
    )
  end

  defp trash_groups do
    Tool.new!(
      name: "publishing.trash_groups",
      audience: :admin,
      scope: "publishing.groups:delete",
      permission: @permission,
      title: "Trash groups",
      description:
        "Moves up to 20 publishing groups, each named by slug, to the trash. The whole group and every " <>
          "post in it disappear from the site; the posts keep their own state and come back with " <>
          "restore_groups. Always needs a confirmation; the preview lists for each group its post count " <>
          "and how many posts are live. A group already in the trash answers unchanged, an unknown slug " <>
          "a not_found row, the same slug twice an invalid_ref row, and one bad row never stops the others.",
      input_schema: Schemas.group_refs(),
      output_schema: Schemas.trash_groups_output(),
      handler: {PhoenixKit.Modules.Publishing.API.TrashGroups, :call},
      danger: :always,
      max_items: 20,
      annotations: %{destructive: true, idempotent: true}
    )
  end

  defp restore_groups do
    Tool.new!(
      name: "publishing.restore_groups",
      audience: :admin,
      scope: "publishing.groups:delete",
      permission: @permission,
      title: "Restore groups",
      description:
        "Brings up to 20 publishing groups, each named by slug, back from the trash; the group and its " <>
          "posts become visible on the site again. Always needs a confirmation; the preview lists for " <>
          "each group its post count and how many posts are live. A group that is not in the trash " <>
          "answers unchanged, an unknown slug a not_found row, the same slug twice an invalid_ref row, " <>
          "and one bad row never stops the others.",
      input_schema: Schemas.group_refs(),
      output_schema: Schemas.restore_groups_output(),
      handler: {PhoenixKit.Modules.Publishing.API.RestoreGroups, :call},
      danger: :always,
      max_items: 20,
      annotations: %{idempotent: true}
    )
  end

  # Each tool task adds its `defp` below this line and one entry to `all/0`, in the declared
  # order. `permission/0` is the one place the permission string lives.
  @doc false
  def permission, do: @permission
end
