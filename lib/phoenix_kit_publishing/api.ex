defmodule PhoenixKit.Modules.Publishing.API do
  @moduledoc """
  The publishing module's part of the machine API (`/api/admin/v1`, `/mcp/admin`).

  `tools/1` is what `PhoenixKit.Modules.Publishing.api_tools/0` hands to core. Twenty admin
  tools: reads of groups, posts and categories; drafting and editing posts, versions and
  translations (by hand and by AI); publish, unpublish and schedule; trash and restore;
  categories and group settings. Anything that changes what a visitor sees needs a
  confirmation (core's `confirm_token` round trip, or a human click when the key requires
  approval). See `dev_docs/guides/machine-api.md`.
  """

  alias PhoenixKit.Modules.Publishing.API.{Gate, Tools}

  @doc """
  The tools, FAIL CLOSED: when the loaded core cannot enforce the confirmation flow
  (`Gate.available?/0`) EVERY tool with a `danger` is withheld, because a core without the
  flow ignores `danger` completely and `update_post` on a live version would apply on the
  first call. On such a core only the reads and `create_version` remain.
  """
  @spec tools(boolean()) :: [PhoenixKit.API.Tool.t()]
  def tools(gate? \\ Gate.available?()) do
    Enum.filter(Tools.all(), fn tool -> gate? or tool.danger == nil end)
  end
end
