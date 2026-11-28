defmodule PhoenixKit.Modules.Publishing.PostAccess.LocalLimitsTest do
  @moduledoc """
  The password limiter's fallback (core's backend down): the same limits on a
  per-node ETS counter, never "allow everything".
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.PostAccess.LocalLimits
  alias PhoenixKit.Modules.Publishing.PostAccess.RateLimit

  defp key, do: "pkpub_unlock:test:#{System.unique_integer([:positive])}"

  test "the fallback limits with the same numbers: 5 allowed, the 6th refused" do
    k = key()
    for _ <- 1..5, do: assert(RateLimit.local_hit(k, 60_000, 5) == :ok)
    assert RateLimit.local_hit(k, 60_000, 5) == {:error, :rate_limited}
    # Another key has its own count.
    assert RateLimit.local_hit(key(), 60_000, 5) == :ok
  end

  test "counts live in their window: a sweep drops windows that have ended" do
    k = key()
    assert {:allow, 1} = LocalLimits.hit(k, 1_000, 5)
    assert {:allow, 2} = LocalLimits.hit(k, 1_000, 5)

    # Two windows later every counter of that window is gone.
    assert LocalLimits.sweep(System.system_time(:millisecond) + 2_000) >= 1
    assert {:allow, 1} = LocalLimits.hit(k, 1_000, 5)
  end

  test "a sweep keeps the window still running" do
    k = key()
    assert {:allow, 1} = LocalLimits.hit(k, 600_000, 30)
    LocalLimits.sweep(System.system_time(:millisecond))
    assert {:allow, 2} = LocalLimits.hit(k, 600_000, 30)
  end
end
