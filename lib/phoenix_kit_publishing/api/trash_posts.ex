defmodule PhoenixKit.Modules.Publishing.API.TrashPosts do
  @moduledoc false
  # Tool `publishing.trash_posts`: move posts to the trash (reversible with restore_posts).

  alias PhoenixKit.Modules.Publishing.API.{Common, PostBatch, Presenter}
  alias PhoenixKit.Modules.Publishing.Posts

  @tool "publishing.trash_posts"

  @spec call(map(), map()) :: {:ok, map()} | {:preview, map(), String.t()}
  def call(input, ctx) do
    plan = PostBatch.plan(input["posts"], :trash, &(&1.trashed_at != nil))
    if Map.get(ctx, :dry_run?, false), do: preview(plan), else: execute(plan, ctx)
  end

  defp execute(plan, ctx) do
    opts = Common.write_opts(ctx, @tool)

    rows =
      Enum.map(plan, fn
        {:trash, ref, hit} ->
          case Posts.trash_post(hit.group.slug, hit.db_post.uuid, opts) do
            {:ok, _} -> Common.row_ok(ref, "removed", hit.db_post.uuid)
            {:error, reason} -> Common.row_from_error(ref, reason)
          end

        {:already, ref, hit} ->
          Common.row_ok(ref, "unchanged", hit.db_post.uuid)

        {:error, _ref, row} ->
          row
      end)

    Common.batch_result(rows)
  end

  defp preview(plan) do
    {rows, term} = plan |> Enum.map(&preview_entry/1) |> Enum.unzip()

    Common.preview(
      rows,
      %{"requires_confirmation" => true},
      {:trash_posts, term, Enum.map(plan, &elem(&1, 0))}
    )
  end

  # {row, fingerprint term}: the term binds a post's state, and an error row's ref and code.
  defp preview_entry({:trash, ref, hit}) do
    {versions, contents} = shown = PostBatch.shown(hit)

    {Common.row_ok(ref, "removed", hit.db_post.uuid, describe(hit, shown)),
     {:trash, Common.post_state(hit.db_post, hit.group, versions, contents)}}
  end

  defp preview_entry({:already, ref, hit}) do
    {versions, contents} = PostBatch.shown(hit)

    {Common.row_ok(ref, "unchanged", hit.db_post.uuid),
     {:already, Common.post_state(hit.db_post, hit.group, versions, contents)}}
  end

  defp preview_entry({:error, ref, row}),
    do: {row, {:error, row["error"]["code"], Common.fingerprint(ref)}}

  defp describe(hit, {_versions, contents}) do
    published? = Presenter.status(hit.db_post) == "published"

    %{
      "changes" => %{
        "status" => %{"from" => Presenter.status(hit.db_post), "to" => "trashed"}
      },
      "title" => title_of(contents),
      "languages" => contents |> Enum.map(& &1.language) |> Enum.sort(),
      "public_paths" =>
        if(published?,
          do: hit.db_post |> Presenter.public_paths(contents) |> Map.values() |> Enum.sort(),
          else: []
        )
    }
  end

  defp title_of(contents) do
    case Presenter.title_row(contents) do
      nil -> nil
      row -> row.title
    end
  end
end
