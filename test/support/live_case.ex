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

    # The admin pages check `publishing.manage` / `publishing.settings`
    # through `Scope.can?/2`, which also asks whether the module is on. Tag a
    # test `publishing_enabled: false` to see the pages with it off.
    unless tags[:publishing_enabled] == false do
      {:ok, _} = PhoenixKit.Settings.update_boolean_setting("publishing_enabled", true)
    end

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
  Views the page in `dialect` (e.g. `"fr-FR"`), as production's locale hook
  would for a `/fr/…` URL: `Multilang.current_locale/0` answers it inside
  the LiveView.
  """
  def with_request_locale(conn, dialect) do
    Plug.Test.init_test_session(conn, %{"pk_test_request_locale" => dialect})
  end

  @doc """
  Builds a minimal admin scope for tests. Pass `roles:` to override
  the default `["Owner", "Admin"]` (the roles `Scope.admin?/1`
  pattern-matches against), and `permissions:` to override the default
  `["publishing", "publishing.manage", "publishing.settings"]` — every key
  the admin pages check, so a test that is not about permissions sees
  every page.

  Returns a real `%PhoenixKit.Users.Auth.Scope{}` with a `%User{}` so
  callers using `Scope.user_uuid/1` (which pattern-matches the struct
  shape) work correctly. The `cached_roles` field is set on the Scope
  struct itself so `Scope.admin?/1` `is_list/1` clause fires.
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, "019cce93-0000-7000-8000-000000000001")
    email = Keyword.get(opts, :email, "test@example.com")
    roles = Keyword.get(opts, :roles, ["Owner", "Admin"])

    permissions =
      Keyword.get(opts, :permissions, [
        "publishing",
        "publishing.manage",
        "publishing.settings"
      ])

    user = %PhoenixKit.Users.Auth.User{
      uuid: user_uuid,
      email: email,
      first_name: "Test",
      last_name: "User"
    }

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions),
      authenticated?: true
    }
  end
end
