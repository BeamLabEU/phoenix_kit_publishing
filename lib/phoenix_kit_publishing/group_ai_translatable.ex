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

  ## Audit + events

  Each merged language logs `publishing.group.updated` (mode `"auto"`, actor
  from the pipeline opts, locale-agnostic metadata). No `:group_updated`
  PubSub broadcast is emitted per merge — see `log_translated/3` for why.
  """

  @behaviour PhoenixKitAI.Translatable

  import Ecto.Query, only: [where: 3, lock: 2]

  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.RepoHelper

  @resource_type "publishing_group"

  @doc "The resource-type key this adapter registers under."
  def resource_type, do: @resource_type

  @impl true
  def fetch(@resource_type, group_uuid) when is_binary(group_uuid) do
    case RepoHelper.repo().get(PublishingGroup, group_uuid) do
      nil -> {:error, :resource_not_found}
      %PublishingGroup{} = group -> {:ok, group}
    end
  end

  def fetch(_resource_type, _uuid), do: {:error, :resource_not_found}

  @impl true
  def source_fields(%PublishingGroup{name: name}, _source_lang) do
    %{"name" => name || ""}
  end

  @impl true
  def put_translation(%PublishingGroup{uuid: uuid}, target_lang, fields, opts)
      when is_binary(target_lang) do
    case translated_name(fields) do
      nil ->
        {:error, :no_translated_name}

      name ->
        case merge_name_translation(uuid, target_lang, name) do
          {:ok, updated} = ok ->
            log_translated(updated, target_lang, opts)
            ok

          error ->
            error
        end
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

  # Post-commit audit row — the same publishing.group.updated action a manual
  # edit logs, mode "auto" (background job), actor threaded from the pipeline
  # opts. Metadata stays locale-agnostic (slug + target language), matching
  # the audit convention.
  #
  # Deliberately NO :group_updated PubSub broadcast: the sibling adapters
  # (posts here, projects, catalogue) suppress per-merge broadcasts too —
  # translation completion is signalled by core's :translation_completed
  # (which the Edit LV folds into the form via FormGlue), and a non-primary
  # name_i18n entry doesn't change what primary-language admin views render,
  # so a per-language broadcast would only fan N full listing reloads out per
  # translation run.
  defp log_translated(%PublishingGroup{} = group, target_lang, opts) do
    ActivityLog.log(%{
      action: "publishing.group.updated",
      mode: "auto",
      actor_uuid: ActivityLog.actor_uuid(opts),
      resource_type: "publishing_group",
      resource_uuid: group.uuid,
      metadata: %{
        "slug" => group.slug,
        "target_lang" => target_lang,
        "source" => "ai_translation"
      }
    })
  end
end
