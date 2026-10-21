defmodule PhoenixKit.Modules.Publishing.API.TranslatePostTest do
  use PhoenixKit.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitPublishing.Test.Repo

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.{DBStorage, Groups, Posts, Versions}
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    start_supervised!({Oban, repo: TestRepo, testing: :manual, queues: false, plugins: false})
    {:ok, _} = Settings.update_boolean_setting("ai_enabled", true)
    Fx.languages!(["en-US", "de-DE", "fr-FR"])

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Aaa pub ep #{System.unique_integer([:positive])}",
        provider: "openrouter",
        api_key: "pub-test-key",
        model: "x/y",
        enabled: true
      })

    {:ok, prompt} =
      PhoenixKitAI.create_prompt(%{
        name: "Pub translate #{System.unique_integer([:positive])}",
        content: "Translate {{Text}} to {{Language}}"
      })

    {:ok, _} = Settings.update_setting("publishing_translation_endpoint_uuid", endpoint.uuid)
    {:ok, _} = Settings.update_setting("publishing_translation_prompt_uuid", prompt.uuid)

    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "Hello", slug: "hello"})
    Fx.body!(g["slug"], post[:uuid], "english body")
    %{g: g, post: post, endpoint: endpoint, prompt: prompt}
  end

  defp translate(ctx, extra \\ %{}, overrides \\ %{}),
    do:
      ApiCase.call(
        "publishing.translate_post",
        Map.merge(%{"post" => Fx.ref(ctx.post)}, extra),
        overrides
      )

  test "queues one job per missing language, never reports 'translated'", ctx do
    assert {:ok,
            %{
              "action" => "queued",
              "source_language" => "en-US",
              "targets" => targets,
              "enqueued" => 2,
              "conflicts" => 0,
              "errors" => []
            } = body} = translate(ctx)

    assert Enum.sort(targets) == ["de-DE", "fr-FR"]
    refute inspect(body) =~ "translated"

    for lang <- targets do
      assert_enqueued(
        worker: PhoenixKitAI.TranslateWorker,
        args: %{"target_lang" => lang, "resource_uuid" => ctx.post[:uuid]}
      )
    end
  end

  test "a language with text is skipped unless overwrite_existing; nothing left is nothing_to_translate",
       ctx do
    Fx.translation!(ctx.g["slug"], ctx.post[:uuid], "de-DE", "Hallo", "Inhalt")
    assert {:ok, %{"targets" => ["fr-FR"], "skipped" => ["de-DE"]}} = translate(ctx)
    assert {:ok, %{"targets" => targets}} = translate(ctx, %{"overwrite_existing" => true})
    assert Enum.sort(targets) == ["de-DE", "fr-FR"]

    Fx.translation!(ctx.g["slug"], ctx.post[:uuid], "fr-FR", "Salut", "Contenu")

    assert {:error, :validation_failed, _, %{errors: [%{reason: "nothing_to_translate"}]}} =
             translate(ctx)
  end

  test "an empty source body is empty_translation", ctx do
    Fx.body!(ctx.g["slug"], ctx.post[:uuid], "")

    assert {:error, :validation_failed, _, %{errors: [%{reason: "empty_translation"}]}} =
             translate(ctx)
  end

  test "ai_not_configured: no endpoint, a disabled or missing override, no prompt", ctx do
    {:ok, _} =
      Settings.update_setting("publishing_translation_endpoint_uuid", Ecto.UUID.generate())

    assert {:error, :validation_failed, _, %{errors: [%{reason: "ai_not_configured"}]}} =
             translate(ctx)

    {:ok, _} = PhoenixKitAI.update_endpoint(ctx.endpoint, %{enabled: false})
    {:ok, _} = Settings.update_setting("publishing_translation_endpoint_uuid", ctx.endpoint.uuid)

    assert {:error, :validation_failed, _, %{errors: [%{reason: "ai_not_configured"}]}} =
             translate(ctx)

    {:ok, _} = PhoenixKitAI.update_endpoint(ctx.endpoint, %{enabled: true})
    {:ok, _} = Settings.update_setting("publishing_translation_prompt_uuid", "")

    assert {:error, :validation_failed, _, %{errors: [%{reason: "ai_not_configured"}]}} =
             translate(ctx)
  end

  test "the LAST-USED endpoint is never chosen: with no override the unattended resolution decides",
       ctx do
    {:ok, other} =
      PhoenixKitAI.create_endpoint(%{
        name: "Zzz last used #{System.unique_integer([:positive])}",
        provider: "openrouter",
        api_key: "pub-test-key",
        model: "expensive/model",
        enabled: true
      })

    {:ok, _} = Settings.update_setting("publishing_translation_endpoint_uuid", "")

    # `other` becomes the last-used endpoint in the AI request history, the way one Playground try would make it
    {:ok, _} =
      PhoenixKitAI.create_request(%{
        endpoint_uuid: other.uuid,
        status: "success",
        request_type: "chat",
        model: "expensive/model"
      })

    # the trap exists: the module's own default would pick it
    assert PhoenixKitAI.Translations.default_endpoint_uuid() == other.uuid
    {:ok, expected} = PhoenixKitAI.Translations.unattended_endpoint_uuid()
    refute expected == other.uuid

    assert {:ok, %{"action" => "queued"}} = translate(ctx)
    [job | _] = all_enqueued(worker: PhoenixKitAI.TranslateWorker)
    assert job.args["endpoint_uuid"] == expected
  end

  test "a context without :dry_run? is a real run", ctx do
    assert {:ok, %{"action" => "queued"}} =
             ApiCase.call_without_dry_run_key("publishing.translate_post", %{
               "post" => Fx.ref(ctx.post)
             })

    assert length(all_enqueued(worker: PhoenixKitAI.TranslateWorker)) == 2
  end

  test "the LAST-USED endpoint is never a fallback when the unattended resolution fails", ctx do
    {:ok, _} = Settings.update_setting("publishing_translation_endpoint_uuid", "")

    {:ok, _} =
      PhoenixKitAI.create_request(%{
        endpoint_uuid: ctx.endpoint.uuid,
        status: "success",
        request_type: "chat",
        model: "x/y"
      })

    # the module's own default would pick the last-used endpoint, the unattended resolution has none
    {:ok, _} = Settings.update_boolean_setting("ai_enabled", false)
    assert PhoenixKitAI.Translations.default_endpoint_uuid() == ctx.endpoint.uuid
    assert {:error, :not_configured} = PhoenixKitAI.Translations.unattended_endpoint_uuid()

    assert {:error, :validation_failed, _, %{errors: [%{reason: "ai_not_configured"}]}} =
             translate(ctx)

    assert all_enqueued(worker: PhoenixKitAI.TranslateWorker) == []
  end

  test "with the override set the job uses it and logs as the key owner", ctx do
    assert {:ok, _} = translate(ctx)
    [job | _] = all_enqueued(worker: PhoenixKitAI.TranslateWorker)

    assert job.args["endpoint_uuid"] == ctx.endpoint.uuid and
             job.args["prompt_uuid"] == ctx.prompt.uuid

    assert job.args["actor_uuid"] == ApiCase.user_uuid()
  end

  test "a second identical call is de-duplicated by the AI module, not billed twice", ctx do
    {:ok, _} = translate(ctx)
    count = length(all_enqueued(worker: PhoenixKitAI.TranslateWorker))
    assert {:ok, %{"enqueued" => 0, "conflicts" => 2}} = translate(ctx)
    assert length(all_enqueued(worker: PhoenixKitAI.TranslateWorker)) == count
  end

  test "the version defaults to the highest DRAFT, not the active version; an explicit version is honoured",
       ctx do
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid], 1)

    {:ok, _} =
      Versions.create_new_version(ctx.g["slug"], ctx.post, %{}, %{})

    assert {:ok, %{"version" => 2}} = translate(ctx)
    assert_enqueued(worker: PhoenixKitAI.TranslateWorker, args: %{"resource_scope" => "2"})
    assert {:ok, %{"version" => 1}} = translate(ctx, %{"version" => 1, "languages" => ["de-DE"]})
  end

  test "languages: the primary and a disabled code are refused; more than 50 are refused by the schema",
       ctx do
    assert {:error, :validation_failed, _, %{errors: [%{reason: "language_not_enabled"}]}} =
             translate(ctx, %{"languages" => ["en-US"]})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "language_not_enabled"}]}} =
             translate(ctx, %{"languages" => ["xx"]})

    # real, enabled codes: only the schema cap can refuse these
    assert {:ok, %{"action" => "queued"}} =
             translate(ctx, %{"languages" => List.duplicate("de-DE", 50)})

    assert {:error, :validation_failed, _, %{errors: [%{path: "languages", limit: 50}]}} =
             translate(ctx, %{"languages" => List.duplicate("de-DE", 51)})
  end

  test "one activity row records the request, attributed; the jobs are not logged by the API",
       ctx do
    {:ok, _} = translate(ctx)

    row =
      assert_activity_logged("publishing.translation.requested", resource_uuid: ctx.post[:uuid])

    assert row.mode == "auto" and row.metadata["via"] == "api"
    assert %{"group_slug" => _, "version" => 1, "enqueued" => 2, "conflicts" => 0} = row.metadata
    assert Enum.sort(row.metadata["targets"]) == ["de-DE", "fr-FR"]
  end

  test "a dry run enqueues nothing, writes nothing and previews targets, skipped, overwrites, endpoint and prompt",
       ctx do
    Fx.translation!(ctx.g["slug"], ctx.post[:uuid], "de-DE", "Hallo", "Inhalt")
    before = Fx.table_state()

    assert {:preview, %{"requires_confirmation" => true, "rows" => [row]}, _} =
             translate(ctx, %{"overwrite_existing" => true}, %{dry_run?: true})

    assert Fx.table_state() == before
    assert all_enqueued(worker: PhoenixKitAI.TranslateWorker) == []

    assert row["overwrites"] == ["de-DE"] and row["endpoint_uuid"] == ctx.endpoint.uuid and
             row["prompt_uuid"] == ctx.prompt.uuid and row["estimated_jobs"] == 2
  end

  test "the preview says whether the version being translated is live", ctx do
    assert {:preview, %{"rows" => [%{"live" => false, "public" => "none"}]}, _} =
             translate(ctx, %{}, %{dry_run?: true})

    Fx.publish!(ctx.g["slug"], ctx.post[:uuid])

    assert {:preview, %{"rows" => [%{"live" => true, "public" => "active"}]}, _} =
             translate(ctx, %{"version" => 1}, %{dry_run?: true})
  end

  test "the fingerprint pins the source text, the live state and the language paths", ctx do
    preview = fn -> translate(ctx, %{"version" => 1}, %{dry_run?: true}) end

    assert {:preview, _, base} = preview.()
    assert {:preview, _, ^base} = preview.()

    Fx.body!(ctx.g["slug"], ctx.post[:uuid], "a different english body")
    assert {:preview, _, edited} = preview.()
    refute edited == base

    {:ok, _} = DBStorage.update_content(Fx.content(ctx.post[:uuid]), %{url_slug: "moved"})
    assert {:preview, _, moved} = preview.()
    refute moved in [base, edited]

    Fx.publish!(ctx.g["slug"], ctx.post[:uuid])
    assert {:preview, _, live} = preview.()
    refute live in [base, edited, moved]
  end

  test "a trashed post and a trashed group are refused", ctx do
    {:ok, _} = Posts.trash_post(ctx.g["slug"], ctx.post[:uuid])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "post_trashed"}]}} =
             translate(ctx)

    g2 = Fx.group!()
    p2 = Fx.post!(g2["slug"], %{title: "T", slug: "t"})
    {:ok, _} = Groups.trash_group(g2["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             ApiCase.call("publishing.translate_post", %{"post" => %{"id" => p2[:uuid]}})
  end

  test "the declaration: always confirmed, its own scope, price 5, open world, not idempotent" do
    tool = ApiCase.tool!("publishing.translate_post")

    assert tool.danger == :always and tool.scope == "publishing.translations:ai" and
             tool.cost == 5

    assert tool.annotations[:open_world] == true and tool.annotations[:idempotent] == false
  end
end
