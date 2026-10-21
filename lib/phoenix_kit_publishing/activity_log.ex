defmodule PhoenixKit.Modules.Publishing.ActivityLog do
  @moduledoc false
  # Activity-logging helper for Publishing mutations: hands the entry to
  # `PhoenixKit.Activity.log/1` with the `"publishing"` module key. Core
  # never raises — a missing table, a sandbox-ownership error or a dead pool
  # is logged there and returned — so audit failures never crash the
  # primary mutation.

  alias PhoenixKit.Modules.Publishing.Shared

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

  `opts` may carry `:activity_mode` (the entry's mode, default `"manual"`)
  and `:log_metadata` (a map with string keys, merged under the entry's own
  metadata).
  """
  @spec log_manual(
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | nil,
          map(),
          keyword() | map()
        ) :: :ok
  def log_manual(action, actor_uuid, resource_type, resource_uuid, metadata \\ %{}, opts \\ []) do
    log(entry(action, actor_uuid, resource_type, resource_uuid, metadata, opts))
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

  Takes the same `:activity_mode` and `:log_metadata` options as
  `log_manual/6`.
  """
  @spec log_failed_mutation(
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | nil,
          map(),
          keyword() | map()
        ) :: :ok
  def log_failed_mutation(
        action,
        actor_uuid,
        resource_type,
        resource_uuid,
        metadata \\ %{},
        opts \\ []
      ) do
    log(
      entry(
        action,
        actor_uuid,
        resource_type,
        resource_uuid,
        Map.put(metadata, "db_pending", true),
        opts
      )
    )
  end

  # `opts` may carry `:activity_mode` (the entry's mode, default "manual") and
  # `:log_metadata` (merged UNDER the entry's own metadata). The key is NOT
  # `:mode`: the same opts reach `Groups.add_group/2`, where `:mode` is the
  # group's URL mode.
  defp entry(action, actor_uuid, resource_type, resource_uuid, metadata, opts) do
    %{
      action: action,
      mode: activity_mode(opts),
      actor_uuid: actor_uuid,
      resource_type: resource_type,
      resource_uuid: resource_uuid,
      metadata: Map.merge(string_keys(Shared.get_option(opts, :log_metadata)), metadata)
    }
  end

  defp activity_mode(opts) do
    case Shared.get_option(opts, :activity_mode) do
      mode when is_binary(mode) and mode != "" -> mode
      _other -> "manual"
    end
  end

  defp string_keys(%{} = map), do: Map.filter(map, fn {key, _value} -> is_binary(key) end)
  defp string_keys(_other), do: %{}

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
