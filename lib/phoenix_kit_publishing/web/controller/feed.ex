defmodule PhoenixKit.Modules.Publishing.Web.Controller.Feed do
  @moduledoc """
  RSS 2.0 feed rendering for a publishing group.

  Served at `/<group>/feed.xml` (and the localized `/:language/<group>/feed.xml`)
  by the public controller's `{:feed, group_slug}` branch — `"feed.xml"` is a
  reserved tail segment in `Routing.parse_path/1`, so it can never collide with
  a post slug. Items come from `Listing.chronological_posts/3` (published,
  language-filtered, newest-first — independent of the group's `listing_sort`).

  The XML is hand-built iodata: RSS 2.0 is a small fixed vocabulary, and a
  dependency-free builder keeps the module's "no new deps" posture. All dynamic
  content is escaped (or CDATA-wrapped with `]]>` split, which is the one
  sequence CDATA cannot contain).

  Element order and shapes follow the RSS 2.0 spec plus the Atom `self` link
  convention (`atom:link rel="self"`), which feed validators expect.
  """

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML

  @doc """
  Renders the RSS 2.0 document for a group as iodata.

  * `group` — the public group map (`Publishing.get_group/1` shape).
  * `posts` — chronological post maps (`Listing.chronological_posts/3`).
  * `opts` — `:base_url` (scheme://host[:port], no trailing slash — required),
    `:language` (resolved request language — required), `:date_counts`
    (date → count map over the group's WHOLE published set — pass it when
    `posts` is a truncated window, else a same-day sibling outside the window
    would make a timestamp item link a date-only URL that resolves to the
    wrong post).
  """
  def render_rss(group, posts, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    language = Keyword.fetch!(opts, :language)
    scope = Keyword.get(opts, :scope)

    group_slug = group["slug"]
    date_counts = Keyword.get(opts, :date_counts) || PublishingHTML.build_date_counts(posts)
    listing_url = base_url <> PublishingHTML.group_listing_path(language, group_slug)
    self_url = base_url <> PublishingHTML.feed_path(language, group_slug, scope)

    title =
      case scope do
        {_type, value} -> "#{Publishing.translated_group_name(group, language)} · #{value}"
        nil -> Publishing.translated_group_name(group, language)
      end

    description = feed_description(group, title)

    items =
      Enum.map(posts, fn post ->
        item_xml(post, group_slug, language, date_counts, base_url)
      end)

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">\n),
      "<channel>\n",
      element("title", title),
      element("link", listing_url),
      element("description", description),
      element("language", language),
      ~s(<atom:link href="#{escape(self_url)}" rel="self" type="application/rss+xml"/>\n),
      last_build_date(posts),
      element("generator", "PhoenixKit Publishing"),
      items,
      "</channel>\n</rss>\n"
    ]
  end

  # RSS requires a channel <description>; the group map carries no prose
  # description today, so the (translated) group name doubles as one.
  defp feed_description(group, title) do
    case group["description"] do
      d when is_binary(d) and d != "" -> d
      _ -> title
    end
  end

  defp item_xml(post, group_slug, language, date_counts, base_url) do
    url = base_url <> PublishingHTML.build_post_url(group_slug, post, language, date_counts)
    title = get_in(post, [:metadata, :title]) || Publishing.Constants.default_title()

    [
      "<item>\n",
      element("title", title),
      element("link", url),
      ~s(<guid isPermaLink="true">#{escape(url)}</guid>\n),
      pub_date(post),
      item_description(post),
      "</item>\n"
    ]
  end

  # The description prefers the post's explicit description; the resolved
  # per-language excerpt (Listing puts it in :content) is the fallback.
  defp item_description(post) do
    text = get_in(post, [:metadata, :description]) || excerpt_fallback(post)

    case text do
      t when is_binary(t) and t != "" ->
        ["<description>", cdata(truncate(t, 500)), "</description>\n"]

      _ ->
        []
    end
  end

  defp excerpt_fallback(post) do
    case post[:content] do
      t when is_binary(t) -> t
      _ -> nil
    end
  end

  defp pub_date(post) do
    case effective_datetime(post) do
      nil -> []
      dt -> element("pubDate", rfc822(dt))
    end
  end

  defp last_build_date(posts) do
    posts
    |> Enum.map(&effective_datetime/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> []
      dts -> element("lastBuildDate", rfc822(Enum.max(dts, DateTime)))
    end
  end

  # Effective publish instant, mirroring the listing's sort key: post_date(+time)
  # for timestamp-mode posts, the version's published_at otherwise. UTC.
  defp effective_datetime(post) do
    cond do
      match?(%Date{}, post[:date]) ->
        time =
          case post[:time] do
            %Time{} = t -> t
            _ -> ~T[00:00:00]
          end

        DateTime.new!(post.date, time, "Etc/UTC")

      is_binary(get_in(post, [:metadata, :published_at])) ->
        case DateTime.from_iso8601(post.metadata.published_at) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      true ->
        nil
    end
  end

  # RFC-822 date the RSS spec requires. Calendar.strftime's default day/month
  # names are English, which is exactly what the format mandates (never
  # localize these).
  defp rfc822(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S +0000")
  end

  defp element(tag, content) do
    ["<", tag, ">", escape(to_string(content)), "</", tag, ">\n"]
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # CDATA keeps human prose readable in the raw feed; the one sequence CDATA
  # can't contain is its own terminator, so split any "]]>" across sections.
  defp cdata(text) do
    ["<![CDATA[", String.replace(text, "]]>", "]]]]><![CDATA[>"), "]]>"]
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end
end
