defmodule PhoenixKit.Modules.Publishing.API.CreateVersion do
  @moduledoc false
  # Tool `publishing.create_version` (spec §9.8). Never touches the live pointer.

  alias PhoenixKit.Modules.Publishing.API.{Common, Presenter, Refs}
  alias PhoenixKit.Modules.Publishing.{DBStorage, Versions}

  @tool "publishing.create_version"

  def call(input, ctx) do
    with :ok <- exclusive(input),
         {:ok, hit} <- Refs.resolve_post(input["post"], []) |> Refs.post_error(),
         :ok <- Refs.ensure_group_active(hit.group) |> Refs.group_error(),
         {:ok, source} <- source(hit.db_post, input) do
      if Map.get(ctx, :dry_run?, false), do: preview(hit, source), else: execute(hit, source, ctx)
    end
  end

  defp exclusive(%{"blank" => true, "from_version" => _}),
    do: Common.invalid("blank", "give blank or from_version, not both")

  defp exclusive(_input), do: :ok

  # nil = blank; a number = clone that version; absent = clone the latest.
  defp source(_db_post, %{"blank" => true}), do: {:ok, nil}

  defp source(db_post, input) do
    versions = DBStorage.list_versions(db_post.uuid)

    number =
      input["from_version"] ||
        versions |> Enum.map(& &1.version_number) |> Enum.max(fn -> nil end)

    cond do
      Enum.any?(versions, &(&1.version_number == number)) ->
        {:ok, number}

      is_nil(number) ->
        Common.invalid("post", "the post has no version to copy", "version_not_found")

      true ->
        Common.invalid("from_version", "the version does not exist", "version_not_found")
    end
  end

  defp preview(hit, source) do
    row = %{"action" => "create_version", "source_version" => source, "blank" => is_nil(source)}

    term =
      {:create_version,
       Common.post_state(hit.db_post, hit.group, DBStorage.list_versions(hit.db_post.uuid), []),
       source}

    Common.preview([row], %{"requires_confirmation" => false}, term)
  end

  defp execute(hit, source, ctx) do
    case Versions.create_version_from(
           hit.group.slug,
           hit.db_post.uuid,
           source,
           %{},
           Common.write_opts(ctx, @tool)
         ) do
      {:ok, _post} ->
        db = DBStorage.get_post_by_uuid(hit.db_post.uuid, [:group])
        versions = DBStorage.list_versions(db.uuid)
        latest = Enum.max_by(versions, & &1.version_number)

        {:ok,
         %{
           "action" => "created",
           "version" => latest.version_number,
           "post" =>
             Presenter.write_summary(db, db.group, versions, DBStorage.list_contents(latest.uuid))
         }}

      {:error, reason} ->
        Common.error(reason)
    end
  end
end
