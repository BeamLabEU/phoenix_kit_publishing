defmodule PhoenixKit.Modules.Publishing.PostAccess.Grants do
  @moduledoc """
  The reader's access cookie: which password and secret-link rules this
  browser has passed.

  One cookie, `pk_pub_access`, encrypted and signed with the endpoint's
  `secret_key_base` (`Plug.Conn.put_resp_cookie/4` with `encrypt: true`), so a
  reader can neither read nor forge it; a tampered cookie decodes to nothing.
  It holds `%{rule_uuid => %{"r" => revision, "e" => expires_unix}}`:

    * the revision is the rule's at the time of the grant — rotating a
      password bumps it and every older grant stops working;
    * a revoked or deleted secret link stops working because its rule does;
    * a grant lives `publishing_access_grant_days` days (default 30).

  At most #{50} grants are kept (the oldest expiring first are dropped), so
  the cookie stays well under the 4 KB browsers allow.
  """

  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings

  @cookie "pk_pub_access"
  @max_grants 50
  @default_days 30

  @doc "The cookie's name."
  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie

  @doc "The grants the request's cookie holds (an empty map when none or tampered)."
  @spec read(Plug.Conn.t()) :: map()
  def read(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_cookies(conn, encrypted: [@cookie])

    case conn.cookies[@cookie] do
      grants when is_map(grants) -> grants
      _ -> %{}
    end
  rescue
    # No secret_key_base (a bare test conn) — no grants.
    _ -> %{}
  end

  @doc "Adds a grant for `rule_uuid` at `revision` and writes the cookie."
  @spec put(Plug.Conn.t(), String.t(), integer()) :: Plug.Conn.t()
  def put(%Plug.Conn{} = conn, rule_uuid, revision) do
    days = grant_days()
    now = System.system_time(:second)
    expires = now + days * 86_400

    grants =
      conn
      |> read()
      |> Enum.filter(fn {_uuid, grant} -> is_map(grant) and (grant["e"] || 0) > now end)
      |> Map.new()
      |> Map.put(rule_uuid, %{"r" => revision, "e" => expires})
      |> cap()

    Plug.Conn.put_resp_cookie(conn, @cookie, grants,
      encrypt: true,
      max_age: days * 86_400,
      http_only: true,
      same_site: "Lax",
      secure: secure?(conn),
      path: "/"
    )
  end

  # Secure when the request came over TLS or the site's public origin is
  # https: behind a TLS-terminating proxy `conn.scheme` says `:http` on
  # every request, which left the cookie without `Secure`.
  defp secure?(%Plug.Conn{scheme: :https}), do: true

  defp secure?(_conn) do
    case PublishingHTML.public_origin() do
      "https://" <> _ -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp cap(grants) when map_size(grants) <= @max_grants, do: grants

  defp cap(grants) do
    grants
    |> Enum.sort_by(fn {_uuid, grant} -> -grant["e"] end)
    |> Enum.take(@max_grants)
    |> Map.new()
  end

  @doc "How long a grant lasts, in days (`publishing_access_grant_days`, 1–365)."
  @spec grant_days() :: pos_integer()
  def grant_days do
    case Integer.parse(to_string(Settings.get_setting("publishing_access_grant_days", "30"))) do
      {days, _} when days >= 1 and days <= 365 -> days
      _ -> @default_days
    end
  rescue
    _ -> @default_days
  end
end
