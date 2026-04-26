defmodule PhoenixKit.DataCase do
  @moduledoc """
  Alias for PhoenixKitPublishing.DataCase.

  The integration tests reference PhoenixKit.DataCase (from the core package).
  When running tests standalone, this module provides the same interface
  using the publishing package's own test repo.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitPublishing.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitPublishing.ActivityLogAssertions
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
