defmodule PhoenixKit.Modules.Publishing.API.Presenter do
  @moduledoc false
  # Output shapes of spec §6.5. The WRITE summary has no title, slug or public_paths: core does not
  # store an answer containing a string that starts with `pk_` or a key named token/secret, so free
  # text must stay out of a write answer (a retry of a post titled `pk_sale` must still be replayed).

  alias PhoenixKit.Modules.Publishing.API.TextScan
  alias PhoenixKit.Modules.Publishing.{Constants, LanguageHelpers, PublishingVersion}
  alias PhoenixKit.Modules.Publishing.Web.HTML

  @doc "trashed | scheduled | published | draft (spec §6.5). `versions` is accepted for symmetry and not read."
  def status(db_post, _versions \\ [], now \\ nil, tz \\ nil) do
    cond do
      db_post.trashed_at ->
        "trashed"

      db_post.active_version_uuid &&
          scheduled?(db_post, now || DateTime.utc_now(), tz || Constants.site_tz()) ->
        "scheduled"

      db_post.active_version_uuid ->
        "published"

      true ->
        "draft"
    end
  end

  @head_chars 300
  @raw_html_per_language 20

  # Constants.scheduled_ahead?/3 reads :mode, :date and :time of a post-like map.
  defp scheduled?(db_post, now, tz),
    do:
      Constants.scheduled_ahead?(
        %{mode: db_post.mode, date: db_post.post_date, time: db_post.post_time},
        now,
        tz
      )

  @doc "How visitors can reach this version: `active` (it is live), `history` (/v/N while the post is live) or `none`."
  def public_state(db_post, version) do
    cond do
      db_post.active_version_uuid == version.uuid ->
        "active"

      db_post.active_version_uuid != nil and version.status in ["published", "archived"] ->
        "history"

      true ->
        "none"
    end
  end

  @doc "`%{language => public path}` for every language row, built with the module's own URL helper and the site origin."
  def public_paths(db_post, contents, date_counts \\ nil) do
    post = path_post(db_post, contents)

    contents
    |> Enum.map(& &1.language)
    |> Enum.uniq()
    |> Map.new(fn language ->
      {language,
       with_origin(HTML.build_post_url(db_post.group.slug, post, language, date_counts))}
    end)
  end

  defp path_post(db_post, contents) do
    %{
      mode: db_post.mode,
      slug: db_post.slug,
      date: db_post.post_date,
      time: db_post.post_time,
      url_slug: db_post.slug,
      language_slugs: Map.new(contents, &{&1.language, blank_to(&1.url_slug, db_post.slug)})
    }
  end

  defp blank_to(value, default), do: if(value in [nil, ""], do: default, else: value)

  # The origin is the site's configured one, never core's ctx.base_url (which follows the Host header).
  defp with_origin(path) do
    case HTML.public_origin() do
      origin when is_binary(origin) and origin != "" -> origin <> path
      _none -> path
    end
  end

  @doc """
  The post summary of spec §6.5. `contents` are the language rows of the version shown (the live one,
  else the latest). Options: `:now`, `:tz` (hoisted once per page) and `:date_counts`
  (`Listing.group_date_counts/1`, computed once per page).
  """
  def post_summary(db_post, group, versions, contents, opts \\ []) do
    status = status(db_post, versions, opts[:now], opts[:tz])
    sorted = Enum.sort_by(versions, & &1.version_number)
    active = Enum.find(sorted, &(&1.uuid == db_post.active_version_uuid))
    shown = active || List.last(sorted)
    title_row = title_row(contents)

    summary = %{
      "id" => db_post.uuid,
      "group" => group.slug,
      "slug" => db_post.slug,
      "mode" => db_post.mode,
      "status" => status,
      "title" => title_row && title_row.title,
      "languages" => contents |> Enum.map(& &1.language) |> Enum.sort(),
      "active_version" => active && active.version_number,
      "latest_version" => shown && List.last(sorted).version_number,
      "versions" => Enum.map(sorted, &version_entry/1),
      "date" => iso_date(db_post.post_date),
      "time" => hour_minute(db_post.post_time),
      "category_ids" => if(shown, do: PublishingVersion.get_category_uuids(shown), else: [])
    }

    if status == "published",
      do:
        Map.put(
          summary,
          "public_paths",
          public_paths(%{db_post | group: group}, contents, opts[:date_counts])
        ),
      else: summary
  end

  defp version_entry(version) do
    %{
      "number" => version.version_number,
      "status" => version.status,
      "published_at" => iso(version.published_at)
    }
  end

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  defp hour_minute(nil), do: nil
  defp hour_minute(%Time{} = time), do: Calendar.strftime(time, "%H:%M")

  @doc "The content row whose title stands for the post: the primary language's, else the first titled one."
  def title_row(contents) do
    primary = LanguageHelpers.get_primary_language()

    Enum.find(contents, &(&1.language == primary)) ||
      Enum.find(contents, &(&1.title not in [nil, ""]))
  end

  @doc "The summary without the free-text keys, for single-write answers."
  def write_summary(db_post, group, versions, contents),
    do:
      db_post
      |> post_summary(group, versions, contents)
      |> Map.drop(["title", "slug", "public_paths"])

  @doc """
  The languages a publish or schedule preview shows: code, title, the first 300 characters of the
  body and its size; with `paths` (a `%{language => path}` map) each row also carries its public path.
  """
  def goes_live_languages(contents, paths \\ nil) do
    for c <- Enum.sort_by(contents, & &1.language) do
      row = %{
        "code" => c.language,
        "title" => c.title,
        "head" => String.slice(c.content || "", 0, @head_chars),
        "body_bytes" => byte_size(c.content || "")
      }

      if paths, do: Map.put(row, "public_path", Map.get(paths, c.language)), else: row
    end
  end

  @doc "HTML found in the stored bodies, at most 20 findings per language: `[{language, kind, line, fragment}]`."
  def raw_html(contents) do
    for c <- contents,
        f <- Enum.take(TextScan.scan(c.content || "")["findings"], @raw_html_per_language) do
      %{
        "language" => c.language,
        "kind" => f["kind"],
        "line" => f["line"],
        "fragment" => f["fragment"]
      }
    end
  end

  @doc "ISO 8601 for the DateTime / NaiveDateTime fields the schemas use; nil stays nil."
  def iso(nil), do: nil
  def iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def iso(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
end
