defmodule PhoenixKit.Modules.Publishing.API.PublishPost do
  @moduledoc false
  # Tool `publishing.publish_post`: make a version the live one.

  alias PhoenixKit.Modules.Publishing.API.{Common, Presenter, Refs}
  alias PhoenixKit.Modules.Publishing.{Constants, DBStorage, Versions}

  @tool "publishing.publish_post"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, hit} <- Refs.resolve_post(input["post"], []) |> Refs.post_error(input["post"]),
         :ok <- Refs.ensure_group_active(hit.group) |> Refs.group_error(),
         {:ok, version} <-
           Refs.resolve_version_or_live(hit.db_post, input["version"]) |> Refs.version_error(),
         contents = DBStorage.list_contents(version.uuid),
         :ok <- Common.check_revision(input, hit.db_post, version, Refs.primary_row(contents)),
         :ok <- Refs.require_primary_title(contents) do
      live? = hit.db_post.active_version_uuid == version.uuid

      cond do
        Map.get(ctx, :dry_run?, false) -> preview(hit, version, contents, live?)
        live? -> {:ok, answer("unchanged", hit, version)}
        true -> execute(hit, version, ctx)
      end
    end
  end

  defp execute(hit, version, ctx) do
    case Versions.publish_version(
           hit.group.slug,
           hit.db_post.uuid,
           version.version_number,
           Common.write_opts(ctx, @tool)
         ) do
      :ok -> {:ok, answer("published", hit, version)}
      {:error, reason} -> Common.error(reason)
    end
  end

  defp answer(action, hit, version) do
    db = DBStorage.get_post_by_uuid(hit.db_post.uuid, [:group])
    versions = DBStorage.list_versions(db.uuid)

    %{
      "action" => action,
      "version" => version.version_number,
      "post" =>
        Presenter.write_summary(db, db.group, versions, DBStorage.list_contents(version.uuid))
    }
  end

  # --- preview ---------------------------------------------------------------------------

  defp preview(hit, version, contents, live?) do
    paths = Presenter.public_paths(hit.db_post, contents)
    previous = if live?, do: nil, else: DBStorage.get_active_version(hit.db_post)

    languages = Presenter.goes_live_languages(contents, paths)

    warnings =
      for c <- contents, String.trim(c.content || "") == "" do
        %{
          "code" => "empty_translation",
          "language" => c.language,
          "message" => "the body of this language is empty"
        }
      end

    row = %{
      "action" => if(live?, do: "unchanged", else: "publish"),
      "goes_live" => %{"version" => version.version_number, "languages" => languages},
      "archived" => previous && %{"version" => previous.version_number},
      "scheduled_until" => scheduled_until(hit.db_post),
      "warnings" => warnings
    }

    row = Map.merge(row, Presenter.raw_html_report(contents))

    term = {:publish_post, Common.post_state(hit.db_post, hit.group, [version], contents)}

    Common.preview([row], %{"requires_confirmation" => true}, term)
  end

  defp scheduled_until(%{mode: "timestamp", post_date: %Date{} = date, post_time: time} = db_post) do
    view = %{mode: db_post.mode, date: date, time: time}

    if Constants.scheduled_ahead?(view),
      do: "#{Date.to_iso8601(date)}T#{Calendar.strftime(time || ~T[00:00:00], "%H:%M")}",
      else: nil
  end

  defp scheduled_until(_db_post), do: nil
end
