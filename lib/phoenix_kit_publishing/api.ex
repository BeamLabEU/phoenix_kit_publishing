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

  require Logger

  alias PhoenixKit.Modules.Publishing.API.{Gate, Tools}

  @withheld_logged {__MODULE__, :withheld_logged}

  @doc """
  The tools, FAIL CLOSED: when the loaded core cannot enforce the confirmation flow
  (`Gate.available?/0`) EVERY tool with a `danger` is withheld, because a core without the
  flow ignores `danger` completely and `update_post` on a live version would apply on the
  first call. On such a core only the reads and `create_version` remain, and one warning
  names the functions the core lacks (a later 2.x core that moves one of them must be
  followed in `Gate`).
  """
  @spec tools(boolean()) :: [PhoenixKit.API.Tool.t()]
  def tools(gate? \\ Gate.available?()) do
    if not gate?, do: warn_withheld()
    Enum.filter(Tools.all(), fn tool -> gate? or tool.danger == nil end)
  end

  # Once per node: core asks for the tools on every registry read.
  defp warn_withheld do
    if not :persistent_term.get(@withheld_logged, false) do
      :persistent_term.put(@withheld_logged, true)

      missing = Enum.reject(Gate.markers(), &Gate.available?/1)

      Logger.warning(
        "[Publishing.API] the loaded phoenix_kit cannot enforce the confirmation flow " <>
          "(missing #{inspect(missing)}); every publishing tool that needs a confirmation is withheld"
      )
    end
  end
end
