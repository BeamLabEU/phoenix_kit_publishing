defmodule PhoenixKit.Modules.Publishing.API.PublishPostTest do
  use PhoenixKit.DataCase, async: false

  import Ecto.Query
  import PhoenixKitPublishing.ActivityLogAssertions

  alias PhoenixKit.Modules.Publishing.{
    Constants,
    Groups,
    Posts,
    PublishingContent,
    PublishingPost,
    PublishingVersion,
    Versions
  }

  alias PhoenixKitPublishing.Test.ApiCase
  alias PhoenixKitPublishing.Test.ApiFixtures, as: Fx
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    Fx.languages!()
    g = Fx.group!()
    post = Fx.post!(g["slug"], %{title: "Hello", slug: "hello"})
    Fx.body!(g["slug"], post[:uuid], "# Body")
    %{g: g, post: post}
  end

  defp publish(ctx, extra \\ %{}, overrides \\ %{}),
    do:
      ApiCase.call(
        "publishing.publish_post",
        Map.merge(%{"post" => Fx.ref(ctx.post)}, extra),
        overrides
      )

  test "publishes the highest draft: the pointer, the version status and an attributed activity row",
       ctx do
    assert {:ok, %{"action" => "published", "version" => 1, "post" => %{"status" => "published"}}} =
             publish(ctx)

    assert Fx.db_post(ctx.post[:uuid]).active_version_uuid == Fx.version(ctx.post[:uuid]).uuid
    assert Fx.version(ctx.post[:uuid]).status == "published"
    row = assert_activity_logged("publishing.version.published", resource_uuid: ctx.post[:uuid])

    assert row.mode == "auto" and row.metadata["via"] == "api" and
             row.metadata["tool"] == "publishing.publish_post"
  end

  test "a rollback: naming an archived version makes it live and archives the current one", ctx do
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid], 1)
    {:ok, _} = Versions.create_new_version(ctx.g["slug"], ctx.post, %{}, %{})
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid], 2)
    assert Fx.version(ctx.post[:uuid], 1).status == "archived"

    assert {:ok, %{"action" => "published", "version" => 1}} = publish(ctx, %{"version" => 1})
    assert Fx.version(ctx.post[:uuid], 1).status == "published"
    assert Fx.version(ctx.post[:uuid], 2).status == "archived"
  end

  test "a version that is already live is unchanged and writes nothing", ctx do
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid])
    n = length(list_activities())
    assert {:ok, %{"action" => "unchanged"}} = publish(ctx, %{"version" => 1})
    assert length(list_activities()) == n
  end

  test "title_required: an empty title, the default title; a legacy base-code primary row with a real title passes",
       ctx do
    {:ok, _} = Versions.create_new_version(ctx.g["slug"], ctx.post, %{}, %{})
    {:ok, post} = Posts.read_post_by_uuid(ctx.post[:uuid], nil, 2)
    {:ok, _} = Posts.update_post(ctx.g["slug"], post, %{"title" => ""}, publish: false)

    assert {:error, :validation_failed, _, %{errors: [%{reason: "title_required"}]}} =
             publish(ctx, %{"version" => 2})

    {:ok, _} =
      Posts.update_post(ctx.g["slug"], post, %{"title" => Constants.default_title()},
        publish: false
      )

    assert {:error, :validation_failed, _, %{errors: [%{reason: "title_required"}]}} =
             publish(ctx, %{"version" => 2})

    # refused up front: the module's own check never runs, so it logs no failed publish either
    refute_activity_logged("publishing.version.published")

    # the primary row stored under the legacy base code "en" with a real title
    TestRepo.update_all(
      from(c in PublishingContent, where: c.version_uuid == ^Fx.version(ctx.post[:uuid], 1).uuid),
      set: [language: "en"]
    )

    assert {:ok, %{"action" => "published"}} = publish(ctx, %{"version" => 1})
  end

  test "with no version named, a live post with no draft answers unchanged and writes nothing",
       ctx do
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid])
    n = length(list_activities())

    assert {:ok, %{"action" => "unchanged", "version" => 1}} = publish(ctx)
    assert length(list_activities()) == n
  end

  test "no_draft_version and version_not_found", ctx do
    # the only version is archived and nothing is live: there is nothing to default to
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid])

    TestRepo.update_all(from(p in PublishingPost, where: p.uuid == ^ctx.post[:uuid]),
      set: [active_version_uuid: nil]
    )

    TestRepo.update_all(from(v in PublishingVersion, where: v.post_uuid == ^ctx.post[:uuid]),
      set: [status: "archived"]
    )

    assert {:error, :validation_failed, _, %{errors: [%{reason: "no_draft_version"}]}} =
             publish(ctx)

    assert {:error, :validation_failed, _, %{errors: [%{reason: "version_not_found"}]}} =
             publish(ctx, %{"version" => 9})
  end

  test "a trashed post and a trashed group are refused", ctx do
    {:ok, _} = Posts.trash_post(ctx.g["slug"], ctx.post[:uuid])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "post_trashed"}]}} = publish(ctx)
    g2 = Fx.group!()
    p2 = Fx.post!(g2["slug"], %{title: "T", slug: "t"})
    {:ok, _} = Groups.trash_group(g2["slug"])

    assert {:error, :validation_failed, _, %{errors: [%{reason: "group_trashed"}]}} =
             ApiCase.call("publishing.publish_post", %{"post" => %{"id" => p2[:uuid]}})
  end

  test "the preview lists the languages, the version that is archived, HTML in the stored text and an empty-language warning",
       ctx do
    Fx.publish!(ctx.g["slug"], ctx.post[:uuid], 1)
    {:ok, _} = Versions.create_new_version(ctx.g["slug"], ctx.post, %{}, %{})
    Fx.body!(ctx.g["slug"], ctx.post[:uuid], "line one\n<b>stored html</b>", 2)
    Fx.translation!(ctx.g["slug"], ctx.post[:uuid], "de-DE", "Hallo", "", 2)

    assert {:preview, %{"requires_confirmation" => true, "rows" => [row]}, _} =
             publish(ctx, %{}, %{dry_run?: true})

    assert %{
             "goes_live" => %{"version" => 2, "languages" => languages},
             "archived" => %{"version" => 1}
           } = row

    assert Enum.map(languages, & &1["code"]) == ["de-DE", "en-US"]
    assert Enum.find(languages, &(&1["code"] == "en-US"))["head"] =~ "line one"
    # `<b>` and `</b>` are two findings of the scan
    assert [
             %{"language" => "en-US", "kind" => "html", "line" => 2, "fragment" => "<b>" <> _},
             %{"language" => "en-US", "kind" => "html", "line" => 2, "fragment" => "</b>"}
           ] = row["contains_raw_html"]

    assert [%{"code" => "empty_translation", "language" => "de-DE"}] = row["warnings"]
  end

  test "the preview caps head at 300 characters, counts body bytes, gives each language its public path and caps HTML findings at 20 per language",
       ctx do
    long = String.duplicate("a", 350)
    Fx.body!(ctx.g["slug"], ctx.post[:uuid], long <> String.duplicate("<br>\n", 30))

    Fx.translation!(
      ctx.g["slug"],
      ctx.post[:uuid],
      "de-DE",
      "Hallo",
      "ééé " <> String.duplicate("<br>\n", 30)
    )

    assert {:preview, %{"rows" => [row]}, _} = publish(ctx, %{}, %{dry_run?: true})
    assert %{"goes_live" => %{"languages" => [de, en]}} = row

    assert String.length(en["head"]) == 300 and en["head"] == String.duplicate("a", 300)
    assert en["body_bytes"] == byte_size(Fx.content(ctx.post[:uuid], "en-US").content)
    assert de["body_bytes"] == byte_size(Fx.content(ctx.post[:uuid], "de-DE").content)
    assert de["body_bytes"] > String.length(Fx.content(ctx.post[:uuid], "de-DE").content)
    assert de["head"] =~ "ééé"

    assert en["public_path"] == "/en/#{ctx.g["slug"]}/hello"
    assert de["public_path"] == "/de/#{ctx.g["slug"]}/hello"

    findings = Enum.group_by(row["contains_raw_html"], & &1["language"])
    assert length(findings["en-US"]) == 20
    assert length(findings["de-DE"]) == 20
  end

  test "the preview of a future timestamp post has scheduled_until" do
    ts = Fx.group!(mode: "timestamp")
    p = Fx.post!(ts["slug"], %{title: "Soon"})
    {:ok, post} = Posts.read_post_by_uuid(p[:uuid])
    future = Date.utc_today() |> Date.add(10)

    {:ok, _} =
      Posts.update_post(ts["slug"], post, %{"published_at" => "#{future}T09:30:00Z"},
        publish: false
      )

    assert {:preview, %{"rows" => [%{"scheduled_until" => until}]}, _} =
             ApiCase.call("publishing.publish_post", %{"post" => %{"id" => p[:uuid]}}, %{
               dry_run?: true
             })

    assert until == "#{future}T09:30"
  end

  test "a dry run leaves ALL tables unchanged and flags the confirmation", ctx do
    before = Fx.table_state()

    assert {:preview, %{"requires_confirmation" => true}, fingerprint} =
             publish(ctx, %{}, %{dry_run?: true})

    assert Fx.table_state() == before
    assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "an if_revision taken from get_post lets the publish through", ctx do
    {:ok, %{"revision" => revision}} =
      ApiCase.call("publishing.get_post", %{"post" => Fx.ref(ctx.post)})

    assert {:ok, %{"action" => "published"}} = publish(ctx, %{"if_revision" => revision})
  end

  test "if_revision mismatch is revision_mismatch with current_revision", ctx do
    assert {:error, :revision_mismatch, _, %{current_revision: _}} =
             publish(ctx, %{"if_revision" => String.duplicate("0", 64)})
  end
end
