defmodule PhoenixKit.Modules.Publishing.PostAccess.RateLimit do
  @moduledoc """
  Limits password attempts on protected posts: 5 a minute per address and
  post, 30 per ten minutes per address over all posts. Counted BEFORE the
  password is checked, so a burst of parallel guesses cannot all see an
  empty bucket.

  Runs on core's Hammer backend (`PhoenixKit.Users.RateLimiter.Backend`, the
  one core's sign-in limits use). If that backend cannot answer, the same
  limits are counted in this node's own ETS table (`PostAccess.LocalLimits`),
  with one warning logged; if that is missing too, the attempt is refused.
  Limits are per node.
  """

  require Logger

  alias PhoenixKit.Modules.Publishing.PostAccess.LocalLimits
  alias PhoenixKit.Users.RateLimiter.Backend
  alias PhoenixKit.Utils.IpAddress

  @per_post {5, 60_000}
  @per_address {30, 600_000}

  @doc "`:ok` or `{:error, :rate_limited}` for one password attempt."
  @spec check(Plug.Conn.t(), String.t()) :: :ok | {:error, :rate_limited}
  def check(%Plug.Conn{} = conn, post_uuid) do
    address = client_address(conn)
    {post_limit, post_window} = @per_post
    {ip_limit, ip_window} = @per_address

    with :ok <- hit("pkpub_unlock:ip:#{address}", ip_window, ip_limit) do
      hit("pkpub_unlock:post:#{post_uuid}:#{address}", post_window, post_limit)
    end
  end

  # Core's reading of the client address (`IpAddress.extract_from_conn/1`,
  # the one its sign-in limits key on): a forwarded hop is believed only
  # from a peer that is a proxy (loopback/private, or `:trusted_proxies`).
  # Reading `x-forwarded-for` from any peer let a client send a new address
  # with every guess and never meet the limit.
  defp client_address(conn), do: IpAddress.extract_from_conn(conn)

  defp hit(key, window, limit) do
    case Backend.hit(key, window, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  rescue
    _error -> local_hit(key, window, limit)
  catch
    :exit, _ -> local_hit(key, window, limit)
  end

  # Core's backend could not answer: the same limits on this node's own ETS
  # counter (`LocalLimits`), so an outage never turns the limit off. When
  # that is not running either, the attempt is refused.
  @doc false
  @spec local_hit(String.t(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def local_hit(key, window, limit) do
    warn_once()

    case LocalLimits.hit(key, window, limit) do
      {:allow, _count} -> :ok
      {:deny, _count} -> {:error, :rate_limited}
      :unavailable -> {:error, :rate_limited}
    end
  end

  @warned_key {__MODULE__, :fallback_warned}

  defp warn_once do
    unless :persistent_term.get(@warned_key, false) do
      :persistent_term.put(@warned_key, true)

      Logger.warning(
        "[PostAccess] core's rate limiter is unavailable; password attempts are " <>
          "limited by this node's own counter until it is back"
      )
    end
  end
end
