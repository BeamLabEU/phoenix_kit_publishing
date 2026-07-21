defmodule PhoenixKitPublishing.GroupAITranslateBinding do
  @moduledoc """
  `PhoenixKitAI.Components.AITranslate.FormBinding`-shaped binding for the
  Edit Group form's name translations.

  NOT declared as `@behaviour`: the FormBinding callbacks type the second
  `apply_translation/4` argument as an `Ecto.Changeset`, but the group edit
  form is a plain params MAP behind `to_form(params, as: :group)` — the glue
  passes `form.source` through verbatim, so a map works, and skipping the
  behaviour declaration keeps dialyzer from flagging the contract mismatch.
  """

  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Shared

  @doc "Languages whose name override is already non-blank in the live form."
  def existing_translation_langs(_resource_type, assigns) do
    case assigns.form.source do
      %{"name_i18n" => %{} = map} ->
        for {lang, value} <- map,
            is_binary(lang) and is_binary(value) and String.trim(value) != "",
            do: lang

      _ ->
        []
    end
  end

  @doc "Merge a completed name translation into the form's params map."
  def apply_translation(_resource_type, params, lang, fields) when is_map(params) do
    case fields do
      %{"name" => name} when is_binary(name) and name != "" ->
        name_i18n =
          case params["name_i18n"] do
            %{} = map -> map
            _ -> %{}
          end

        # Same cap the persist paths apply — the in-form preview must not
        # momentarily show a longer name than what will be saved.
        capped = String.slice(name, 0, Constants.max_group_name_length())
        Map.put(params, "name_i18n", Map.put(name_i18n, lang, capped))

      _ ->
        params
    end
  end

  @doc "The acting user's UUID for the translation audit trail."
  def actor_uuid(socket), do: Shared.actor_uuid_from_socket(socket)
end
