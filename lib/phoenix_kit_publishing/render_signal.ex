defmodule PhoenixKit.Modules.Publishing.RenderSignal do
  @moduledoc false

  # Core records a storage lookup that raised (`RenderCache.take/1`).

  alias PhoenixKit.Modules.Shared.RenderCache

  @spec take((-> result)) :: {:ok | :retry, result} when result: term()
  def take(fun) when is_function(fun, 0), do: RenderCache.take(fun)
end
