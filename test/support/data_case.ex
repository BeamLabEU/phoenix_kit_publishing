defmodule PhoenixKitPublishing.DataCase do
  @moduledoc """
  Test case for tests requiring database access.

  Uses PhoenixKitPublishing.Test.Repo with SQL Sandbox for isolation.
  Tests using this case are tagged `:integration` and will be
  automatically excluded when the database is unavailable.

  ## Usage

      defmodule MyModule.Integration.SomeTest do
        use PhoenixKitPublishing.DataCase, async: true

        test "creates a record" do
          # Repo is available, transactions are isolated
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitPublishing.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end
end
