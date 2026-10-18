defmodule PhoenixKit.Modules.Publishing.API.TranslatePost do
  @moduledoc false
  # Tool `publishing.translate_post`: queue AI translation jobs; they run and bill later.

  alias PhoenixKit.Modules.Publishing.API.{Common, Refs}

  alias PhoenixKit.Modules.Publishing.{
    ActivityLog,
    DBStorage,
    LanguageHelpers,
    TranslationManager
  }

  alias PhoenixKit.Settings
  alias PhoenixKitAI.Translations

  @tool "publishing.translate_post"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, hit} <- Refs.resolve_post(input["post"], []) |> Refs.post_error(),
         :ok <- Refs.ensure_group_active(hit.group) |> Refs.group_error(),
         {:ok, version} <-
           Refs.resolve_version(hit.db_post, input["version"], :write) |> Refs.version_error(),
         contents = DBStorage.list_contents(version.uuid),
         {:ok, source} <- source(contents),
         {:ok, wanted} <- languages(input["languages"]),
         {:ok, endpoint} <- endpoint(),
         {:ok, prompt} <- prompt(),
         {targets, skipped} = split(wanted, contents, input["overwrite_existing"] == true),
         :ok <- something_to_do(targets) do
      plan = %{
        hit: hit,
        version: version,
        source: source,
        targets: targets,
        skipped: skipped,
        endpoint: endpoint,
        prompt: prompt,
        contents: contents
      }

      if Map.get(ctx, :dry_run?, false), do: preview(plan), else: execute(plan, ctx)
    end
  end

  defp source(contents) do
    primary = LanguageHelpers.get_primary_language()
    row = Enum.find(contents, &(&1.language == primary))

    if row && String.trim(row.content || "") != "",
      do: {:ok, primary},
      else:
        Common.invalid(
          "version",
          "the primary-language body is empty; there is nothing to translate from",
          "empty_translation"
        )
  end

  # nil = every enabled language except the primary; explicit codes must be enabled and not the primary.
  defp languages(nil) do
    primary = LanguageHelpers.get_primary_language()
    {:ok, Enum.reject(LanguageHelpers.enabled_language_codes(), &(&1 == primary))}
  end

  defp languages(codes) when is_list(codes) do
    primary = LanguageHelpers.get_primary_language()

    codes
    |> Enum.reduce_while({:ok, []}, fn code, {:ok, acc} ->
      case Refs.resolve_language(code) do
        {:ok, ^primary} ->
          {:halt,
           Common.invalid(
             "languages",
             "the primary language is the source",
             "language_not_enabled"
           )}

        {:ok, resolved} ->
          {:cont, {:ok, [resolved | acc]}}

        {:error, {:language_not_enabled, allowed}} ->
          {:halt,
           Common.invalid("languages", "is not an enabled language", "language_not_enabled", %{
             allowed: allowed
           })}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, list |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp split(wanted, contents, overwrite?) do
    has_text =
      for c <- contents, String.trim(c.content || "") != "", into: MapSet.new(), do: c.language

    if overwrite?,
      do: {wanted, []},
      else: Enum.split_with(wanted, &(not MapSet.member?(has_text, &1)))
  end

  defp something_to_do([]),
    do:
      Common.invalid(
        "languages",
        "every target language already has text; send overwrite_existing: true to translate again",
        "nothing_to_translate"
      )

  defp something_to_do(_targets), do: :ok

  # The admin override (verified), else the AI module's unattended resolution. NEVER the last-used endpoint.
  defp endpoint do
    case Settings.get_setting("publishing_translation_endpoint_uuid") do
      uuid when is_binary(uuid) and uuid != "" -> verify_endpoint(uuid)
      _unset -> unattended()
    end
  end

  defp verify_endpoint(uuid) do
    case PhoenixKitAI.get_endpoint(uuid) do
      %{enabled: true} ->
        {:ok, uuid}

      _missing_or_disabled ->
        not_configured("the configured translation endpoint is missing or disabled")
    end
  end

  defp unattended do
    if Code.ensure_loaded?(Translations) and
         function_exported?(Translations, :unattended_endpoint_uuid, 0) do
      case Translations.unattended_endpoint_uuid() do
        {:ok, uuid} -> {:ok, uuid}
        {:error, _reason} -> not_configured("no usable AI endpoint is configured")
      end
    else
      not_configured("the installed AI module cannot pick an endpoint unattended")
    end
  end

  defp prompt do
    case TranslationManager.default_prompt_uuid() do
      uuid when is_binary(uuid) and uuid != "" -> {:ok, uuid}
      _none -> not_configured("no translation prompt is configured")
    end
  end

  defp not_configured(message), do: Common.invalid("", message, "ai_not_configured")

  # --- dry run ---------------------------------------------------------------------------

  defp preview(plan) do
    existing =
      for c <- plan.contents,
          c.language in plan.targets,
          String.trim(c.content || "") != "",
          do: c.language

    row = %{
      "action" => "queue",
      "version" => plan.version.version_number,
      "source_language" => plan.source,
      "targets" => plan.targets,
      "skipped" => plan.skipped,
      "overwrites" => existing,
      "endpoint_uuid" => plan.endpoint,
      "prompt_uuid" => plan.prompt,
      "estimated_jobs" => length(plan.targets)
    }

    term =
      {:translate_post, plan.hit.db_post.uuid, plan.version.version_number, plan.targets,
       existing, plan.endpoint, plan.prompt}

    Common.preview([row], %{"requires_confirmation" => true}, term)
  end

  # --- write -----------------------------------------------------------------------------

  defp execute(plan, ctx) do
    {base, targets} =
      TranslationManager.build_bulk_translation_params(plan.hit.db_post.uuid,
        source_language: plan.source,
        target_languages: plan.targets,
        endpoint_uuid: plan.endpoint,
        prompt_uuid: plan.prompt,
        resource_scope: to_string(plan.version.version_number),
        user_uuid: ctx.actor.user_uuid
      )

    case Translations.enqueue_all_missing(base, targets) do
      {:ok, result} ->
        log(plan, result, ctx)

        {:ok,
         %{
           "action" => "queued",
           "version" => plan.version.version_number,
           "source_language" => plan.source,
           "targets" => plan.targets,
           "skipped" => plan.skipped,
           "enqueued" => result.enqueued,
           "conflicts" => result.conflicts,
           "errors" =>
             for(
               {lang, reason} <- result.errors,
               do: %{"language" => lang, "reason" => Common.reason_text(reason)}
             ),
           "in_flight" => result.in_flight
         }}

      {:error, reason} ->
        Common.error(reason)
    end
  end

  # The per-language jobs run in another process and log without API attribution, so the request
  # itself leaves one row.
  defp log(plan, result, ctx) do
    opts = Common.write_opts(ctx, @tool)

    ActivityLog.log_manual(
      "publishing.translation.requested",
      ctx.actor.user_uuid,
      "publishing_post",
      plan.hit.db_post.uuid,
      %{
        "group_slug" => plan.hit.group.slug,
        "version" => plan.version.version_number,
        "targets" => plan.targets,
        "enqueued" => result.enqueued,
        "conflicts" => result.conflicts
      },
      opts
    )
  end
end
