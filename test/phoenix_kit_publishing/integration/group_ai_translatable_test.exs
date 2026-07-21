defmodule PhoenixKitPublishing.GroupAITranslatableTest do
  @moduledoc """
  Integration pins for the group-name AI-translation adapter:

    * fetch/2 resolves a group by ROW uuid (the "uuid" key the public group
      map now exposes)
    * source_fields/2 exposes the lowercase {{name}} placeholder field
    * put_translation/4 merges one language into data["name_i18n"] without
      dropping siblings (the FOR UPDATE single-JSONB-row contract), caps to
      the primary column's max length, and refuses blank output
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing, as: PublishingFacade
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKitPublishing.GroupAITranslatable

  defp create_group! do
    {:ok, group} = Groups.add_group("AI Group #{System.unique_integer([:positive])}")
    group
  end

  test "the public group map exposes the row uuid" do
    group = create_group!()
    assert is_binary(group["uuid"])
    assert {:ok, _} = Ecto.UUID.cast(group["uuid"])
  end

  test "fetch/2 resolves by uuid; unknown uuid errors with the behaviour's atom" do
    group = create_group!()

    assert {:ok, fetched} = GroupAITranslatable.fetch("publishing_group", group["uuid"])
    assert fetched.slug == group["slug"]

    assert {:error, :resource_not_found} =
             GroupAITranslatable.fetch("publishing_group", Ecto.UUID.generate())
  end

  test "source_fields/2 exposes the primary name under the lowercase key" do
    group = create_group!()
    {:ok, fetched} = GroupAITranslatable.fetch("publishing_group", group["uuid"])

    assert GroupAITranslatable.source_fields(fetched, "en-US") == %{"name" => group["name"]}
  end

  test "put_translation/4 merges a language and preserves siblings" do
    group = create_group!()
    {:ok, _} = Groups.update_group(group["slug"], %{"name_i18n" => %{"et" => "Eesti nimi"}})
    {:ok, fetched} = GroupAITranslatable.fetch("publishing_group", group["uuid"])

    assert {:ok, _} =
             GroupAITranslatable.put_translation(fetched, "de-DE", %{"name" => "Deutscher Name"},
               actor_uuid: nil
             )

    {:ok, updated} = Groups.get_group(group["slug"])
    assert updated["name_i18n"]["de-DE"] == "Deutscher Name"
    # The sibling override written before the job must survive the merge.
    assert updated["name_i18n"]["et"] == "Eesti nimi"
  end

  test "put_translation/4 caps the translated name to the column max" do
    group = create_group!()
    {:ok, fetched} = GroupAITranslatable.fetch("publishing_group", group["uuid"])
    long = String.duplicate("x", Constants.max_group_name_length() + 50)

    assert {:ok, _} =
             GroupAITranslatable.put_translation(fetched, "fr-FR", %{"name" => long}, [])

    {:ok, updated} = Groups.get_group(group["slug"])
    assert String.length(updated["name_i18n"]["fr-FR"]) == Constants.max_group_name_length()
  end

  test "put_translation/4 refuses a blank or absent translated name" do
    group = create_group!()
    {:ok, fetched} = GroupAITranslatable.fetch("publishing_group", group["uuid"])

    assert {:error, :no_translated_name} =
             GroupAITranslatable.put_translation(fetched, "de-DE", %{"name" => "   "}, [])

    assert {:error, :no_translated_name} =
             GroupAITranslatable.put_translation(fetched, "de-DE", %{}, [])
  end

  test "put_translation/4 logs a publishing.group.updated audit row with the actor" do
    group = create_group!()
    {:ok, fetched} = GroupAITranslatable.fetch("publishing_group", group["uuid"])
    actor = Ecto.UUID.generate()

    assert {:ok, _} =
             GroupAITranslatable.put_translation(fetched, "et", %{"name" => "Eesti"},
               actor_uuid: actor
             )

    %{entries: activities} = PhoenixKit.Activity.list(resource_uuid: group["uuid"], preload: [])

    assert Enum.any?(activities, fn a ->
             a.action == "publishing.group.updated" and a.mode == "auto" and
               a.actor_uuid == actor and a.metadata["source"] == "ai_translation" and
               a.metadata["target_lang"] == "et"
           end)
  end

  test "put_translation/4 rolls back when the group vanished between fetch and merge" do
    group = create_group!()
    {:ok, fetched} = GroupAITranslatable.fetch("publishing_group", group["uuid"])
    {:ok, _} = Groups.remove_group(group["slug"], force: true)

    assert {:error, :resource_not_found} =
             GroupAITranslatable.put_translation(fetched, "de-DE", %{"name" => "Name"}, [])
  end

  test "ai_translatables/0 registers both publishing adapters" do
    assert {"publishing_group", GroupAITranslatable} in PublishingFacade.ai_translatables()
  end
end
