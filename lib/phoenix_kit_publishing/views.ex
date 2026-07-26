defmodule PhoenixKit.Modules.Publishing.Views do
  @moduledoc """
  Post view counting over core migration **V159**'s
  `phoenix_kit_publishing_post_views` — one `(post_uuid, view_date)` row per
  day, incremented in place. Totals are `SUM(count)`.

  ## What counts as a view

  A public post-page render for a group with `views_enabled` on, where:

  - the visitor's User-Agent doesn't look like a bot/CLI (`bot_ua?/1`), and
  - the visitor's session hasn't already viewed this post today — dedup
    rides the Phoenix session cookie (`mark_viewed/2`), so there is **no
    server-side visitor state and no reader PII**: the DB only ever stores
    accepted counts. A cookieless client (most bots) still passes the
    session check every time, which is why the UA filter runs first.

  Recording is fire-and-forget (`Task.Supervisor` under core's
  `PhoenixKit.TaskSupervisor`) — a slow or failing insert never delays or
  crashes the page.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost

  @session_key "pk_publishing_viewed"
  # Session-map cap: one browser session rarely reads more than this many
  # distinct posts per day; beyond it we stop deduping (never grow the cookie
  # unboundedly).
  @session_cap 50

  @bot_ua ~r/bot|crawl|spider|slurp|feedfetcher|preview|curl|wget|python|go-http|okhttp|httpclient|headless/i

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ===========================================================================
  # Recording
  # ===========================================================================

  @doc """
  Records a view for `post_uuid` unless the request is a bot or this session
  already viewed the post today. Returns the (possibly updated) conn —
  callers thread it so the dedup marker lands in the session cookie.
  """
  def maybe_record_view(conn, post_uuid) when is_binary(post_uuid) do
    cond do
      bot_ua?(List.first(Plug.Conn.get_req_header(conn, "user-agent"))) ->
        conn

      viewed_or_capped?(conn, post_uuid) ->
        conn

      true ->
        record_async(post_uuid)
        mark_viewed(conn, post_uuid)
    end
  rescue
    # A view counter must never break the page — session store quirks,
    # anything: give the conn back. (Supervisor absence is an EXIT, handled
    # in record_async — rescue alone would not catch it.)
    _ -> conn
  end

  def maybe_record_view(conn, _), do: conn

  defp record_async(post_uuid) do
    Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fn ->
      record_view(post_uuid)
    end)
  catch
    # A missing task supervisor (bare test host) is an EXIT (noproc), not an
    # exception — `rescue` would sail past it. Count synchronously instead.
    :exit, _ -> record_view(post_uuid)
  end

  @doc """
  Increments today's rollup row for a post (upsert). Safe under concurrency —
  the conflict target is the primary key and the update is an atomic
  `count = count + 1`.
  """
  def record_view(post_uuid, date \\ nil) do
    date = date || Date.utc_today()

    repo().insert_all(
      "phoenix_kit_publishing_post_views",
      [
        [
          post_uuid: Ecto.UUID.dump!(post_uuid),
          view_date: date,
          count: 1
        ]
      ],
      on_conflict: [inc: [count: 1]],
      conflict_target: [:post_uuid, :view_date]
    )

    :ok
  rescue
    error ->
      Logger.warning("[Publishing.Views] record_view failed: #{Exception.message(error)}")
      :error
  end

  @doc "True when the User-Agent looks like a bot/CLI (or is absent)."
  def bot_ua?(nil), do: true
  def bot_ua?(ua) when is_binary(ua), do: Regex.match?(@bot_ua, ua)

  # Already viewed today — or the session's dedup list is full. A full list
  # counts as "viewed" so the failure mode is UNDERcounting: the alternative
  # (keep counting once the marker can't be stored) would let one hot session
  # inflate every post it touches past the cap.
  defp viewed_or_capped?(conn, post_uuid) do
    today = Date.to_iso8601(Date.utc_today())

    case Plug.Conn.get_session(conn, @session_key) do
      %{^today => uuids} when is_list(uuids) ->
        post_uuid in uuids or length(uuids) >= @session_cap

      _ ->
        false
    end
  end

  defp mark_viewed(conn, post_uuid) do
    today = Date.to_iso8601(Date.utc_today())
    seen = Plug.Conn.get_session(conn, @session_key) || %{}

    today_list =
      case seen do
        %{^today => uuids} when is_list(uuids) -> uuids
        _ -> []
      end

    # Only today's map survives — yesterday's entries would just grow the
    # cookie for a dedup window that has already passed. (The cap was checked
    # in viewed_or_capped?/2 before anything was recorded.)
    Plug.Conn.put_session(conn, @session_key, %{today => [post_uuid | today_list]})
  end

  # ===========================================================================
  # Reads
  # ===========================================================================

  @doc "All-time view totals for a list of post uuids: `%{post_uuid => total}`."
  def totals(post_uuids) when is_list(post_uuids) do
    from(v in "phoenix_kit_publishing_post_views",
      where: v.post_uuid in ^Enum.map(post_uuids, &Ecto.UUID.dump!/1),
      group_by: v.post_uuid,
      select: {v.post_uuid, sum(v.count)}
    )
    |> repo().all()
    |> Map.new(fn {raw_uuid, total} -> {Ecto.UUID.load!(raw_uuid), total} end)
  rescue
    # Table missing (host not yet on V159) — every reader degrades to zeros.
    _ -> %{}
  end

  @doc "All-time view total for one post."
  def total(post_uuid), do: totals([post_uuid]) |> Map.get(post_uuid, 0)

  @doc """
  A group's top posts by views in the trailing `days` window:
  `[{post_uuid, views}]`, most-viewed first, capped at `limit`.
  """
  def top_posts(group_slug, days, limit) when days > 0 do
    since = Date.add(Date.utc_today(), -days + 1)

    from(v in "phoenix_kit_publishing_post_views",
      join: p in PublishingPost,
      on: p.uuid == type(v.post_uuid, UUIDv7),
      join: g in PublishingGroup,
      on: g.uuid == p.group_uuid,
      where: g.slug == ^group_slug and v.view_date >= ^since,
      group_by: v.post_uuid,
      order_by: [desc: sum(v.count)],
      select: {v.post_uuid, sum(v.count)},
      limit: ^limit
    )
    |> repo().all()
    |> Enum.map(fn {raw_uuid, views} -> {Ecto.UUID.load!(raw_uuid), views} end)
  rescue
    _ -> []
  end
end
