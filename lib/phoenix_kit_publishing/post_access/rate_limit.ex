defmodule PhoenixKit.Modules.Publishing.PostAccess.RateLimit do
  @moduledoc """
  Limits password attempts on protected posts: 5 a minute per address and
  post, 30 per ten minutes per address over all posts. Counted BEFORE the
  password is checked, so a burst of parallel guesses cannot all see an
  empty bucket.

  Runs on core's Hammer backend (`PhoenixKit.Users.RateLimiter.Backend`, the
  one core's sign-in limits use). If that backend is not running the attempt
  is allowed and a warning logged — Bcrypt still costs every guess ~100 ms.
  Limits are per node.
  """

  require Logger

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
    error ->
      Logger.warning(
        "[PostAccess] rate limiter unavailable (#{inspect(error.__struct__)}); attempt allowed"
      )

      :ok
  catch
    :exit, _ ->
      Logger.warning("[PostAccess] rate limiter unavailable; attempt allowed")
      :ok
  end
end
