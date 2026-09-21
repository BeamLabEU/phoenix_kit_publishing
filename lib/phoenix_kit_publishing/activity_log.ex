defmodule PhoenixKit.Modules.Publishing.ActivityLog do
  @moduledoc false
  # Activity-logging helper for Publishing mutations: hands the entry to
  # `PhoenixKit.Activity.log/1` with the `"publishing"` module key. Core
  # never raises — a missing table, a sandbox-ownership error or a dead pool
  # is logged there and returned — so audit failures never crash the
  # primary mutation.

  @module_key "publishing"

  @spec log(map()) :: :ok
  def log(attrs) when is_map(attrs) do
    _ = PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
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

  @doc """
  Logs a failed user-driven mutation with `db_pending: true` so the audit
  trail still captures the user-initiated action when the primary write
  failed (DB constraint, sandbox crash, etc).

  `resource_uuid` is `nil` when the failure happened before a row was
  assigned a UUID — that's expected for create paths. Metadata callers
  pass should still be PII-safe (slugs / names / status, never email or
  free-text body).
  """
  @spec log_failed_mutation(
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | nil,
          map()
        ) :: :ok
  def log_failed_mutation(action, actor_uuid, resource_type, resource_uuid, metadata \\ %{}) do
    log(%{
      action: action,
      mode: "manual",
      actor_uuid: actor_uuid,
      resource_type: resource_type,
      resource_uuid: resource_uuid,
      metadata: Map.put(metadata, "db_pending", true)
    })
  end

  @doc """
  Compresses a mutation-failure reason into a PII-safe string for failure
  metadata. Changesets carry the submitted params (free text, names), so
  they collapse to `"changeset_error"` rather than being inspected.
  """
  @spec reason_string(term()) :: String.t()
  def reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_string(%Ecto.Changeset{}), do: "changeset_error"
  def reason_string(reason), do: inspect(reason)
end
