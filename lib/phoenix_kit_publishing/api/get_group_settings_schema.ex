defmodule PhoenixKit.Modules.Publishing.API.GetGroupSettingsSchema do
  @moduledoc false
  # Tool `publishing.get_group_settings_schema` (spec §9.2): the vocabulary for upsert_groups.settings.

  alias PhoenixKit.Modules.Publishing.GroupSettings

  @spec call(map(), map()) :: {:ok, map()}
  def call(_input, _ctx) do
    {:ok,
     %{
       "settings" => Enum.map(GroupSettings.schema(), &json/1),
       "defaults" => GroupSettings.default_config(),
       "group_fields" => ["name", "name_i18n"]
     }}
  end

  # Atoms to strings so the answer is plain JSON; `allowed` stays a list of values.
  defp json(entry) do
    Map.new(entry, fn
      {key, value} when is_atom(value) and not is_nil(value) and not is_boolean(value) ->
        {to_string(key), to_string(value)}

      {key, value} ->
        {to_string(key), value}
    end)
  end
end
