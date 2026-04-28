defmodule PhoenixKitPublishing.ActivityLogAssertions do
  @moduledoc """
  Helpers for asserting activity log rows landed with the right action,
  module, actor, and metadata. Imported into
  `PhoenixKitPublishing.DataCase` and `PhoenixKitPublishing.LiveCase`
  so every DB-backed test can reach them.

  Queries `phoenix_kit_activities` directly via raw SQL — the activities
  table lives in core PhoenixKit and we don't ship its Ecto schema in
  this module. Postgres returns UUIDs as raw 16-byte binaries; the
  helpers normalise both sides to the canonical string form so callers
  can pass `post.uuid` (already a string) without manual conversion.
  """

  import ExUnit.Assertions
  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  @doc """
  Asserts exactly one activity row exists for `action` matching the given
  optional filters. Returns the matched row (a map) so further assertions
  can be made on it.

  ## Options

    * `:resource_uuid` — match on `resource_uuid`
    * `:actor_uuid`    — match on `actor_uuid`
    * `:metadata_has`  — assert each key/value pair is present in
                         `metadata` (JSONB subset match; extra keys ok)

  ## Example

      assert_activity_logged("publishing.post.trashed",
        resource_uuid: post_uuid,
        actor_uuid: user_uuid,
        metadata_has: %{"group_slug" => "blog"}
      )
  """
  def assert_activity_logged(action, opts \\ []) do
    rows = query_activities(action: action)

    matching =
      Enum.filter(rows, fn row ->
        matches_opts?(row, opts)
      end)

    case matching do
      [row] ->
        row

      [] ->
        flunk("""
        Expected one activity row for #{inspect(action)}, found none matching the criteria.
        Rows for this action: #{inspect(rows)}
        Criteria: #{inspect(opts)}
        """)

      many ->
        flunk("""
        Expected exactly one activity row for #{inspect(action)}, found #{length(many)}.
        Matches: #{inspect(many)}
        """)
    end
  end

  @doc "Asserts no activity row exists for `action` (with the same optional filters)."
  def refute_activity_logged(action, opts \\ []) do
    rows = query_activities(action: action)

    matching =
      Enum.filter(rows, fn row ->
        matches_opts?(row, opts)
      end)

    case matching do
      [] ->
        :ok

      rows ->
        flunk("""
        Expected no activity row for #{inspect(action)}, found #{length(rows)}.
        Rows: #{inspect(rows)}
        """)
    end
  end

  @doc "Returns all raw activity rows for debugging."
  def list_activities do
    query_activities([])
  end

  # ── internals ──────────────────────────────────────────────────

  defp query_activities(filters) do
    query =
      "SELECT action, module, mode, actor_uuid, resource_type, resource_uuid, metadata FROM phoenix_kit_activities ORDER BY inserted_at DESC"

    %{rows: rows, columns: cols} = SQL.query!(TestRepo, query)

    rows
    |> Enum.map(fn row ->
      cols
      |> Enum.zip(row)
      |> Map.new(fn {k, v} -> {String.to_atom(k), normalize(v)} end)
    end)
    |> filter_rows(filters)
  end

  defp normalize({:ok, uuid}) when is_binary(uuid), do: uuid
  defp normalize(value), do: value

  defp filter_rows(rows, filters) do
    Enum.filter(rows, fn row ->
      Enum.all?(filters, fn {k, v} -> Map.get(row, k) == v end)
    end)
  end

  defp matches_opts?(row, opts) do
    match_opt(opts, :resource_uuid, &uuid_match?(row.resource_uuid, &1)) and
      match_opt(opts, :actor_uuid, &uuid_match?(row.actor_uuid, &1)) and
      match_opt(opts, :metadata_has, &metadata_subset?(row.metadata, &1))
  end

  defp match_opt(opts, key, check_fun) do
    case Keyword.fetch(opts, key) do
      :error -> true
      {:ok, value} -> check_fun.(value)
    end
  end

  defp metadata_subset?(metadata, subset) do
    metadata = metadata || %{}
    Enum.all?(subset, fn {k, v} -> Map.get(metadata, k) == v end)
  end

  # Postgres returns UUIDs as raw <<16 bytes>>; callers pass string UUIDs.
  # Normalise both sides to the string form so comparisons work.
  defp uuid_match?(nil, nil), do: true
  defp uuid_match?(nil, _), do: false
  defp uuid_match?(_, nil), do: false

  defp uuid_match?(row_uuid, expected) when is_binary(row_uuid) and byte_size(row_uuid) == 16 do
    {:ok, encoded} = Ecto.UUID.load(row_uuid)
    encoded == expected
  end

  defp uuid_match?(row_uuid, expected) when is_binary(row_uuid), do: row_uuid == expected
end
