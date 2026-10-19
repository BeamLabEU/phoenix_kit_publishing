defmodule PhoenixKit.Modules.Publishing.API.ListGroups do
  @moduledoc false
  # Tool `publishing.list_groups`.

  alias PhoenixKit.Modules.Publishing.{DBStorage, Groups, GroupSettings}

  @spec call(map(), map()) :: {:ok, map()}
  def call(input, _ctx) do
    groups = (input["status"] || "active") |> Groups.list_groups() |> Enum.map(&present/1)
    {:ok, %{"groups" => groups, "count" => length(groups)}}
  end

  defp present(group) do
    %{
      "id" => group["uuid"],
      "slug" => group["slug"],
      "name" => group["name"],
      "name_i18n" => group["name_i18n"],
      "mode" => group["mode"],
      "type" => group["type"],
      "item_singular" => group["item_singular"],
      "item_plural" => group["item_plural"],
      "status" => group["status"],
      "post_count" => DBStorage.count_posts(group["slug"]),
      "settings" => Map.take(group, GroupSettings.keys())
    }
  end
end
