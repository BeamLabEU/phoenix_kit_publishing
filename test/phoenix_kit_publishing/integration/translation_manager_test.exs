defmodule PhoenixKit.Integration.Publishing.TranslationManagerTest do
  @moduledoc """
  Direct unit tests for `TranslationManager`'s three public destructive /
  semi-destructive functions: `add_language_to_post/5`,
  `clear_translation/4`, and `delete_language/5`.

  Happy paths are already exercised indirectly by
  `integration/activity_logging_test.exs` (for `add_language_to_post`
  and `delete_language`). This
  file focuses on the error branches and on the audit trail of
  `clear_translation` — the latter being newly-wired in this sweep.

  Async: false because every test mutates the shared `languages_config`
  setting; running these in parallel would clobber each other's
  language enablement state.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.TranslationManager
  alias PhoenixKit.Settings

  @actor_uuid "019cce93-aaaa-7000-8000-000000000456"

  defp unique_name, do: "TranslationManager #{System.unique_integer([:positive])}"

  setup do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English (United States)",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          },
          %{
            "code" => "de-DE",
            "name" => "German (Germany)",
            "is_default" => false,
            "is_enabled" => true,
            "position" => 1
          }
        ]
      })

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    {:ok, post} = Posts.create_post(group["slug"], %{title: "Seed Post"})

    %{group: group, post: post}
  end

  # ============================================================================
  # add_language_to_post/5
  # ============================================================================

  describe "add_language_to_post/5 — error branches" do
    test "returns {:error, :not_found} when the post UUID doesn't exist", %{group: group} do
      missing_uuid = "019cce93-9999-7000-8000-000000000000"

      assert {:error, :not_found} =
               TranslationManager.add_language_to_post(group["slug"], missing_uuid, "de-DE")
    end

    test "is idempotent when the same language is added twice", %{group: group, post: post} do
      assert {:ok, _} =
               TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de-DE")

      # Second call should succeed without surfacing a duplicate-language
      # error (the underlying `ensure_language_content/2` treats an existing
      # row as success so legacy base-code content can be promoted in
      # place without false-positive errors).
      assert {:ok, _} =
               TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de-DE")
    end
  end

  # ============================================================================
  # clear_translation/4
  # ============================================================================

  describe "clear_translation/4 — error branches" do
    test "returns {:error, :not_found} when the post UUID doesn't exist", %{group: group} do
      missing_uuid = "019cce93-9999-7000-8000-000000000000"

      assert {:error, :not_found} =
               TranslationManager.clear_translation(group["slug"], missing_uuid, "de-DE")
    end

    test "returns {:error, :not_found} when the language doesn't exist on the post",
         %{group: group, post: post} do
      # Post has en-US (primary) only; clearing fr-FR returns not_found
      # because no content row matches.
      assert {:error, :not_found} =
               TranslationManager.clear_translation(group["slug"], post[:uuid], "fr-FR")
    end

    test "refuses to delete the last remaining language", %{group: group, post: post} do
      # Seed post has only its primary-language content row. Clearing it
      # would leave the version with zero content rows; the validator
      # rejects this so the post never becomes unreachable.
      assert {:error, :last_language} =
               TranslationManager.clear_translation(group["slug"], post[:uuid], "en-US")
    end
  end

  describe "clear_translation/4 — happy path + activity log" do
    test "hard-deletes the content row and logs the action with the threaded actor",
         %{group: group, post: post} do
      # Add a second language so there's something to clear that's NOT
      # the last language. The `last_language` check guards otherwise.
      assert {:ok, _} =
               TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de-DE")

      [version] = DBStorage.list_versions(post[:uuid])

      # Sanity: both languages exist before the clear
      assert length(DBStorage.list_contents(version.uuid)) == 2

      assert :ok =
               TranslationManager.clear_translation(
                 group["slug"],
                 post[:uuid],
                 "de-DE",
                 nil,
                 actor_uuid: @actor_uuid
               )

      # The content row was hard-deleted (NOT archived — that's
      # `delete_language/5`'s job).
      remaining = DBStorage.list_contents(version.uuid)
      assert length(remaining) == 1
      assert hd(remaining).language == "en-US"

      # Activity log carries the threaded actor_uuid + the metadata
      # keys the AGENTS.md / FOLLOW_UP convention pins.
      assert_activity_logged("publishing.translation.cleared",
        actor_uuid: @actor_uuid,
        metadata_has: %{
          "group_slug" => group["slug"],
          "post_uuid" => post[:uuid],
          "language" => "de-DE",
          "version_uuid" => version.uuid
        }
      )
    end

    test "logs the action even when `actor_uuid` opt isn't supplied",
         %{group: group, post: post} do
      assert {:ok, _} =
               TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de-DE")

      assert :ok =
               TranslationManager.clear_translation(group["slug"], post[:uuid], "de-DE")

      # Log lands with `actor_uuid: nil` — the audit row still exists,
      # we just can't attribute it to a user.
      assert_activity_logged("publishing.translation.cleared",
        actor_uuid: nil,
        metadata_has: %{"language" => "de-DE"}
      )
    end

    test "clears the GIVEN version, not the latest (data-loss regression)",
         %{group: group, post: post} do
      # v1: en-US + de-DE.
      assert {:ok, _} =
               TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de-DE")

      # v2 (now the latest): cloned from v1, so it carries de-DE too.
      assert {:ok, _v2} = DBStorage.create_version_from(post[:uuid], 1)

      [v1, v2] = DBStorage.list_versions(post[:uuid]) |> Enum.sort_by(& &1.version_number)
      assert {v1.version_number, v2.version_number} == {1, 2}
      assert Enum.any?(DBStorage.list_contents(v1.uuid), &(&1.language == "de-DE"))
      assert Enum.any?(DBStorage.list_contents(v2.uuid), &(&1.language == "de-DE"))

      # Clear de-DE on v1 (the OLDER, non-latest version) explicitly.
      assert :ok = TranslationManager.clear_translation(group["slug"], post[:uuid], "de-DE", 1)

      # v1's de-DE is gone; v2 (latest) is untouched. Before the fix this
      # resolved `nil` -> latest version and would have deleted v2's row.
      refute Enum.any?(DBStorage.list_contents(v1.uuid), &(&1.language == "de-DE"))
      assert Enum.any?(DBStorage.list_contents(v2.uuid), &(&1.language == "de-DE"))
    end
  end

  # ============================================================================
  # delete_language/5 — error branches (happy path covered elsewhere)
  # ============================================================================

  describe "delete_language/5 — error branches" do
    test "returns {:error, :not_found} when the post UUID doesn't exist", %{group: group} do
      missing_uuid = "019cce93-9999-7000-8000-000000000000"

      assert {:error, :not_found} =
               TranslationManager.delete_language(group["slug"], missing_uuid, "de-DE")
    end

    test "returns {:error, :not_found} when the language doesn't exist on the post",
         %{group: group, post: post} do
      assert {:error, :not_found} =
               TranslationManager.delete_language(group["slug"], post[:uuid], "fr-FR")
    end

    test "refuses to archive the last remaining ACTIVE language",
         %{group: group, post: post} do
      # Single en-US content row → archiving it would leave zero
      # non-archived rows. Refused.
      assert {:error, :last_language} =
               TranslationManager.delete_language(group["slug"], post[:uuid], "en-US")
    end

    test "archives (not hard-deletes) the content row when there are >1 languages",
         %{group: group, post: post} do
      assert {:ok, _} =
               TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de-DE")

      [version] = DBStorage.list_versions(post[:uuid])

      assert :ok =
               TranslationManager.delete_language(
                 group["slug"],
                 post[:uuid],
                 "de-DE",
                 nil,
                 actor_uuid: @actor_uuid
               )

      # Sibling distinction from `clear_translation`: the row STAYS in
      # the DB with `status="archived"`, it isn't deleted.
      contents = DBStorage.list_contents(version.uuid)
      assert length(contents) == 2

      archived = Enum.find(contents, &(&1.language == "de-DE"))
      assert archived.status == "archived"

      assert_activity_logged("publishing.translation.deleted",
        actor_uuid: @actor_uuid,
        metadata_has: %{
          "group_slug" => group["slug"],
          "post_uuid" => post[:uuid],
          "language" => "de-DE",
          "version_uuid" => version.uuid
        }
      )
    end
  end
end
