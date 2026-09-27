defmodule PhoenixKit.Modules.Publishing.RenderSignal do
  @moduledoc false

  # Core 2.41.1 records a storage lookup that raised (`RenderCache.take/1`).
  # Older cores do not have that module. The call goes through a variable
  # so Dialyzer does not resolve it against a core that predates it.

  @compile {:no_warn_undefined, PhoenixKit.Modules.Shared.RenderCache}

  @spec take((-> result)) :: {:ok | :retry, result} when result: term()
  def take(fun) when is_function(fun, 0) do
    mod = PhoenixKit.Modules.Shared.RenderCache

    if Code.ensure_loaded?(mod) and function_exported?(mod, :take, 1) do
      mod.take(fun)
    else
      {:ok, fun.()}
    end
  end
end
