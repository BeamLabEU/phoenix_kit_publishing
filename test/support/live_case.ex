defmodule PhoenixKitPublishing.LiveCase do
  @moduledoc """
  Test case for LiveView smoke tests that mount admin LiveViews
  (Index / Listing / Editor / Edit / New / Preview / PostShow /
  Settings) through `Phoenix.LiveViewTest`.

  Wires up `PhoenixKitPublishing.Test.Endpoint`, the SQL sandbox in
  shared mode (LV processes are spawned by the endpoint, not by the
  test process — they need explicit Sandbox allowances), and a
  scope-injection helper.

  ## Example

      defmodule Web.ListingLiveTest do
        use PhoenixKitPublishing.LiveCase

        test "renders the trash tab", %{conn: conn} do
          {:ok, view, html} =
            conn
            |> put_test_scope(fake_scope())
            |> live("/admin/publishing/db-test")

          assert html =~ "Trash"
          render_click(view, "trash_post", %{"uuid" => ...})
          assert render(view) =~ "Post moved to trash"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitPublishing.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitPublishing.LiveCase
      import PhoenixKitPublishing.ActivityLogAssertions
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn ->
      Sandbox.stop_owner(pid)
    end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Stores a scope in the test session so the `:assign_scope` on_mount
  hook can read it back and assign it onto the LV socket.
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end

  @doc """
  Builds a minimal admin scope for tests. Pass `roles:` to override
  the default `["Owner", "Admin"]` (the roles `Scope.admin?/1`
  pattern-matches against).

  Returns a real `%PhoenixKit.Users.Auth.Scope{}` with a `%User{}` so
  callers using `Scope.user_uuid/1` (which pattern-matches the struct
  shape) work correctly. The `cached_roles` field is set on the Scope
  struct itself so `Scope.admin?/1` `is_list/1` clause fires.
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, "019cce93-0000-7000-8000-000000000001")
    email = Keyword.get(opts, :email, "test@example.com")
    roles = Keyword.get(opts, :roles, ["Owner", "Admin"])

    user = %PhoenixKit.Users.Auth.User{
      uuid: user_uuid,
      email: email,
      first_name: "Test",
      last_name: "User"
    }

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      cached_roles: roles,
      authenticated?: true
    }
  end
end
