defmodule PhoenixKit.Integration.Publishing.SitemapRefreshTest do
  @moduledoc """
  Pins the sitemap seam: a post going live (or leaving the public site) asks
  core's Sitemap module to regenerate, through one debounced Oban job no
  matter how many posts change, and never when the Sitemap module is off.
  Without Oban running, the publish still succeeds.
  """

  use PhoenixKit.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitPublishing.Test.Repo

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.SitemapRefresh
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Sitemap.SchedulerWorker
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup do
    {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", true)

    {:ok, group} =
      Groups.add_group("sitemap-refresh-#{System.unique_integer([:positive])}", mode: "slug")

    %{group_slug: group["slug"]}
  end

  defp new_post(group_slug, n) do
    {:ok, post} =
      Posts.create_post(group_slug, %{
        title: "Post #{n}",
        slug: "post-#{n}",
        content: "Body #{n}."
      })

    post
  end

  defp sitemap_jobs, do: all_enqueued(worker: SchedulerWorker)

  defp clear_jobs, do: TestRepo.delete_all(Oban.Job)

  describe "with Oban running" do
    setup do
      start_supervised!({Oban, repo: TestRepo, testing: :manual, queues: false, plugins: false})
      :ok
    end

    test "publishing posts queues exactly one regeneration for them all", %{group_slug: slug} do
      posts = for n <- 1..5, do: new_post(slug, n)
      assert sitemap_jobs() == []

      for post <- posts, do: assert(:ok = Versions.publish_version(slug, post.uuid, 1))

      assert [job] = sitemap_jobs()
      assert job.args == %{"manual" => true, "scheduled" => false, "source" => "publishing"}
      assert job.queue == "sitemap"
      assert job.state == "scheduled"
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "a request after the waiting job started queues the next one", %{group_slug: slug} do
      post = new_post(slug, 1)
      :ok = Versions.publish_version(slug, post.uuid, 1)
      [job] = sitemap_jobs()

      TestRepo.update_all(
        Ecto.Query.from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "executing"]
      )

      SitemapRefresh.request()
      assert [_waiting] = all_enqueued(worker: SchedulerWorker, state: "scheduled")
    end

    test "unpublishing, trashing and restoring a live post refresh the sitemap", %{
      group_slug: slug
    } do
      a = new_post(slug, 1)
      b = new_post(slug, 2)
      :ok = Versions.publish_version(slug, a.uuid, 1)
      :ok = Versions.publish_version(slug, b.uuid, 1)

      clear_jobs()
      :ok = Versions.unpublish_post(slug, a.uuid)
      assert [_] = sitemap_jobs()

      clear_jobs()
      assert {:ok, _} = Posts.trash_post(slug, b.uuid)
      assert [_] = sitemap_jobs()

      clear_jobs()
      assert {:ok, _} = Posts.restore_post(slug, b.uuid)
      assert [_] = sitemap_jobs()
    end

    test "trashing a post that was never live leaves the sitemap alone", %{group_slug: slug} do
      draft = new_post(slug, 1)
      assert {:ok, _} = Posts.trash_post(slug, draft.uuid)
      assert sitemap_jobs() == []
    end

    test "nothing is queued while the Sitemap module is disabled", %{group_slug: slug} do
      {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", false)
      post = new_post(slug, 1)

      assert :ok = Versions.publish_version(slug, post.uuid, 1)
      assert sitemap_jobs() == []
    end
  end

  test "without Oban running the publish still succeeds", %{group_slug: slug} do
    post = new_post(slug, 1)

    assert SitemapRefresh.request() == :ok
    assert :ok = Versions.publish_version(slug, post.uuid, 1)
  end
end
