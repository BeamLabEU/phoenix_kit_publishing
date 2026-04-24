defmodule PhoenixKit.Modules.Publishing.ActivityLog do
  @moduledoc false
  # Activity-logging helper for Publishing mutations.
  #
  # Wraps `PhoenixKit.Activity.log/1` with the `"publishing"` module key
  # injected and guards with `Code.ensure_loaded?/1` so the module stays
  # usable in environments where the Activity context isn't available
  # (library tests, misconfigured parent apps). Any exception from the
  # Activity path is swallowed with a `Logger.warning` so audit failures
  # never crash the primary mutation.

  require Logger

  @module_key "publishing"

  @spec log(map()) :: :ok
  def log(attrs) when is_map(attrs) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      try do
        PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
      rescue
        error ->
          Logger.warning(
            "PhoenixKit.Modules.Publishing activity log failed: " <>
              "#{Exception.message(error)} — " <>
              "attrs=#{inspect(Map.take(attrs, [:action, :resource_type, :resource_uuid]))}"
          )
      end
    end

    :ok
  end
end
