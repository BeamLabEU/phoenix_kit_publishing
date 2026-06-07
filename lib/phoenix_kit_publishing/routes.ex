defmodule PhoenixKitPublishing.Routes do
  @moduledoc """
  Publishing module routes.

  Provides route definitions for content management (publishing groups and posts).
  """

  @doc """
  Returns quoted code for publishing non-LiveView routes via `generate/1`.
  No-op — public routes are provided via `public_routes/1` instead, which
  is placed later in the route order to avoid catch-all conflicts.
  """
  def generate(_url_prefix) do
    quote do
    end
  end

  @doc """
  Returns an empty AST.

  Publishing's public catch-all is no longer registered through this hook.
  Dispatch happens via `PhoenixKitPublishing.RouterDispatch` — the host
  router's `call/2` is overridden (by `phoenix_kit_routes/0`) to detect
  publishing-bound URLs and rewrite them onto an internal prefix where
  the catch-all lives. See `PhoenixKitPublishing.RouterDispatch` moduledoc
  + `AGENTS.md` "Public dispatch — RouterDispatch" for the full mechanism.

  This callback is kept (returning a no-op) for backwards compatibility
  with core's route compiler in `PhoenixKitWeb.Integration` (the
  `compile_external_public_routes` hook), which walks every route_module
  looking for the function. Removing the callback entirely would require a
  coordinated bump of the `function_exported?/3` guard in core.
  """
  @spec public_routes(String.t()) :: Macro.t()
  def public_routes(_url_prefix) do
    quote do
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (localized).
  """
  @spec admin_locale_routes() :: Macro.t()
  def admin_locale_routes do
    quote do
      live "/admin/publishing", PhoenixKit.Modules.Publishing.Web.Index, :index,
        as: :publishing_index_localized

      # Literal path routes MUST come before :group param routes
      live "/admin/publishing/new-group", PhoenixKit.Modules.Publishing.Web.New, :new,
        as: :publishing_new_group_localized

      live "/admin/publishing/edit-group/:group",
           PhoenixKit.Modules.Publishing.Web.Edit,
           :edit,
           as: :publishing_edit_group_localized

      live "/admin/publishing/:group", PhoenixKit.Modules.Publishing.Web.Listing, :group,
        as: :publishing_group_localized

      live "/admin/publishing/:group/edit", PhoenixKit.Modules.Publishing.Web.Editor, :edit,
        as: :publishing_editor_localized

      live "/admin/publishing/:group/new", PhoenixKit.Modules.Publishing.Web.Editor, :new,
        as: :publishing_new_post_localized

      live "/admin/publishing/:group/preview",
           PhoenixKit.Modules.Publishing.Web.Preview,
           :preview,
           as: :publishing_preview_localized

      # UUID-based routes (param routes — must come AFTER literal routes above)
      live "/admin/publishing/:group/:post_uuid",
           PhoenixKit.Modules.Publishing.Web.PostShow,
           :show,
           as: :publishing_post_show_localized

      live "/admin/publishing/:group/:post_uuid/edit",
           PhoenixKit.Modules.Publishing.Web.Editor,
           :edit_post,
           as: :publishing_post_editor_localized

      live "/admin/publishing/:group/:post_uuid/preview",
           PhoenixKit.Modules.Publishing.Web.Preview,
           :preview_post,
           as: :publishing_post_preview_localized

      live "/admin/settings/publishing", PhoenixKit.Modules.Publishing.Web.Settings, :index,
        as: :publishing_settings_localized
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (non-localized).
  """
  @spec admin_routes() :: Macro.t()
  def admin_routes do
    quote do
      live "/admin/publishing", PhoenixKit.Modules.Publishing.Web.Index, :index,
        as: :publishing_index

      # Literal path routes MUST come before :group param routes
      live "/admin/publishing/new-group", PhoenixKit.Modules.Publishing.Web.New, :new,
        as: :publishing_new_group

      live "/admin/publishing/edit-group/:group",
           PhoenixKit.Modules.Publishing.Web.Edit,
           :edit,
           as: :publishing_edit_group

      live "/admin/publishing/:group", PhoenixKit.Modules.Publishing.Web.Listing, :group,
        as: :publishing_group

      live "/admin/publishing/:group/edit", PhoenixKit.Modules.Publishing.Web.Editor, :edit,
        as: :publishing_editor

      live "/admin/publishing/:group/new", PhoenixKit.Modules.Publishing.Web.Editor, :new,
        as: :publishing_new_post

      live "/admin/publishing/:group/preview",
           PhoenixKit.Modules.Publishing.Web.Preview,
           :preview,
           as: :publishing_preview

      # UUID-based routes (param routes — must come AFTER literal routes above)
      live "/admin/publishing/:group/:post_uuid",
           PhoenixKit.Modules.Publishing.Web.PostShow,
           :show,
           as: :publishing_post_show

      live "/admin/publishing/:group/:post_uuid/edit",
           PhoenixKit.Modules.Publishing.Web.Editor,
           :edit_post,
           as: :publishing_post_editor

      live "/admin/publishing/:group/:post_uuid/preview",
           PhoenixKit.Modules.Publishing.Web.Preview,
           :preview_post,
           as: :publishing_post_preview

      live "/admin/settings/publishing", PhoenixKit.Modules.Publishing.Web.Settings, :index,
        as: :publishing_settings
    end
  end
end
