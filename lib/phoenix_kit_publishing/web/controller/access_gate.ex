defmodule PhoenixKit.Modules.Publishing.Web.Controller.AccessGate do
  @moduledoc """
  The public controller's side of per-post access control
  (`PhoenixKit.Modules.Publishing.PostAccess`).

    * `check/2` — the decision for one post on a request. A post without
      rules answers `:public`, and the request is served exactly as before.
    * `respond/4` — turns a denial into a response:
      * a secret link → the grant goes into the access cookie and the reader
        is redirected to the clean URL (no `?access_token=` in history, logs after
        this hop, or the `Referer` of the page's links);
      * `:password` → a generic password form (no title, description or
        image of the post), status 401;
      * `:login` → the sign-in page, returning here afterwards;
      * `:forbidden` → by default the same answer as a missing post; the
        `publishing_access_forbidden_status` setting `"403"` shows a 403;
      * `:not_found` → exactly the missing-post answer, so a secret-link
        post cannot be told apart from no post at all.
    * `protect/1` — the headers every protected response carries:
      `Cache-Control: private, no-store`, `X-Robots-Tag: noindex, nofollow`,
      `Referrer-Policy: no-referrer`.
    * `unlock/2` — the password form's POST (it arrives through the
      comment route, the only POST route core declares for publishing).
  """

  use PhoenixKitWeb, :controller
  use Gettext, backend: PhoenixKitPublishing.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.PostAccess
  alias PhoenixKit.Modules.Publishing.PostAccess.Grants
  alias PhoenixKit.Modules.Publishing.PostAccess.RateLimit
  alias PhoenixKit.Modules.Publishing.PostAccess.Viewer
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias Plug.Conn.Query

  @type outcome :: :public | :protected | {:redeem, term()} | {:error, PostAccess.denial()}

  @doc "The access decision for `post` on this request."
  @spec check(Plug.Conn.t(), map()) :: outcome()
  def check(conn, post) do
    case PostAccess.access_for_post(post_uuid(post)) do
      nil ->
        :public

      access ->
        case PostAccess.authorize_view(access, viewer(conn)) do
          :ok -> :protected
          other -> other
        end
    end
  end

  @doc "The request's viewer (built once and kept in `conn.private`)."
  @spec viewer(Plug.Conn.t()) :: Viewer.t()
  def viewer(conn), do: conn.private[:publishing_viewer] || Viewer.from_conn(conn)

  defp post_uuid(%{uuid: uuid}), do: uuid
  defp post_uuid(%{"uuid" => uuid}), do: uuid
  defp post_uuid(_), do: nil

  @doc """
  Answers a post the reader may not open (or a secret link to redeem).
  `not_found` is the controller's own missing-post handler.
  """
  @spec respond(Plug.Conn.t(), term(), map(), (Plug.Conn.t(), atom() -> Plug.Conn.t())) ::
          Plug.Conn.t()
  def respond(conn, {:redeem, rule}, _post, _not_found) do
    conn
    |> Grants.put(rule.uuid, PostAccess.revision(rule))
    |> protect()
    |> redirect(to: clean_path(conn))
  end

  def respond(conn, {:error, :password}, post, _not_found) do
    render_password_form(conn, post, nil, 401)
  end

  def respond(conn, {:error, :login}, _post, _not_found) do
    return_to = clean_path(conn)

    conn
    |> protect()
    |> redirect(
      to: Routes.path("/users/log-in") <> "?" <> URI.encode_query(%{"return_to" => return_to})
    )
  end

  def respond(conn, {:error, :forbidden}, _post, not_found) do
    if forbidden_status() == 403 do
      conn
      |> protect()
      |> put_status(:forbidden)
      |> put_view(html: PublishingHTML)
      |> render(:access_forbidden, page_title: gettext("Not available"))
    else
      not_found.(conn, :not_found)
    end
  end

  def respond(conn, {:error, _not_found}, _post, not_found), do: not_found.(conn, :not_found)

  @doc "Adds the headers of a protected response."
  @spec protect(Plug.Conn.t()) :: Plug.Conn.t()
  def protect(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> assign(:publishing_protected, true)
  end

  @doc """
  The password form's POST. Only a protected, live post of the group the URL
  names can be unlocked; every failure reads the same ("That password didn't
  work"), and attempts are rate-limited before the password is checked.
  """
  @spec unlock(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unlock(conn, params) do
    with true <- Publishing.enabled?(),
         %PublishingPost{} = post <- unlock_target(params),
         access when not is_nil(access) <- PostAccess.access_for_post(post.uuid) do
      case RateLimit.check(conn, post.uuid) do
        {:error, :rate_limited} ->
          render_password_form(
            conn,
            %{uuid: post.uuid},
            gettext("Too many attempts. Please wait a minute and try again."),
            429
          )

        :ok ->
          try_password(conn, post, access, params["password"])
      end
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(html: PhoenixKitWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  defp try_password(conn, post, access, password) do
    case PostAccess.check_password(access, password) do
      {:ok, rule} ->
        conn
        |> Grants.put(rule.uuid, PostAccess.revision(rule))
        |> protect()
        |> redirect(to: back_path(conn))

      :error ->
        render_password_form(conn, %{uuid: post.uuid}, gettext("That password didn't work."), 401)
    end
  end

  defp unlock_target(params) do
    with uuid when is_binary(uuid) <- params["post_uuid"],
         group when is_binary(group) <- params["group"],
         {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %PublishingPost{
           trashed_at: nil,
           group: %PublishingGroup{slug: ^group, status: "active"},
           active_version: %{status: "published"}
         } = post <-
           DBStorage.get_post_by_uuid(uuid, [:group, :active_version]),
         false <-
           Constants.scheduled_ahead?(%{
             mode: post.mode,
             date: post.post_date,
             time: post.post_time
           }) do
      post
    else
      _ -> nil
    end
  end

  defp render_password_form(conn, post, error, status) do
    conn
    |> protect()
    |> put_status(status)
    |> put_view(html: PublishingHTML)
    |> render(:access_password,
      page_title: gettext("Protected page"),
      access_post_uuid: post_uuid(post),
      access_error: error,
      access_action: back_path(conn),
      access_login_url:
        Routes.path("/users/log-in") <>
          "?" <> URI.encode_query(%{"return_to" => back_path(conn)})
    )
  end

  # The request's own path, without `?access_token=` — where the reader goes once the
  # grant is in the cookie.
  defp clean_path(conn) do
    conn = fetch_query_params(conn)
    # Plug's encoder: the query may hold nested params (`a[b]=c`), which
    # `URI.encode_query/1` refuses with an exception.
    query = conn.query_params |> Map.drop([Viewer.key_param()]) |> Query.encode()
    path = back_path(conn)
    if query == "", do: path, else: path <> "?" <> query
  end

  defp back_path(conn) do
    path = conn.request_path

    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
         not String.contains?(path, "\\"),
       do: path,
       else: "/"
  end

  defp forbidden_status do
    case Settings.get_setting("publishing_access_forbidden_status", "404") do
      "403" -> 403
      _ -> 404
    end
  rescue
    _ -> 404
  end
end
