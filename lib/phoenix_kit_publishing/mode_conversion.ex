defmodule PhoenixKit.Modules.Publishing.ModeConversion do
  @moduledoc """
  Converts a timestamp-mode group to slug mode: `/news/2026-11-06/01:13`
  becomes `/news/projects-0-33-0`, and every old date URL keeps working with
  a 301 to the new one.

  A group's mode is otherwise fixed at creation (the URL identity of every
  post depends on it). This is the one sanctioned change, one way only:
  slug mode has no date to go back to for posts written in it.

  What it does, in one transaction under a lock on the group row:

  - every post of the group, trashed ones included (the slug index covers
    them), gets a slug from its title in the primary language (its newest
    version), unique in the group, oldest post first so older posts keep
    the plain slug; a title that yields no slug gives `post-<date>-<time>`,
    a slug that the router would read as something else (a date, a reserved
    route word, a language code) gets a `-post` suffix, a post that already
    has a routable slug keeps it, and no post is given a slug that another
    post already answers to through a translation's `url_slug`;
  - the posts' and the group's `mode` become `"slug"`.

  It is refused (`:scheduled_posts`) while a live post of the group is dated
  ahead: only a timestamp post is held back until its date, so converting
  would publish every scheduled post at once.

  Their `post_date` / `post_time` stay, which is what makes the old URLs
  resolve: the controller finds the post by them as before and its
  canonical check answers with a 301 to the slug URL. After the commit the
  listing cache is rebuilt, the group change broadcast, a sitemap refresh
  requested (every URL of the group changed), and a
  `publishing.group.updated` activity entry written (`mode_converted`).
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.ActivityLog
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.SitemapRefresh
  alias PhoenixKit.Modules.Publishing.SlugHelpers
  alias PhoenixKit.Modules.Publishing.Web.Controller.Routing

  @doc """
  Converts the timestamp-mode group `group_slug` to slug mode. Returns
  `{:ok, %{converted: n, slugs: %{post_uuid => slug}}}`; `{:error,
  :group_not_found}`, `{:error, :invalid_mode}` for a group already in
  slug mode, or `{:error, :scheduled_posts}` while a live post is dated
  ahead. `opts` take `:actor_uuid` for the activity entry.
  """
  @spec to_slug_mode(String.t(), keyword() | map()) :: {:ok, map()} | {:error, atom()}
  def to_slug_mode(group_slug, opts \\ []) do
    result =
      repo().transaction(fn ->
        with %PublishingGroup{} = group <- lock_group(group_slug),
             :ok <- check_mode(group),
             :ok <- check_nothing_scheduled(group) do
          convert(group)
        else
          nil -> repo().rollback(:group_not_found)
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    with {:ok, summary} <- result do
      after_commit(group_slug, summary, opts)
      {:ok, summary}
    end
  end

  defp lock_group(group_slug) do
    from(g in PublishingGroup, where: g.slug == ^group_slug, lock: "FOR UPDATE")
    |> repo().one()
  end

  defp check_mode(%PublishingGroup{mode: "timestamp"}), do: :ok
  defp check_mode(_group), do: {:error, :invalid_mode}

  # A slug post has no embargo (`Constants.scheduled_ahead?/3` holds back
  # timestamp posts only), so a live post dated ahead would go public the
  # moment its mode changed.
  defp check_nothing_scheduled(group) do
    # a wall clock is at most a day away from UTC: older dates cannot be ahead
    floor = Date.add(Date.utc_today(), -1)
    now = DateTime.utc_now()
    tz = Constants.site_tz()

    scheduled? =
      from(p in PublishingPost,
        where:
          p.group_uuid == ^group.uuid and is_nil(p.trashed_at) and
            not is_nil(p.active_version_uuid) and p.post_date >= ^floor,
        select: {p.post_date, p.post_time}
      )
      |> repo().all()
      |> Enum.any?(fn {date, time} ->
        Constants.scheduled_ahead?(%{mode: "timestamp", date: date, time: time}, now, tz)
      end)

    if scheduled?, do: {:error, :scheduled_posts}, else: :ok
  end

  defp convert(group) do
    posts =
      from(p in PublishingPost,
        where: p.group_uuid == ^group.uuid,
        order_by: [asc_nulls_last: p.post_date, asc_nulls_last: p.post_time, asc: p.uuid]
      )
      |> repo().all()

    post_uuids = Enum.map(posts, & &1.uuid)
    titles = titles(post_uuids)
    url_slugs = url_slug_owners(post_uuids)
    taken = posts |> Enum.map(& &1.slug) |> Enum.reject(&(&1 in [nil, ""])) |> MapSet.new()

    {slugs, _taken} =
      Enum.map_reduce(posts, taken, fn post, taken ->
        slug = converted_slug(post, titles, url_slugs, taken)
        {{post.uuid, slug}, MapSet.put(taken, slug)}
      end)

    for {uuid, slug} <- slugs do
      from(p in PublishingPost, where: p.uuid == ^uuid)
      |> repo().update_all(set: [slug: slug, mode: "slug"])
    end

    {1, _} =
      from(g in PublishingGroup, where: g.uuid == ^group.uuid)
      |> repo().update_all(set: [mode: "slug"])

    %{converted: length(posts), slugs: Map.new(slugs)}
  end

  defp converted_slug(post, titles, url_slugs, taken) do
    if routable_slug?(post.slug) do
      post.slug
    else
      taken = MapSet.delete(taken, post.slug)

      free_slug(post, titles, fn candidate ->
        MapSet.member?(taken, candidate) or others_url_slug?(url_slugs, candidate, post)
      end)
    end
  end

  # Each post's title in the primary language (else any) of its newest
  # version.
  defp titles([]), do: %{}

  defp titles(post_uuids) do
    primary = LanguageHelpers.get_primary_language()

    from(c in PublishingContent,
      join: v in PublishingVersion,
      on: v.uuid == c.version_uuid,
      where: v.post_uuid in ^post_uuids,
      select: {v.post_uuid, v.version_number, c.language, c.title}
    )
    |> repo().all()
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {post_uuid, rows} ->
      {_, _, _, title} =
        Enum.max_by(rows, fn {_, number, language, _} -> {number, language == primary} end)

      {post_uuid, title}
    end)
  end

  # The `url_slug`s the group's contents carry, each with the posts that
  # own it. A timestamp post can hold one (the editor writes it in any
  # mode); once the group routes by slug it is a public address, so a slug
  # equal to ANOTHER post's `url_slug` would put two posts on one URL.
  defp url_slug_owners([]), do: %{}

  defp url_slug_owners(post_uuids) do
    from(c in PublishingContent,
      join: v in PublishingVersion,
      on: v.uuid == c.version_uuid,
      where: v.post_uuid in ^post_uuids and not is_nil(c.url_slug) and c.url_slug != "",
      distinct: true,
      select: {c.url_slug, v.post_uuid}
    )
    |> repo().all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp others_url_slug?(url_slugs, candidate, post),
    do: url_slugs |> Map.get(candidate, []) |> Enum.any?(&(&1 != post.uuid))

  defp free_slug(post, titles, taken?) do
    base =
      case SlugHelpers.slugify(Map.get(titles, post.uuid) || "") do
        "" -> fallback_slug(post)
        slug -> routable(slug, post)
      end

    Enum.find_value(Stream.iterate(1, &(&1 + 1)), fn
      1 -> unless taken?.(base), do: base
      n -> unless taken?.("#{base}-#{n}"), do: "#{base}-#{n}"
    end)
  end

  defp fallback_slug(%PublishingPost{post_date: %Date{} = date, post_time: %Time{} = time}),
    do: "post-#{Date.to_iso8601(date)}-#{Calendar.strftime(time, "%H%M")}"

  defp fallback_slug(_post), do: "post"

  # A timestamp post's slug was never part of its URL; one the router could
  # not reach as a slug (blank, date-shaped, a reserved route word, a
  # language code, not slug-shaped) is made anew. The rules are the ones a
  # slug post's slug is held to when it is written (`validate_slug/1`).
  defp routable_slug?(slug) when is_binary(slug) and slug != "",
    do: not Routing.date?(slug) and match?({:ok, _}, SlugHelpers.validate_slug(slug))

  defp routable_slug?(_slug), do: false

  # A slug the router would read as something else never reaches the post.
  defp routable(slug, post) do
    cond do
      routable_slug?(slug) -> slug
      routable_slug?(slug <> "-post") -> slug <> "-post"
      true -> fallback_slug(post)
    end
  end

  defp after_commit(group_slug, summary, opts) do
    ListingCache.invalidate(group_slug)
    _ = ListingCache.regenerate(group_slug)

    group_uuid =
      case repo().get_by(PublishingGroup, slug: group_slug) do
        %PublishingGroup{} = group ->
          PublishingPubSub.broadcast_group_updated(%{"uuid" => group.uuid, "slug" => group.slug})
          group.uuid

        nil ->
          nil
      end

    # every post's address changed
    SitemapRefresh.request()

    ActivityLog.log_manual(
      "publishing.group.updated",
      ActivityLog.actor_uuid(opts),
      "publishing_group",
      group_uuid,
      %{
        "slug" => group_slug,
        "mode_converted" => "timestamp_to_slug",
        "posts" => summary.converted
      },
      opts
    )
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
