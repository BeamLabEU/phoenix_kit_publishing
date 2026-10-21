defmodule PhoenixKit.Modules.Publishing.API.UnpublishPost do
  @moduledoc false
  # Tool `publishing.unpublish_post`: take the live version down.

  alias PhoenixKit.Modules.Publishing.API.{Common, Presenter, Refs}
  alias PhoenixKit.Modules.Publishing.{DBStorage, Versions}

  @tool "publishing.unpublish_post"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, hit} <- Refs.resolve_post(input["post"], []) |> Refs.post_error(input["post"]),
         :ok <- Refs.ensure_group_active(hit.group) |> Refs.group_error(),
         {:ok, live} <- live_version(hit.db_post) do
      if Map.get(ctx, :dry_run?, false), do: preview(hit, live), else: execute(hit, live, ctx)
    end
  end

  defp live_version(db_post) do
    case DBStorage.get_active_version(db_post) do
      nil -> Common.invalid("post", "nothing is live", "not_published")
      live -> {:ok, live}
    end
  end

  defp preview(hit, live) do
    contents = DBStorage.list_contents(live.uuid)

    row = %{
      "action" => "unpublish",
      "version" => live.version_number,
      "public_paths_stop" =>
        hit.db_post |> Presenter.public_paths(contents) |> Map.values() |> Enum.sort()
    }

    Common.preview(
      [row],
      %{"requires_confirmation" => true},
      {:unpublish_post, Common.post_state(hit.db_post, hit.group, [live], contents)}
    )
  end

  defp execute(hit, live, ctx) do
    case Versions.unpublish_post(
           hit.group.slug,
           hit.db_post.uuid,
           Common.write_opts(ctx, @tool, target_status: "draft")
         ) do
      :ok ->
        db = DBStorage.get_post_by_uuid(hit.db_post.uuid, [:group])
        versions = DBStorage.list_versions(db.uuid)

        {:ok,
         %{
           "action" => "unpublished",
           "version" => live.version_number,
           "post" =>
             Presenter.write_summary(db, db.group, versions, DBStorage.list_contents(live.uuid))
         }}

      {:error, reason} ->
        Common.error(reason)
    end
  end
end
