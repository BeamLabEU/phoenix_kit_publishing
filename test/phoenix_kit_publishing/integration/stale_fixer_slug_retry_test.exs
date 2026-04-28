defmodule PhoenixKit.Integration.Publishing.StaleFixerSlugRetryTest do
  @moduledoc """
  Pins the PR #9 follow-up fix — `apply_stale_fix/3` retries once on
  a `:slug` unique constraint violation by appending the deterministic
  `post_uuid[0..8]` suffix. Without the retry, two concurrent fixers
  generating the same slug would crash one of them.

  Drives `apply_stale_fix/3` directly (it's `@doc false def` for this
  test) with attrs that target a slug another post has already taken.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.StaleFixer
  alias PhoenixKit.Settings

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
          }
        ]
      })

    :ok
  end

  test "retries with the post_uuid suffix when the bare slug is already taken" do
    {:ok, group} =
      Groups.add_group("Slug Race #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, _winner} = Posts.create_post(group["slug"], %{title: "Conflict Slug"})
    {:ok, target} = Posts.create_post(group["slug"], %{title: "Different Title"})

    target_uuid = target[:uuid]
    target_post = repo().get!(PublishingPost, target_uuid)
    winner_post = DBStorage.get_post(group["slug"], "conflict-slug")
    assert winner_post.slug == "conflict-slug"

    # Drive apply_stale_fix with attrs that would collide on slug.
    # The bare attempt update_post(target, slug: "conflict-slug") hits the
    # unique index; the retry suffixes with target_uuid[0..8].
    fixed = StaleFixer.apply_stale_fix(target_post, %{slug: "conflict-slug"})

    expected_suffix = String.slice(target_uuid, 0, 8)
    assert fixed.slug == "conflict-slug-#{expected_suffix}"
    assert fixed.uuid == target_uuid

    # Sanity: winner row was untouched.
    refreshed_winner = repo().get!(PublishingPost, winner_post.uuid)
    assert refreshed_winner.slug == "conflict-slug"
  end

  test "non-slug constraint failures propagate (no retry)" do
    {:ok, group} =
      Groups.add_group("Non Slug #{System.unique_integer([:positive])}", mode: "slug")

    {:ok, target} = Posts.create_post(group["slug"], %{title: "Anything"})

    target_post = repo().get!(PublishingPost, target[:uuid])

    # group_uuid pointing at a missing FK fails on foreign_key_constraint,
    # NOT on slug. apply_stale_fix should NOT retry — it returns the
    # unchanged record after logging.
    bogus_group_uuid = "019cce93-bbbb-7000-8000-000000000777"

    fixed = StaleFixer.apply_stale_fix(target_post, %{group_uuid: bogus_group_uuid})

    assert fixed == target_post
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
