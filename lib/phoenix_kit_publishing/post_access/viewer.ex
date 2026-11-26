defmodule PhoenixKit.Modules.Publishing.PostAccess.Viewer do
  @moduledoc """
  Who is asking to open a post, as `PostAccess.authorize_view/2` needs it:
  the signed-in user (if any) and their roles, whether they hold the
  `publishing` permission (editors always pass), the password and link
  grants in their access cookie, and a secret-link key the request carried.

  `from_conn/1` builds it from a public request. The query parameter
  `pk_preview=anonymous` (the editor's "Preview as anonymous" link) drops
  everything but the key and the grants' absence: the page renders exactly as
  a stranger would see it.
  """

  alias PhoenixKit.Modules.Publishing.PostAccess.Grants
  alias PhoenixKit.Users.Auth.Scope

  defstruct user_uuid: nil,
            role_names: MapSet.new(),
            bypass?: false,
            anonymous?: true,
            grants: %{},
            key: nil,
            preview?: false

  @type t :: %__MODULE__{
          user_uuid: String.t() | nil,
          role_names: MapSet.t(),
          bypass?: boolean(),
          anonymous?: boolean(),
          grants: map(),
          key: String.t() | nil,
          preview?: boolean()
        }

  @preview_param "pk_preview"
  @key_param "key"

  @doc "A reader with nothing: no account, no grants."
  @spec anonymous() :: t()
  def anonymous, do: %__MODULE__{}

  @doc "A viewer from a scope (or nil) and a grants map."
  @spec new(term(), map()) :: t()
  def new(scope, grants \\ %{}) do
    user_uuid = Scope.user_uuid(scope)

    %__MODULE__{
      user_uuid: user_uuid,
      anonymous?: is_nil(user_uuid),
      role_names: MapSet.new(Scope.user_roles(scope)),
      bypass?: Scope.can?(scope, "publishing"),
      grants: if(is_map(grants), do: grants, else: %{})
    }
  end

  @doc """
  The viewer of a public request. Reads the scope the router assigned, the
  access cookie and the `?key=` / `?pk_preview=` query parameters.
  """
  @spec from_conn(Plug.Conn.t()) :: t()
  def from_conn(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    params = conn.query_params
    key = valid_key(params[@key_param])

    if params[@preview_param] == "anonymous" do
      %__MODULE__{key: key, preview?: true}
    else
      viewer = new(conn.assigns[:phoenix_kit_current_scope], Grants.read(conn))
      %{viewer | key: key}
    end
  end

  @doc """
  True when this viewer could be allowed into some protected post (signed in,
  holding grants or the editor's bypass). An anonymous reader with no cookie
  cannot, so listings skip the rules query for them.
  """
  @spec may_hold_access?(t() | nil) :: boolean()
  def may_hold_access?(nil), do: false

  def may_hold_access?(%__MODULE__{} = viewer),
    do: viewer.bypass? or not viewer.anonymous? or map_size(viewer.grants) > 0

  # A key is url-safe base64 of 32 bytes; anything else is not one of ours
  # and must not reach the digest compare (or a log line).
  defp valid_key(key) when is_binary(key) and byte_size(key) in 40..64 do
    if key =~ ~r/\A[A-Za-z0-9_-]+\z/, do: key
  end

  defp valid_key(_), do: nil
end
