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
        Postgrex.Error ->
          # phoenix_kit_activities table may be missing in test sandboxes
          # or hosts that haven't run the Activity migration. Silent —
          # we don't want to spam Logger on every mutation.
          :ok

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

  @doc """
  Convenience for the standard "user-driven mutation" shape — wraps `log/1`
  with `mode: "manual"` and the canonical key set so context functions only
  pass the bits that vary.
  """
  @spec log_manual(String.t(), String.t() | nil, String.t(), String.t() | nil, map()) :: :ok
  def log_manual(action, actor_uuid, resource_type, resource_uuid, metadata \\ %{}) do
    log(%{
      action: action,
      mode: "manual",
      actor_uuid: actor_uuid,
      resource_type: resource_type,
      resource_uuid: resource_uuid,
      metadata: metadata
    })
  end

  @doc """
  Extracts `:actor_uuid` from an opts keyword list or map. Returns `nil` for
  anything else. Designed to be the single point where context functions
  read the caller's user identity — keeps the call sites short.
  """
  @spec actor_uuid(keyword() | map() | nil) :: String.t() | nil
  def actor_uuid(opts) when is_list(opts), do: Keyword.get(opts, :actor_uuid)
  def actor_uuid(opts) when is_map(opts), do: Map.get(opts, :actor_uuid)
  def actor_uuid(_), do: nil
end
