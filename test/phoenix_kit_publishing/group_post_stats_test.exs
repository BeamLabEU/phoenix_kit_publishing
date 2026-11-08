defmodule PhoenixKit.Modules.Publishing.GroupPostStatsTest do
  @moduledoc """
  `DBStorage.group_post_stats/1`: the dashboard's figures from aggregates,
  matching what loading every post used to give it.
  """

  use PhoenixKitPublishing.DataCase, async: false

  import PhoenixKitPublishing.Test.MediaFixtures

  alias PhoenixKit.Modules.Publishing.DBStorage

  test "counts live and draft posts, skips trashed ones, collects the newest version's languages" do
    group = group!("Stats")

    live = post!(group, contents: [{"en-US", "", %{}}, {"de-DE", "", %{}}])
    v1 = DBStorage.get_version(live.uuid, 1)
    published_at = ~U[2026-05-01 10:00:00Z]
    {:ok, _} = DBStorage.update_version(v1, %{status: "published", published_at: published_at})
    {:ok, _} = DBStorage.update_post(live, %{active_version_uuid: v1.uuid})

    _draft = post!(group, contents: [{"fr-FR", "", %{}}])
    _trashed = post!(group, trashed_at: DateTime.utc_now(), contents: [{"it-IT", "", %{}}])

    stats = DBStorage.group_post_stats(group.slug)

    assert stats.posts == 2
    assert stats.published == 1
    assert DateTime.compare(stats.last_published_at, published_at) == :eq
    assert stats.languages == ["de-DE", "en-US", "fr-FR"]
  end

  test "an empty group" do
    group = group!("Empty stats")

    assert DBStorage.group_post_stats(group.slug) ==
             %{posts: 0, published: 0, last_published_at: nil, languages: []}
  end
end
