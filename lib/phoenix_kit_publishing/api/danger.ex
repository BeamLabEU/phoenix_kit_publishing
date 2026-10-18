defmodule PhoenixKit.Modules.Publishing.API.Danger do
  @moduledoc false
  # `{Module, :function}` danger checks (spec §8). Each is `fun(input, ctx) :: boolean()`, called
  # by core with a dry-run context, read-only and FAIL CLOSED:
  #   1. unprovable means true (an unresolvable reference, a missing row, a bad id);
  #   2. an error means true, and no read may hide one: only raising reads are used (Refs,
  #      DBStorage reads, Common.*!), never the banned reads of F25;
  #   3. each function body is wrapped in `guard/1`, `rescue _ -> true`.
  # The per-tool functions are added by the task that adds the tool.

  alias PhoenixKit.Modules.Publishing.API.TextScan

  @doc false
  def guard(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> true
  catch
    _kind, _value -> true
  end

  @doc "create_post: the text rule on `content` only (a new post has no live version)."
  def create_post(input, _ctx), do: guard(fn -> text_dangerous?(input) end)

  @doc false
  # `null` content means "clear": the empty text is not dangerous. Any other non-string fails closed.
  def text_dangerous?(input) do
    case Map.fetch(input, "content") do
      :error -> false
      {:ok, nil} -> false
      {:ok, text} -> TextScan.dangerous?(text)
    end
  end
end
