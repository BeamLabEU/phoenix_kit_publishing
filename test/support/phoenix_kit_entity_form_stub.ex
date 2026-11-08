defmodule PhoenixKitEntities.Components.EntityForm do
  @moduledoc """
  Test-only stand-in for the `<EntityForm>` component of the optional
  `phoenix_kit_entities` plugin, which the renderer calls by this module name.
  Like the real one it renders a form that carries the visitor's CSRF token,
  which is what keeps a page holding one out of the render cache.
  """
  use Phoenix.Component

  def render(assigns) do
    ~H"""
    <form action="/entities/stub/submit" method="post">
      <input type="hidden" name="_csrf_token" value="stub-csrf-token" />
    </form>
    """
  end
end
