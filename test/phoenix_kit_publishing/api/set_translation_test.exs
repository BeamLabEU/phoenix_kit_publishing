defmodule PhoenixKit.Modules.Publishing.API.SetTranslationTest do
  use PhoenixKit.DataCase, async: false

  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.{DBStorage, Groups, Posts, PublishingContent, Versions}
  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    Fx.languages!(["en-US", "de-DE", "fr-FR"])
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "Hello", slug: "hello"})
    Fx.body!(g["slug"], post[:uuid], "english body")
    %{g: g, post: post}
  end

  defp set(ctx, extra \\ %{}, overrides \\ %{}) do
    input = %{
      "post" => Fx.ref(ctx.post),
      "language" => "de-DE",
      "title" => "Hallo",
      "content" => "Inhalt"
    }

    ApiCase.call("publishing.set_translation", Map.merge(input, extra), overrides)
  end

  test "creates a language: the row, one translation.added and one post.updated, both attributed; English untouched",
       ctx do
    assert {:ok, %{"action" => "created", "language" => "de-DE"}} = set(ctx)
    assert %{title: "Hallo", content: "Inhalt"} = Fx.content(ctx.post[:uuid], "de-DE")
    assert Fx.content(ctx.post[:uuid], "en-US").content == "english body"

    added =
      assert_activity_logged("publishing.translation.added", resource_uuid: ctx.post[:uuid])

    assert added.mode == "auto" and added.metadata["via"] == "api"

    updated =
      Enum.find(
        list_activities(),
        &(&1.action == "publishing.post.updated" and &1.mode == "auto")
      )

    assert updated.metadata["tool"] == "publishing.set_translation"
  end

  test "updating an existing language writes no translation.added row", ctx do
    {:ok, _} = set(ctx)
    before = Enum.count(list_activities(), &(&1.action == "publishing.translation.added"))
    assert {:ok, %{"action" => "updated"}} = set(ctx, %{"content" => "Neuer Inhalt"})

    assert Enum.count(list_activities(), &(&1.action == "publishing.translation.added")) ==
             before

    assert Fx.content(ctx.post[:uuid], "de-DE").content == "Neuer Inhalt"
  end

  test "the primary language is refused", ctx do
    assert {:error, :validation_failed, message, _} = set(ctx, %{"language" => "en-US"})
    assert message =~ "update_post"
  end

  test "an empty title or body is empty_translation and creates no row", ctx do
    assert {:error, :validation_failed, _, %{errors: [%{reason: "empty_translation"}]}} =
             set(ctx, %{"content" => "  "})

    assert {:error, :validation_failed, _, %{errors: [%{reason: "empty_translation"}]}} =
             set(ctx, %{"title" => "  "})

    assert Fx.content(ctx.post[:uuid], "de-DE") == nil
  end

  test "a language that is not enabled is language_not_enabled with allowed", ctx do
    assert {:error, :validation_failed, _,
            %{errors: [%{reason: "language_not_enabled", allowed: allowed}]}} =
             set(ctx, %{"language" => "xx"})

    assert "de-DE" in allowed
  end

  test "a legacy base-code row is promoted, not duplicated", ctx do
    # The legacy row is a content row for the base code "de" on version 1.
    {:ok, _} =
      DBStorage.create_content(%{
        version_uuid: Fx.version(ctx.post[:uuid]).uuid,
        language: "de",
        title: "Alt",
        content: "alt"
      })

    assert {:ok, _} = set(ctx)
    languages = Fx.contents(ctx.post[:uuid]) |> Enum.map(& &1.language) |> Enum.sort()
    assert languages == ["de-DE", "en-US"]
  end

  test "a language disabled after its row was written is language_not_enabled", ctx do
    {:ok, _} = set(ctx)
    Fx.languages!(["en-US", "fr-FR"])

    assert {:error, :validation_failed, _,
            %{errors: [%{reason: "language_not_enabled", allowed: allowed}]}} =
             set(ctx, %{"content" => "neu"})

    refute "de-DE" in allowed
    assert Fx.content(ctx.post[:uuid], "de-DE").content == "Inhalt"
  end

  test "og fields are written to the language row; an invalid og_image_id is refused", ctx do
    assert {:error, :validation_failed, _, %{errors: [%{path: "og_image_id"}]}} =
             set(ctx, %{"og_image_id" => "not-a-uuid"})

    assert Fx.content(ctx.post[:uuid], "de-DE") == nil

    assert {:ok, _} = set(ctx, %{"og_title" => "OG Titel", "og_description" => "OG Text"})

    og =
      PublishingContent.get_og(Fx.content(ctx.post[:uuid], "de-DE"))

    assert og["title"] == "OG Titel" and og["description"] == "OG Text"
  end

  test "NUL byte in title or content is a validation error", ctx do
    assert {:error, :validation_failed, _, %{errors: [%{path: "title"}]}} =
             set(ctx, %{"title" => "a\u0000"})

    assert {:error, :validation_failed, _, %{errors: [%{path: "content"}]}} =
             set(ctx, %{"content" => "a\u0000"})
  end

  test "a step-3 failure after the row was created reports the left-behind row and writes no body",
       ctx do
    # A publish landing right after step 1's INSERT makes the :locked_check of step 3 refuse the write.
    flag = make_ref()
    me = self()
    handler = "set-translation-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      TestRepo.config()[:telemetry_prefix] ++ [:query],
      fn _e, _m, meta, _c ->
        if meta.source == "phoenix_kit_publishing_contents" and meta.query =~ ~r/^INSERT/ and
             Process.get(flag) == nil do
          Process.put(flag, true)
          :ok = Versions.publish_version(ctx.g["slug"], ctx.post[:uuid], 1, [])
          send(me, :interleaved)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :revision_mismatch, _,
            %{reason: "went_live", left_behind: "empty row for de-DE"}} =
             set(ctx)

    assert_received :interleaved
    row = Fx.content(ctx.post[:uuid], "de-DE")
    assert row != nil and row.content in [nil, ""]
  end

  test "the text rule makes HTML a confirmed write even on a draft; a live target needs a confirmation",
       ctx do
    assert {:preview,
            %{
              "requires_confirmation" => true,
              "rows" => [%{"changes" => %{"content" => %{"raw_html" => raw}}}]
            }, _} = set(ctx, %{"content" => "<b>x</b>"}, %{dry_run?: true})

    assert raw != []

    assert {:preview, %{"requires_confirmation" => false}, _} =
             set(ctx, %{}, %{dry_run?: true})

    Fx.publish!(ctx.g["slug"], ctx.post[:uuid])

    assert {:preview, %{"requires_confirmation" => true}, _} =
             set(ctx, %{"version" => 1}, %{dry_run?: true})
  end

  test "a dry run leaves ALL tables unchanged and previews add vs update per language", ctx do
    before = Fx.table_state()

    assert {:preview, %{"rows" => [%{"action" => "add", "language" => "de-DE"}]}, _} =
             set(ctx, %{}, %{dry_run?: true})

    assert Fx.table_state() == before
    {:ok, _} = set(ctx)

    assert {:preview, %{"rows" => [%{"action" => "update"}]}, _} =
             set(ctx, %{"content" => "anders"}, %{dry_run?: true})
  end

  test "if_revision mismatch, trashed post and trashed group", ctx do
    assert {:error, :revision_mismatch, _, %{current_revision: _}} =
             set(ctx, %{"if_revision" => String.duplicate("0", 64)})

    {:ok, _} = Posts.trash_post(ctx.g["slug"], ctx.post[:uuid])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "post_trashed"}]}} = set(ctx)
    g2 = Fx.group!()
    p2 = Fx.post!(g2["slug"], %{title: "T", slug: "t"})
    {:ok, _} = Groups.trash_group(g2["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             ApiCase.call("publishing.set_translation", %{
               "post" => %{"id" => p2[:uuid]},
               "language" => "de-DE",
               "title" => "a",
               "content" => "b"
             })
  end
end
