defmodule PhoenixKit.Modules.Publishing.Access do
  @moduledoc """
  The sub-permissions the admin pages check on top of the base `publishing`
  key, which covers writing and managing posts.

    * `publishing.manage` — create, edit, trash, restore and permanently
      delete groups (the LiveViews and the `upsert_groups`, `trash_groups`
      and `restore_groups` API tools).
    * `publishing.settings` — open the settings page and change anything on
      it (module settings, caches).

  Checks go through `PhoenixKit.Users.Auth.Scope.can?/2`, so Owner (who holds
  no permission rows) passes and a disabled module grants nothing.
  """

  alias PhoenixKit.Users.Auth.Scope

  @manage "publishing.manage"
  @settings "publishing.settings"

  @doc "The key that lets a user create, edit and delete groups."
  @spec manage_key() :: String.t()
  def manage_key, do: @manage

  @doc "The key that guards the settings page."
  @spec settings_key() :: String.t()
  def settings_key, do: @settings

  @doc "True when the scope may create, edit, trash, restore or delete groups."
  @spec can_manage_groups?(term()) :: boolean()
  def can_manage_groups?(scope), do: Scope.can?(scope, @manage)

  @doc "True when the scope may open and change the settings page."
  @spec can_change_settings?(term()) :: boolean()
  def can_change_settings?(scope), do: Scope.can?(scope, @settings)

  @doc "The current scope from a LiveView socket."
  @spec scope(Phoenix.LiveView.Socket.t()) :: term()
  def scope(socket), do: socket.assigns[:phoenix_kit_current_scope]
end
