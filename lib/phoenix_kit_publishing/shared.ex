defmodule PhoenixKit.Modules.Publishing.Shared do
  @moduledoc """
  Shared helper functions used across publishing submodules.

  These functions were extracted to eliminate duplication between
  Posts, Versions, TranslationManager, and Groups.
  """

  require Logger

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Users.Auth.Scope

  # ============================================================================
  # UUID Validation
  # ============================================================================

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc false
  @spec uuid_format?(term()) :: boolean()
  def uuid_format?(str) when is_binary(str), do: Regex.match?(@uuid_regex, str)
  def uuid_format?(_), do: false

  # ============================================================================
  # Option / Audit Helpers
  # ============================================================================

  @doc false
  @spec fetch_option(map() | keyword() | nil, atom()) :: term()
  def fetch_option(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  def fetch_option(opts, key) when is_list(opts) do
    Keyword.get(opts, key)
  end

  def fetch_option(_, _), do: nil

  @doc false
  @spec audit_metadata(term() | nil, :create | :update) :: map()
  def audit_metadata(nil, _action), do: %{}

  def audit_metadata(scope, action) do
    user_uuid =
      scope
      |> Scope.user_uuid()
      |> normalize_audit_value()

    user_email =
      scope
      |> Scope.user_email()
      |> normalize_audit_value()

    base =
      case action do
        :create ->
          %{
            created_by_uuid: user_uuid,
            created_by_email: user_email
          }

        _ ->
          %{}
      end

    base
    |> maybe_put_audit(:updated_by_uuid, user_uuid)
    |> maybe_put_audit(:updated_by_email, user_email)
  end

  @dialyzer {:nowarn_function, normalize_audit_value: 1}
  defp normalize_audit_value(nil), do: nil
  defp normalize_audit_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_audit_value(value), do: to_string(value)

  defp maybe_put_audit(map, _key, nil), do: map
  defp maybe_put_audit(map, key, value), do: Map.put(map, key, value)

  # ============================================================================
  # Scope Resolution
  # ============================================================================

  @doc false
  @spec resolve_scope_user_uuids(term() | nil) :: String.t() | nil
  def resolve_scope_user_uuids(nil), do: nil

  def resolve_scope_user_uuids(scope) do
    scope
    |> Scope.user_uuid()
    |> normalize_audit_value()
  end

  @doc """
  Reads the current user's UUID from a LiveView socket's
  `phoenix_kit_current_scope` assign. Returns `nil` when the LV is
  mounted in a logged-out context (no scope, no user). LV callers
  thread the result into mutating context functions as
  `actor_uuid: actor_uuid_from_socket(socket)` so the activity log
  records who initiated the change.
  """
  @spec actor_uuid_from_socket(struct() | map() | any()) :: String.t() | nil
  def actor_uuid_from_socket(%{assigns: assigns}), do: actor_uuid_from_assigns(assigns)
  def actor_uuid_from_socket(_), do: nil

  defp actor_uuid_from_assigns(%{phoenix_kit_current_scope: %{user: %{uuid: uuid}}})
       when is_binary(uuid),
       do: uuid

  defp actor_uuid_from_assigns(_), do: nil

  # ============================================================================
  # Post Reading (shared by Posts, Versions, TranslationManager)
  # ============================================================================

  @doc """
  Reads a post back from DB using the appropriate method for the post's mode.

  Used after create/update operations to return a consistent post map.
  """
  @spec read_back_post(String.t(), term(), term() | nil, String.t() | nil, pos_integer() | nil) ::
          {:ok, map()} | {:error, :not_found}
  def read_back_post(group_slug, identifier, db_post, language, version_number) do
    case resolve_read_strategy(db_post, identifier) do
      {:timestamp, date, time} ->
        DBStorage.read_post_by_datetime(group_slug, date, time, language, version_number)

      {:slug, slug} ->
        DBStorage.read_post(group_slug, slug, language, version_number)
    end
  end

  defp resolve_read_strategy(db_post, _identifier)
       when not is_nil(db_post) and db_post.mode == "timestamp" and
              not is_nil(db_post.post_date) and not is_nil(db_post.post_time) do
    {:timestamp, db_post.post_date, db_post.post_time}
  end

  defp resolve_read_strategy(db_post, _identifier)
       when not is_nil(db_post) and not is_nil(db_post.slug) do
    {:slug, db_post.slug}
  end

  defp resolve_read_strategy(db_post, identifier) when is_binary(identifier) do
    case parse_timestamp_path(identifier) do
      {:ok, date, time, _version, _lang} ->
        {:timestamp, date, time}

      _ ->
        {:slug, (db_post && db_post.slug) || identifier}
    end
  end

  defp resolve_read_strategy(db_post, identifier) do
    {:slug, (db_post && db_post.slug) || identifier}
  end

  # ============================================================================
  # Timestamp Path Parsing
  # ============================================================================

  @doc false
  @spec parse_timestamp_path(String.t()) ::
          {:ok, Date.t(), Time.t() | nil, pos_integer() | nil, String.t() | nil} | nil
  def parse_timestamp_path(identifier) do
    parts =
      identifier
      |> to_string()
      |> String.trim_leading("/")
      |> String.split("/", trim: true)

    case parts do
      [date_str] ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> {:ok, date, nil, nil, nil}
          _ -> nil
        end

      [date_str, time_str | rest] ->
        with {:ok, date} <- Date.from_iso8601(date_str),
             {:ok, time} <- parse_time(time_str) do
          {version, rest_after_version} = extract_version_from_parts(rest)

          lang = extract_lang_from_parts(rest_after_version)

          {:ok, date, time, version, lang}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_lang_from_parts([]), do: nil
  defp extract_lang_from_parts([<<>> | _]), do: nil
  defp extract_lang_from_parts([lang_code | _]), do: lang_code

  @doc false
  @spec parse_time(term()) :: {:ok, Time.t()} | :error
  def parse_time(time_str) when is_binary(time_str) do
    case String.split(time_str, ":") do
      [h, m] ->
        with {hour, ""} <- Integer.parse(h),
             {minute, ""} <- Integer.parse(m) do
          Time.new(hour, minute, 0)
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse_time(_), do: :error

  @doc false
  @spec extract_version_from_parts([String.t()]) :: {pos_integer() | nil, [String.t()]}
  def extract_version_from_parts([]), do: {nil, []}

  def extract_version_from_parts([first | rest] = parts) do
    case parse_version_segment(first) do
      {:ok, version} -> {version, rest}
      :error -> {nil, parts}
    end
  end

  @doc false
  @spec parse_version_segment(term()) :: {:ok, pos_integer()} | :error
  def parse_version_segment(segment) when is_binary(segment) do
    case Regex.run(~r/^v(\d+)$/, segment) do
      [_, num_str] -> {:ok, String.to_integer(num_str)}
      nil -> :error
    end
  end

  def parse_version_segment(_), do: :error

  # ============================================================================
  # Version Resolution
  # ============================================================================

  @doc false
  @spec resolve_db_version(map(), pos_integer() | nil) ::
          PhoenixKit.Modules.Publishing.PublishingVersion.t() | nil
  def resolve_db_version(db_post, nil), do: DBStorage.get_latest_version(db_post.uuid)

  def resolve_db_version(db_post, version_number),
    do: DBStorage.get_version(db_post.uuid, version_number)
end
