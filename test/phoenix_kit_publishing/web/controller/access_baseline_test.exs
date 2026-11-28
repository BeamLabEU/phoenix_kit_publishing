defmodule PhoenixKit.Modules.Publishing.Web.Controller.AccessBaselineTest do
  @moduledoc """
  Pins that a site with NO access rules renders every public surface exactly as
  it did before per-post access control existed.

  The snapshots under `test/fixtures/access_baseline/` were recorded on the
  commit before the access-control work (`PK_RECORD_BASELINE=1 mix test
  <this file>`), so a difference here is a change the access layer made to a
  site that never asked for it. Values that differ between runs (uuids, CSRF
  and form tokens, today's date) are normalised before the comparison; the
  status line and every response header except the session cookie are part of
  the snapshot, so a stray `cache-control` or `x-robots-tag` fails it too.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings

  @dir Path.expand("../../../fixtures/access_baseline", __DIR__)

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")
    {:ok, _} = Settings.update_setting("site_url", "")

    {:ok, group} = Groups.add_group("Baseline Blog", mode: "slug")
    slug = group["slug"]

    {:ok, one} =
      Posts.create_post(slug, %{
        title: "Baseline One",
        slug: "baseline-one",
        content: "First body about #elixir and things.\n\n## A heading\n\nMore text."
      })

    :ok = Versions.publish_version(slug, one.uuid, 1)

    {:ok, two} =
      Posts.create_post(slug, %{
        title: "Baseline Two",
        slug: "baseline-two",
        content: "Second body, also #elixir."
      })

    :ok = Versions.publish_version(slug, two.uuid, 1)

    {:ok, _draft} =
      Posts.create_post(slug, %{title: "Baseline Draft", slug: "baseline-draft", content: "x"})

    {:ok, ts_group} = Groups.add_group("Baseline News", mode: "timestamp")

    {:ok, news} =
      Posts.create_post(ts_group["slug"], %{title: "Baseline News Item", content: "News body."})

    :ok = Versions.publish_version(ts_group["slug"], news.uuid, 1)

    %{slug: slug, ts_slug: ts_group["slug"], news: news}
  end

  defp surfaces(%{slug: slug, ts_slug: ts_slug, news: news}) do
    news_path =
      "/#{ts_slug}/#{Date.to_iso8601(news.date)}/" <>
        String.slice(Time.to_iso8601(news.time), 0, 5)

    [
      {"listing", "/#{slug}"},
      {"listing_page2", "/#{slug}?page=2"},
      {"post_one", "/#{slug}/baseline-one"},
      {"post_two", "/#{slug}/baseline-two"},
      {"draft", "/#{slug}/baseline-draft"},
      {"missing", "/#{slug}/no-such-post"},
      {"feed", "/#{slug}/feed.xml"},
      {"tag_archive", "/#{slug}/tag/elixir"},
      {"tag_feed", "/#{slug}/tag/elixir/feed.xml"},
      {"search", "/#{slug}?q=body"},
      {"versioned", "/#{slug}/baseline-one/v/1"},
      {"ts_listing", "/#{ts_slug}"},
      {"ts_post", news_path},
      {"ts_date", "/#{ts_slug}/#{Date.to_iso8601(news.date)}"},
      {"ts_feed", "/#{ts_slug}/feed.xml"},
      {"unknown_group", "/no-such-group-at-all"}
    ]
  end

  test "every public surface of a site without rules is unchanged", ctx do
    results =
      for {name, path} <- surfaces(ctx) do
        conn = get(Phoenix.ConnTest.build_conn(), path)
        {name, render_snapshot(conn)}
      end

    facade =
      [
        # Same-second posts have no defined order in this list; sorted by slug.
        {"facade_list_posts",
         inspect_normalized(Enum.sort_by(Publishing.list_posts(ctx.slug, "en"), & &1.slug))},
        {"facade_list_published", inspect_normalized(Publishing.list_published(ctx.slug))}
      ]

    for {name, snapshot} <- results ++ facade do
      file = Path.join(@dir, name <> ".txt")

      if System.get_env("PK_RECORD_BASELINE") == "1" do
        File.mkdir_p!(@dir)
        File.write!(file, snapshot)
      else
        assert File.exists?(file), "missing baseline #{file}"
        expected = File.read!(file)

        assert snapshot == expected,
               "surface #{name} changed for a site without access rules:\n" <>
                 first_difference(expected, snapshot)
      end
    end
  end

  defp render_snapshot(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {k, _} -> k in ["set-cookie", "x-request-id"] end)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

    normalize("#{conn.status}\n#{headers}\n\n#{conn.resp_body}")
  end

  defp inspect_normalized(term) do
    term
    |> canonical()
    |> inspect(pretty: true, limit: :infinity, printable_limit: :infinity, width: 100)
    |> normalize()
  end

  # Small maps print in atom-table order since OTP 26, which depends on what
  # code loaded first; a map becomes a key-sorted list so the text is stable.
  defp canonical(%_{} = struct), do: struct

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {k, v} -> {k, canonical(v)} end) |> Enum.sort_by(&inspect(elem(&1, 0)))

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical({:ok, value}), do: {:ok, canonical(value)}
  defp canonical(other), do: other

  defp normalize(text) do
    text
    |> String.replace(
      ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,
      "<uuid>"
    )
    |> String.replace(~r/(name="_csrf_token"[^>]*value=")[^"]*"/, "\\1<csrf>\"")
    |> String.replace(~r/(name="csrf-token" content=")[^"]*"/, "\\1<csrf>\"")
    |> String.replace(~r/(name="ft"[^>]*value=")[^"]*"/, "\\1<ft>\"")
    # RFC 822 dates (feeds) before the <time> pass below cuts one apart:
    # lastBuildDate is today.
    |> String.replace(
      ~r/\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}/,
      "<rfc822>"
    )
    |> String.replace(~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?/, "<ts>")
    |> String.replace(~r/~U\[[^\]]*\]|~N\[[^\]]*\]|~D\[[^\]]*\]|~T\[[^\]]*\]/, "<sigil>")
    |> String.replace(~r/\d{4}-\d{2}-\d{2}/, "<date>")
    |> String.replace(~r/\b\d{2}:\d{2}(:\d{2})?\b/, "<time>")
    |> String.replace(
      ~r/\b(January|February|March|April|May|June|July|August|September|October|November|December) \d{1,2}, \d{4}/,
      "<human-date>"
    )
    |> String.replace(
      ~r/\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{1,2}, \d{4}/,
      "<human-date>"
    )
  end

  defp first_difference(expected, actual) do
    expected_lines = String.split(expected, "\n")
    actual_lines = String.split(actual, "\n")

    expected_lines
    |> Enum.zip(actual_lines)
    |> Enum.with_index(1)
    |> Enum.find(fn {{a, b}, _} -> a != b end)
    |> case do
      {{a, b}, line} -> "line #{line}\n- #{a}\n+ #{b}"
      nil -> "length differs: #{length(expected_lines)} vs #{length(actual_lines)} lines"
    end
  end
end
