defmodule PhoenixKit.Modules.Publishing.Views do
  @moduledoc """
  Post view counting over core migration **V159**'s
  `phoenix_kit_publishing_post_views` — one `(post_uuid, view_date)` row per
  day, incremented in place. Totals are `SUM(count)`.

  ## What counts as a view

  A public post-page render for a group with `views_enabled` on, where:

  - the visitor's User-Agent doesn't look like a bot/CLI (`bot_ua?/1`), and
  - the visitor's session hasn't already viewed this post today — dedup
    rides the Phoenix session cookie (`mark_viewed/2`); the DB only ever
    stores accepted counts, never a reader, and
  - under `publishing_unique_views` (default on) the visitor hasn't opened
    this post today: a session carrying the dedup marker IS the visitor, a
    cookieless request (a curl loop, a fresh session) is a hash of its
    address — the last `x-forwarded-for` hop when present — held for the
    day in `Views.VisitorTable`. The raw address is never stored. With the
    setting off every page open counts, for a site that wants to see how
    often a page was opened at all.

  Recording is fire-and-forget (`Task.Supervisor` under core's
  `PhoenixKit.TaskSupervisor`) — a slow or failing insert never delays or
  crashes the page.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.Views.VisitorTable
  alias PhoenixKit.Settings

  @session_key "pk_publishing_viewed"
  @unique_views_key "publishing_unique_views"
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
  @spec maybe_record_view(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def maybe_record_view(conn, post_uuid) when is_binary(post_uuid) do
    cond do
      bot_ua?(List.first(Plug.Conn.get_req_header(conn, "user-agent"))) ->
        conn

      # Off means every page open counts — the session marker is a dedup
      # too, so it is neither consulted nor written.
      not unique_views?() ->
        record_async(post_uuid)
        conn

      viewed_or_capped?(conn, post_uuid) ->
        conn

      repeat_visitor?(conn, post_uuid) ->
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
  @spec record_view(String.t(), Date.t() | nil) :: :ok | :error
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

  @doc "The `publishing_unique_views` setting: one view per visitor per post per day."
  @spec unique_views?() :: boolean()
  def unique_views?, do: Settings.get_boolean_setting(@unique_views_key, true)

  # Unique views on, and this visitor already opened the post today. A
  # session that carries the marker was answered by viewed_or_capped?/2 —
  # it is the visitor, and it has not seen this post today. Everything else
  # is identified by its hashed address for the day.
  defp repeat_visitor?(conn, post_uuid) do
    not session_marked?(conn) and
      not VisitorTable.first_view_today?(post_uuid, visitor_hash(conn))
  end

  defp session_marked?(conn), do: is_map(Plug.Conn.get_session(conn, @session_key))

  # Never the address itself, and never the client's word for it: the LAST
  # forwarded hop is the one the site's own proxy appended (the peer it saw);
  # the first is whatever the client wrote, so hashing it let a curl loop
  # mint a new visitor per request. Without a forwarded header, the socket
  # address. The digest is an HMAC under the table owner's per-boot pepper,
  # truncated — a plain hash of an IPv4 address is a 2^32 dictionary.
  # One spelling per address, or "2001:db8::1" and "2001:0db8:0:0:0:0:0:1"
  # would be two visitors. A value that is not an address (a forged header)
  # is kept as written — it still hashes to one visitor per spelling.
  defp canonical_address(nil), do: nil

  defp canonical_address(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, ip} -> ip |> :inet.ntoa() |> to_string()
      _ -> address
    end
  end

  defp visitor_hash(conn) do
    address =
      conn
      |> Plug.Conn.get_req_header("x-forwarded-for")
      |> Enum.join(",")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last()

    address = canonical_address(address) || inspect(conn.remote_ip)

    case VisitorTable.pepper() do
      nil -> :crypto.hash(:sha256, address) |> binary_part(0, 16)
      pepper -> :crypto.mac(:hmac, :sha256, pepper, address) |> binary_part(0, 16)
    end
  end

  @doc "True when the User-Agent looks like a bot/CLI (or is absent)."
  @spec bot_ua?(String.t() | nil) :: boolean()
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
  @spec totals([String.t()]) :: %{optional(String.t()) => non_neg_integer()}
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
  @spec total(String.t()) :: non_neg_integer()
  def total(post_uuid), do: totals([post_uuid]) |> Map.get(post_uuid, 0)

  @doc """
  A group's top posts by views in the trailing `days` window:
  `[{post_uuid, views}]`, most-viewed first, capped at `limit`.
  """
  @spec top_posts(String.t(), pos_integer(), pos_integer()) :: [{String.t(), non_neg_integer()}]
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
