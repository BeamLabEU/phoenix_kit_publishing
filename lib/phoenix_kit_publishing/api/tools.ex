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

  @permission "publishing"

  @spec all() :: [PhoenixKit.API.Tool.t()]
  def all do
    []
  end

  # Each tool task adds its `defp` below this line and one entry to `all/0`, in the order of
  # spec §6.2. `permission/0` is the one place the permission string lives.
  @doc false
  def permission, do: @permission
end
