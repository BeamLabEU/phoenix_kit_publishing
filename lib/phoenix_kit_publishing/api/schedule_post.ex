defmodule PhoenixKit.Modules.Publishing.API.SchedulePost do
  @moduledoc false
  # Tool `publishing.schedule_post` (spec §9.11): publish at a future time in a timestamp-mode group.

  alias PhoenixKit.Modules.Publishing.{Constants, DBStorage, LanguageHelpers, Posts, Versions}
  alias PhoenixKit.Modules.Publishing.API.{Common, Presenter, Refs}

  @tool "publishing.schedule_post"
  @format ~r/\A(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})\z/

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, {date, time}} <- parse(input["publish_at"]),
         {:ok, hit} <- Refs.resolve_post(input["post"], []) |> Refs.post_error(),
         :ok <- Refs.ensure_group_active(hit.group) |> Refs.group_error(),
         :ok <- timestamp_group(hit.group),
         {:ok, version} <-
           Refs.resolve_version(hit.db_post, input["version"], :write) |> Refs.version_error(),
         :ok <- Common.check_revision(input, hit.db_post, version, primary_row(version)),
         :ok <- future(date, time),
         same? = same_slot?(hit.db_post, date, time),
         :ok <- free(hit, date, time, same?),
         :ok <- title(version) do
      live? = hit.db_post.active_version_uuid == version.uuid

      cond do
        Map.get(ctx, :dry_run?, false) -> preview(input, hit, version, date, time, same?, live?)
        same? and live? -> {:ok, answer("unchanged", input, hit, version)}
        true -> execute(input, hit, version, date, time, same?, ctx)
      end
    end
  end

  defp parse(value) when is_binary(value) do
    with [_, d, hh, mm] <- Regex.run(@format, value),
         {:ok, date} <- Date.from_iso8601(d),
         {:ok, time} <- Time.new(String.to_integer(hh), String.to_integer(mm), 0) do
      {:ok, {date, time}}
    else
      _ ->
        Common.invalid(
          "publish_at",
          "must be YYYY-MM-DDTHH:MM on the site clock, without seconds or a zone"
        )
    end
  end

  defp parse(_other), do: Common.invalid("publish_at", "must be a string")

  defp primary_row(version),
    do:
      Enum.find(
        DBStorage.list_contents(version.uuid),
        &(&1.language == LanguageHelpers.get_primary_language())
      )

  defp timestamp_group(%{mode: "timestamp"}), do: :ok

  defp timestamp_group(_group),
    do: Common.invalid("post", "only timestamp-mode groups can schedule", "not_timestamp_group")

  defp future(date, time) do
    if DateTime.compare(
         Constants.from_site_wall(date, time, Constants.site_tz()),
         DateTime.utc_now()
       ) == :gt,
       do: :ok,
       else:
         Common.invalid(
           "publish_at",
           "must be later than now on the site clock",
           "schedule_in_past"
         )
  end

  defp same_slot?(db_post, date, time) do
    db_post.post_date == date and db_post.post_time != nil and
      db_post.post_time.hour == time.hour and db_post.post_time.minute == time.minute
  end

  defp free(_hit, _date, _time, true), do: :ok

  defp free(hit, date, time, false) do
    if DBStorage.timestamp_slot_taken?(hit.group.slug, date, time),
      do: Common.invalid("publish_at", "another post holds that minute", "slot_taken"),
      else: :ok
  end

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

  # --- write: two non-atomic steps ----------------------------------------------------------

  defp execute(input, hit, version, date, time, same?, ctx) do
    publish_at = Date.to_iso8601(date) <> "T" <> Calendar.strftime(time, "%H:%M")

    with :ok <- move(hit, version, publish_at, same?, ctx),
         :ok <- publish(hit, version, ctx) do
      {:ok, answer("scheduled", input, hit, version)}
    end
  end

  defp move(_hit, _version, _publish_at, true, _ctx), do: :ok

  defp move(hit, version, publish_at, false, ctx),
    do: set_date(hit, version, publish_at <> ":00Z", ctx)

  defp set_date(hit, version, published_at, ctx) do
    with {:ok, post} <-
           Refs.read_post_for_preview(hit.db_post.uuid, nil, version.version_number),
         {:ok, _} <-
           Posts.update_post(
             hit.group.slug,
             post,
             %{"published_at" => published_at},
             Common.write_opts(ctx, @tool, publish: false)
           ) do
      :ok
    else
      {:error, reason} -> Common.error(reason)
    end
  end

  defp publish(hit, version, ctx) do
    case Versions.publish_version(
           hit.group.slug,
           hit.db_post.uuid,
           version.version_number,
           Common.write_opts(ctx, @tool)
         ) do
      :ok -> :ok
      {:error, reason} -> rollback(hit, version, ctx, Common.error(reason))
    end
  end

  # Best effort: put the old date and time back, logged like the other API writes. A post that was
  # already on the slot never moved, so there is nothing to undo.
  defp rollback(hit, version, ctx, error) do
    original = hit.db_post

    case old_stamp(original) do
      nil ->
        with_left_behind(error)

      stamp ->
        if set_date(hit, version, stamp, ctx) == :ok, do: error, else: with_left_behind(error)
    end
  end

  defp old_stamp(%{post_date: %Date{} = date, post_time: %Time{} = time}),
    do: Date.to_iso8601(date) <> "T" <> Calendar.strftime(time, "%H:%M") <> ":00Z"

  defp old_stamp(_db_post), do: nil

  defp with_left_behind({:error, code, message, context}),
    do: {:error, code, message, Map.put(context, :left_behind, ["date", "time"])}

  defp answer(action, input, hit, version) do
    db = DBStorage.get_post_by_uuid(hit.db_post.uuid, [:group])

    %{
      "action" => action,
      "version" => version.version_number,
      "publish_at" => input["publish_at"],
      "time_zone" => Constants.site_tz(),
      "post" =>
        Presenter.write_summary(
          db,
          db.group,
          DBStorage.list_versions(db.uuid),
          DBStorage.list_contents(version.uuid)
        )
    }
  end

  defp preview(input, hit, version, date, time, same?, live?) do
    previous = if live?, do: nil, else: DBStorage.get_active_version(hit.db_post)

    row = %{
      "action" => if(same? and live?, do: "unchanged", else: "schedule"),
      "version" => version.version_number,
      "publish_at" => input["publish_at"],
      "time_zone" => Constants.site_tz(),
      "public_url_changes_with_date" => not same?,
      "archived" => previous && %{"version" => previous.version_number},
      "disappears_until" =>
        if(hit.db_post.active_version_uuid != nil and not same?,
          do: input["publish_at"],
          else: nil
        )
    }

    term =
      {:schedule_post, Common.post_state(hit.db_post, hit.group, [version], []),
       version.version_number, Date.to_iso8601(date), Calendar.strftime(time, "%H:%M")}

    Common.preview([row], %{"requires_confirmation" => true}, term)
  end
end
