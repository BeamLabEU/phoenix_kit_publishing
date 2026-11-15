defmodule PhoenixKit.Modules.Publishing.SitemapRefresh do
  @moduledoc """
  Asks core's Sitemap module to regenerate after a public URL appears,
  disappears or moves: a post goes live or stops being live (publish,
  unpublish, trash or restore of a post with a live version), a live post's
  slug changes, a post's or group's `sitemap_exclude` flips, a group is
  trashed or restored, or a group is converted to slug URLs.

  It is automatic regeneration, so it follows the two switches that govern
  that: core's `sitemap_schedule_enabled` ("Automatic regeneration" on the
  Sitemap settings page; a site that turned it off regenerates by hand, and
  core's job bypasses the switch for manual jobs, so this module checks it)
  and Publishing's own `publishing_sitemap_refresh` (default on), for a site
  that wants the schedule but not a refresh per publish.

  The seam is optional and fully guarded, like the module's other ones: no
  Sitemap module loaded, the Sitemap module or either switch off, no Oban
  running, or any raise or exit, and `request/0` returns without a word to
  the caller. It never fails or blocks the mutation that called it.

  Core's `SchedulerWorker.regenerate_module_now/1` inserts an Oban job with
  args `%{scheduled: false, manual: true, source: "publishing"}`, but neither
  it nor the worker is unique, so calling it on every publish would queue one
  full regeneration per post: 1,000 for a bulk import. This module builds the
  same job through the worker's own `new/2`, scheduled `@delay_seconds` out
  and unique over the jobs still waiting (`:available`, `:scheduled`), so
  every request that arrives before the job starts collapses into it, cluster
  wide. A request after it started queues the next one, so the last change is
  always covered.
  """

  require Logger

  @worker PhoenixKit.Modules.Sitemap.SchedulerWorker
  @sitemap PhoenixKit.Modules.Sitemap

  @delay_seconds 30
  @setting_key "publishing_sitemap_refresh"
  @source "publishing"

  @doc false
  # The job args, in core's `regenerate_module_now/1` shape.
  @spec job_args() :: map()
  def job_args, do: %{scheduled: false, manual: true, source: @source}

  @doc """
  Requests one debounced sitemap regeneration. Always returns `:ok`.
  """
  @spec request() :: :ok
  def request do
    if available?() and enabled?() do
      enqueue(@worker)
    end

    :ok
  rescue
    error ->
      Logger.debug("[Publishing] sitemap refresh skipped: #{inspect(error.__struct__)}")
      :ok
  catch
    kind, _reason ->
      Logger.debug("[Publishing] sitemap refresh skipped (#{kind})")
      :ok
  end

  defp available? do
    Code.ensure_loaded?(@worker) and function_exported?(@worker, :new, 2) and
      Code.ensure_loaded?(Oban) and function_exported?(Oban, :insert, 1)
  end

  @doc """
  Whether a request would queue a job: Publishing's `publishing_sitemap_refresh`
  and core's Sitemap module and its automatic regeneration all on.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    PhoenixKit.Settings.get_boolean_setting(@setting_key, true) and
      sitemap_says?(:enabled?) and sitemap_says?(:schedule_enabled?)
  end

  defp sitemap_says?(function) do
    Code.ensure_loaded?(@sitemap) and function_exported?(@sitemap, function, 0) and
      apply(@sitemap, function, []) == true
  end

  defp enqueue(worker) do
    changeset =
      worker.new(job_args(),
        schedule_in: @delay_seconds,
        unique: [period: :infinity, states: [:available, :scheduled]]
      )

    case Oban.insert(changeset) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.debug("[Publishing] sitemap refresh not queued: #{inspect(reason)}")
        :ok
    end
  end
end
