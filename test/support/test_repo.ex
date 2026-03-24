defmodule PhoenixKitPublishing.Test.Repo do
  @moduledoc """
  Test-only Ecto repo for integration tests.

  Configured in config/test.exs and started by test_helper.exs.
  Uses SQL Sandbox for transaction-based test isolation.
  """
  use Ecto.Repo,
    otp_app: :phoenix_kit_publishing,
    adapter: Ecto.Adapters.Postgres
end
