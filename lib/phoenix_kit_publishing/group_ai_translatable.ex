defmodule PhoenixKitPublishing.GroupAITranslatable do
  @moduledoc """
  `PhoenixKitAI.Translatable` adapter for a publishing GROUP's display name —
  the second publishing resource on PhoenixKitAI's generic translation
  pipeline (posts ride `PhoenixKitPublishing.AITranslatable`).

  ## Resource identity

  `resource_type` is `"publishing_group"`; `resource_uuid` is the group row's
  uuid (exposed on the public group map as `"uuid"` for exactly this).

  ## Fields

  One translatable field: `%{"name" => primary name}` — lowercase to match a
  `{{name}}` prompt placeholder (PhoenixKitAI's substitution is
  case-sensitive). `put_translation/4` merges the translated name into the
  group's `data["name_i18n"]` map, capped to the same max length the primary
  `name` column enforces.

  ## Concurrency

  Unlike posts (one content ROW per language), every language shares the ONE
  group row's `name_i18n` JSONB — so the merge re-reads the row `FOR UPDATE`
  (the projects/catalogue adapters' pattern): concurrent per-language jobs
  serialize on the row lock and each merges against the latest committed map,
  never dropping a sibling language.
  """

  @behaviour PhoenixKitAI.Translatable

  import Ecto.Query, only: [where: 3, lock: 2]

  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.RepoHelper

  @resource_type "publishing_group"

  @doc "The resource-type key this adapter registers under."
  def resource_type, do: @resource_type

  @impl true
  def fetch(@resource_type, group_uuid) when is_binary(group_uuid) do
    case RepoHelper.repo().get(PublishingGroup, group_uuid) do
      nil -> {:error, :not_found}
      %PublishingGroup{} = group -> {:ok, group}
    end
  end

  def fetch(_resource_type, _uuid), do: {:error, :not_found}

  @impl true
  def source_fields(%PublishingGroup{name: name}, _source_lang) do
    %{"name" => name || ""}
  end

  @impl true
  def put_translation(%PublishingGroup{uuid: uuid}, target_lang, fields, _opts)
      when is_binary(target_lang) do
    case translated_name(fields) do
      nil ->
        {:error, :no_translated_name}

      name ->
        uuid
        |> merge_name_translation(target_lang, name)
        |> broadcast_updated()
    end
  end

  # A blank/absent translation must not clobber an existing override.
  defp translated_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, Constants.max_group_name_length())
    end
  end

  defp translated_name(_fields), do: nil

  defp merge_name_translation(uuid, target_lang, name) do
    repo = RepoHelper.repo()

    repo.transaction(fn ->
      query = PublishingGroup |> where([g], g.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo.one(query) do
        nil -> repo.rollback(:resource_not_found)
        %PublishingGroup{} = fresh -> write_merged_name(repo, fresh, target_lang, name)
      end
    end)
  end

  defp write_merged_name(repo, fresh, target_lang, name) do
    name_i18n =
      case fresh.data["name_i18n"] do
        %{} = map -> map
        _ -> %{}
      end

    data = Map.put(fresh.data, "name_i18n", Map.put(name_i18n, target_lang, name))

    case fresh |> Ecto.Changeset.change(data: data) |> repo.update() do
      {:ok, updated} -> updated
      {:error, reason} -> repo.rollback(reason)
    end
  end

  # Post-commit: let open admin/public views refresh the group map. The DB
  # write happened inside the FOR UPDATE transaction, so the broadcast waits
  # until after commit (a pre-commit event would race the read-back).
  # Consumers receive the same public map shape Groups.update_group emits.
  defp broadcast_updated({:ok, %PublishingGroup{} = group} = ok) do
    case Groups.get_group(group.slug) do
      {:ok, map} -> PublishingPubSub.broadcast_group_updated(map)
      _ -> :ok
    end

    ok
  rescue
    # A PubSub hiccup must not fail the translation job — the write committed.
    _ -> ok
  end

  defp broadcast_updated(error), do: error
end
