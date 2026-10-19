defmodule PhoenixKit.Modules.Publishing.API.RestorePosts do
  @moduledoc false
  # Tool `publishing.restore_posts`: bring posts back from the trash.

  alias PhoenixKit.Modules.Publishing.API.{Common, Danger, PostBatch, Presenter}
  alias PhoenixKit.Modules.Publishing.{Constants, Posts}

  @tool "publishing.restore_posts"

  @spec call(map(), map()) :: {:ok, map()} | {:preview, map(), String.t()}
  def call(input, ctx) do
    plan = PostBatch.plan(input["posts"], :restore, &(&1.trashed_at == nil))
    if Map.get(ctx, :dry_run?, false), do: preview(input, plan, ctx), else: execute(plan, ctx)
  end

  defp execute(plan, ctx) do
    opts = Common.write_opts(ctx, @tool)

    rows =
      Enum.map(plan, fn
        {:restore, ref, hit} ->
          case Posts.restore_post(hit.group.slug, hit.db_post.uuid, opts) do
            {:ok, _} -> Common.row_ok(ref, "restored", hit.db_post.uuid)
            {:error, reason} -> Common.row_from_error(ref, reason)
          end

        {:already, ref, hit} ->
          Common.row_ok(ref, "unchanged", hit.db_post.uuid)

        {:error, _ref, row} ->
          row
      end)

    Common.batch_result(rows)
  end

  defp preview(input, plan, ctx) do
    entries =
      Enum.map(plan, fn
        {kind, ref, hit} when kind in [:restore, :already] ->
          {kind, ref, hit, PostBatch.shown(hit)}

        error ->
          error
      end)

    rows =
      Enum.map(entries, fn
        {:restore, ref, hit, shown} ->
          Common.row_ok(ref, "restored", hit.db_post.uuid, describe(hit, shown))

        {:already, ref, hit, _shown} ->
          Common.row_ok(ref, "unchanged", hit.db_post.uuid)

        {:error, _ref, row} ->
          row
      end)

    term =
      for {kind, _ref, hit, {versions, shown_contents}} <- entries,
          kind in [:restore, :already],
          do: {kind, Common.post_state(hit.db_post, hit.group, versions, shown_contents)}

    Common.preview(
      rows,
      %{"requires_confirmation" => Danger.restore_posts(input, ctx)},
      {:restore_posts, term, Enum.map(plan, &elem(&1, 0))}
    )
  end

  defp describe(hit, {_versions, contents}) do
    db_post = hit.db_post
    live? = db_post.active_version_uuid != nil
    scheduled? = live? and scheduled_ahead?(db_post)
    visible? = live? and not scheduled?

    %{
      "becomes_visible" => visible?,
      "changes" => %{"status" => %{"from" => "trashed", "to" => target_status(live?, scheduled?)}},
      "title" => contents |> Enum.find(&(&1.title not in [nil, ""])) |> then(&(&1 && &1.title)),
      "public_paths" =>
        if(visible?,
          do: db_post |> Presenter.public_paths(contents) |> Map.values() |> Enum.sort(),
          else: []
        )
    }
  end

  defp scheduled_ahead?(db_post) do
    Constants.scheduled_ahead?(%{
      mode: db_post.mode,
      date: db_post.post_date,
      time: db_post.post_time
    })
  end

  defp target_status(_live?, true), do: "scheduled"
  defp target_status(true, _scheduled?), do: "published"
  defp target_status(false, _scheduled?), do: "draft"
end
