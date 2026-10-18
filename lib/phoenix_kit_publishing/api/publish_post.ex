defmodule PhoenixKit.Modules.Publishing.API.PublishPost do
  @moduledoc false
  # Tool `publishing.publish_post` (spec §9.10): make a version the live one.

  alias PhoenixKit.Modules.Publishing.{Constants, DBStorage, LanguageHelpers, Versions}
  alias PhoenixKit.Modules.Publishing.API.{Common, Presenter, Refs, TextScan}

  @tool "publishing.publish_post"
  @head_chars 300

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, hit} <- Refs.resolve_post(input["post"], []) |> Refs.post_error(),
         :ok <- Refs.ensure_group_active(hit.group) |> Refs.group_error(),
         {:ok, version} <-
           Refs.resolve_version(hit.db_post, input["version"], :write) |> Refs.version_error(),
         contents = DBStorage.list_contents(version.uuid),
         :ok <- Common.check_revision(input, hit.db_post, version, primary_row(contents)),
         :ok <- title(version) do
      live? = hit.db_post.active_version_uuid == version.uuid

      cond do
        Map.get(ctx, :dry_run?, false) -> preview(hit, version, contents, live?)
        live? -> {:ok, answer("unchanged", hit, version)}
        true -> execute(hit, version, ctx)
      end
    end
  end

  # The module's own check rolls the transaction back with a bare atom; checking up front gives
  # the caller a reason and keeps a refused publish out of the failed-mutation log.
  defp title(version) do
    if Refs.primary_title_ok?(version),
      do: :ok,
      else:
        Common.invalid(
          "version",
          "the primary-language title is empty or the default title",
          "title_required"
        )
  end

  defp primary_row(contents),
    do: Enum.find(contents, &(&1.language == LanguageHelpers.get_primary_language()))

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

    languages =
      for c <- Enum.sort_by(contents, & &1.language) do
        %{
          "code" => c.language,
          "title" => c.title,
          "head" => String.slice(c.content || "", 0, @head_chars),
          "body_bytes" => byte_size(c.content || ""),
          "public_path" => Map.get(paths, c.language)
        }
      end

    raw_html =
      for c <- contents, f <- Enum.take(TextScan.scan(c.content || "")["findings"], 20) do
        %{
          "language" => c.language,
          "kind" => f["kind"],
          "line" => f["line"],
          "fragment" => f["fragment"]
        }
      end

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
      "contains_raw_html" => raw_html,
      "warnings" => warnings
    }

    term =
      {:publish_post, Common.post_state(hit.db_post, hit.group, [version], contents),
       version.version_number}

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
