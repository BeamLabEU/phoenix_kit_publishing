defmodule PhoenixKit.Modules.Publishing.PostAccess.LocalLimits do
  @moduledoc """
  The password limiter's fallback: a per-node fixed-window counter in ETS,
  used only while core's Hammer backend cannot answer
  (`PostAccess.RateLimit`), so attempts stay limited with the same numbers
  instead of being let through.

  A supervised process owns the table (an ETS table dies with the process
  that created it, as `Views.VisitorTable` explains) and sweeps windows that
  have ended once a minute. Keys are `{key, window_ms, window_index}`; a
  count lives in its window only, so a window boundary resets it, as a
  fixed window does.

  When this owner is not running either, `hit/3` answers `:unavailable` and
  the caller refuses the attempt: no limiter at all must not mean no limit.
  """

  use GenServer

  @table :phoenix_kit_publishing_unlock_limits
  @sweep_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Counts one attempt for `key` in the current `window_ms` window:
  `{:allow, count}`, `{:deny, count}` past `limit`, or `:unavailable` when
  the table does not exist.
  """
  @spec hit(String.t(), pos_integer(), pos_integer()) ::
          {:allow, pos_integer()} | {:deny, pos_integer()} | :unavailable
  def hit(key, window_ms, limit) do
    index = div(System.system_time(:millisecond), window_ms)
    count = :ets.update_counter(@table, {key, window_ms, index}, 1, {{key, window_ms, index}, 0})
    if count > limit, do: {:deny, count}, else: {:allow, count}
  rescue
    ArgumentError -> :unavailable
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(System.system_time(:millisecond))
    schedule_sweep()
    {:noreply, state}
  end

  @doc false
  # Deletes every counter whose window ended before `now_ms`.
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now_ms) do
    # A window `index` of `window_ms` ends at (index + 1) * window_ms.
    spec = [
      {{{:_, :"$1", :"$2"}, :_}, [{:<, {:*, {:+, :"$2", 1}, :"$1"}, now_ms}], [true]}
    ]

    :ets.select_delete(@table, spec)
  rescue
    ArgumentError -> 0
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
