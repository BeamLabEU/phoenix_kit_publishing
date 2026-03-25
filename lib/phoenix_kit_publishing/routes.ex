defmodule PhoenixKitWeb.Routes.PublishingRoutes do
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
  Public blog/publishing catch-all routes.

  Placed AFTER all other routes by phoenix_kit's `compile_external_public_routes`
  to prevent the `/:group` catch-all from intercepting admin or other paths.

  Includes `:phoenix_kit_optional_scope` pipeline so `AdminEditHelper` can show
  edit buttons for logged-in admins/owners on public pages.
  """
  def public_routes(url_prefix) do
    quote do
      blog_scope_multi =
        case unquote(url_prefix) do
          "/" -> "/:language"
          prefix -> "#{prefix}/:language"
        end

      scope blog_scope_multi do
        pipe_through [
          :browser,
          :phoenix_kit_auto_setup,
          :phoenix_kit_locale_validation,
          :phoenix_kit_optional_scope
        ]

        get "/:group", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{
            "group" => ~r/^(?!admin$|assets$|images$|fonts$|js$|css$|favicon)/,
            "language" => ~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/
          }

        get "/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{
            "group" => ~r/^(?!admin$|assets$|images$|fonts$|js$|css$|favicon)/,
            "language" => ~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/
          }
      end

      blog_scope_non_localized =
        case unquote(url_prefix) do
          "/" -> "/"
          prefix -> prefix
        end

      scope blog_scope_non_localized do
        pipe_through [
          :browser,
          :phoenix_kit_auto_setup,
          :phoenix_kit_locale_validation,
          :phoenix_kit_optional_scope
        ]

        get "/:group", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{"group" => ~r/^(?!admin$|assets$|images$|fonts$|js$|css$|favicon)/}

        get "/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{"group" => ~r/^(?!admin$|assets$|images$|fonts$|js$|css$|favicon)/}
      end
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (localized).
  """
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
