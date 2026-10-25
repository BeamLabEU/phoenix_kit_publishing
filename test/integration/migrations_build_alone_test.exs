defmodule PhoenixKitPublishing.Integration.MigrationsBuildAloneTest do
  @moduledoc """
  This module's chain builds all of its tables exactly as core's chain does,
  on a database where core did not create them — the proof core needs before
  it stops creating them (core's
  `dev_docs/plans/2026-10-25-module-table-ownership.md`). Rows are not
  compared.

  `PhoenixKit.TestSupport.ModuleChainCheck` does the work in a scratch schema
  of its own, through `Ecto.Migrator` — so `ExUnit.Case`, not a sandboxed case,
  and `async: false`. Excluded (`:requires_module_chain_check`, see
  `test_helper.exs`) against a core that does not ship the check yet.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.TestSupport.ModuleChainCheck

  @moduletag :integration
  @moduletag :requires_module_chain_check
  @moduletag timeout: :timer.minutes(3)

  test "the chain builds the module's tables without core" do
    assert :ok =
             ModuleChainCheck.check(
               PhoenixKitPublishing.Test.Repo,
               PhoenixKitPublishing.Migrations
             )
  end
end
