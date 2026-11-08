defmodule PhoenixKit.Modules.Publishing.Views.VisitorTable do
  @moduledoc """
  Owner of the per-day visitor ETS table behind `publishing_unique_views`.

  `Views.maybe_record_view/2` asks `first_view_today?/3` once per cookieless
  request; the key is `{day, post_uuid, visitor_hash}` and the caller passes a
  HASH — no address ever reaches this table. Keys from earlier days are swept
  just after each UTC midnight (and at start), so the table holds one day of
  visitors; a per-day counter (`{:count, day}`) is what the cap reads.

  A supervised process owns the table for the same reason
  `ListingCache.LockTableOwner` owns the lock table: an ETS table dies with
  the process that created it, and a request process is gone after one page.
  When the owner is not running the lookup answers `true` — the counter
  degrades to counting every open rather than dropping views.
  """

  use GenServer

  @table :phoenix_kit_publishing_view_visitors
  # Past midnight, so the day being swept is over on every clock that agrees
  # with this one to within a second.
  @sweep_delay_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  True the first time `visitor_hash` opens `post_uuid` on `day`, false on
  every repeat. `day` is the ISO date (`Date.to_iso8601/1`): ISO strings sort
  chronologically, which is what the sweep's match spec compares — a
  `%Date{}` struct compares field by field in key order (day before month)
  and would sweep the wrong keys.
  """
  # Past this many visitors in a day the table stops remembering and every view
  # counts: a flood of distinct addresses must not turn a 16-byte row each
  # into unbounded memory, and over-counting under attack beats a crash. Read
  # from the day's own counter: the table's size also held the previous day
  # until a sweep timed from boot came round, so a busy day switched dedup off
  # for most of the next one.
  @max_rows 500_000

  @spec first_view_today?(String.t(), binary(), String.t()) :: boolean()
  def first_view_today?(post_uuid, visitor_hash, day \\ today()) do
    if day_count(day) >= @max_rows do
      true
    else
      inserted? = :ets.insert_new(@table, {{day, post_uuid, visitor_hash}, true})
      if inserted?, do: :ets.update_counter(@table, {:count, day}, 1, {{:count, day}, 0})
      inserted?
    end
  rescue
    ArgumentError -> true
  end

  defp day_count(day) do
    case :ets.lookup(@table, {:count, day}) do
      [{_key, count}] -> count
      [] -> 0
    end
  end

  @doc "Deletes every key (and counter) from a day before `today`. Returns the number removed."
  @spec sweep(String.t()) :: non_neg_integer()
  def sweep(today \\ today()) do
    :ets.select_delete(@table, [
      {{{:"$1", :_, :_}, :_}, [{:<, :"$1", today}], [true]},
      {{{:count, :"$1"}, :_}, [{:<, :"$1", today}], [true]}
    ])
  rescue
    ArgumentError -> 0
  end

  @doc false
  # Test-only: the visitor rows, so a test can prove no address is stored.
  @spec entries() :: [{{String.t(), String.t(), binary()}, true}]
  def entries do
    :ets.match_object(@table, {{:_, :_, :_}, :_})
  rescue
    ArgumentError -> []
  end

  @pepper_key {__MODULE__, :pepper}

  @doc """
  The per-boot secret the visitor hashes are keyed with. A plain hash of an
  address is a dictionary attack over the IPv4 space against a readable
  table; an HMAC under a key nobody stores makes the digests worthless
  offline, and a day-bucketed table has no reason to survive a restart.
  `nil` before the owner has started, in which case nothing is counted as
  a repeat anyway (`first_view_today?/3` answers true without the table).
  """
  @spec pepper() :: binary() | nil
  def pepper, do: :persistent_term.get(@pepper_key, nil)

  @impl true
  def init(:ok) do
    :persistent_term.put(@pepper_key, :crypto.strong_rand_bytes(32))

    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    sweep()
    {:ok, schedule_sweep(%{})}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    {:noreply, schedule_sweep(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_sweep(state) do
    Process.send_after(self(), :sweep, ms_until_next_utc_midnight() + @sweep_delay_ms)
    state
  end

  @doc false
  @spec ms_until_next_utc_midnight(DateTime.t()) :: non_neg_integer()
  def ms_until_next_utc_midnight(now \\ DateTime.utc_now()) do
    tomorrow = now |> DateTime.to_date() |> Date.add(1)
    DateTime.diff(DateTime.new!(tomorrow, ~T[00:00:00], "Etc/UTC"), now, :millisecond)
  end

  defp today, do: Date.to_iso8601(Date.utc_today())
end
