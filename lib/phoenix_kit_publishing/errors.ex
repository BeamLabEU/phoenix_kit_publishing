defmodule PhoenixKit.Modules.Publishing.Errors do
  @moduledoc """
  Central mapping from error atoms (returned by the Publishing module's
  public API) to translated human-readable strings.

  Keeping the API layer locale-agnostic means callers and integration
  consumers can pattern-match on atoms and decide their own presentation.
  Anything user-facing (flash messages, error banners) goes through
  `message/1` which wraps each mapping in `gettext/1` using the
  `PhoenixKitWeb.Gettext` backend.

  ## Supported reason shapes

    * plain atoms — `:not_found`, `:slug_already_exists`, `:title_required`,
      `:invalid_mode`, `:no_published_version`, etc.
    * tagged tuples — `{:ai_translation_failed, reason}`,
      `{:ai_extract_failed, reason}`, `{:ai_request_failed, reason}`,
      `{:source_post_read_failed, reason}`
    * strings — passed through unchanged (legacy / interpolated messages)
    * unknown reasons — rendered as `"Unexpected error: <inspect>"` via
      gettext so nothing ever silently surfaces a raw struct

  ## Log-safe error inspection

  `truncate_for_log/2` is the canonical way to render an opaque error
  reason inside `Logger.*` calls that target external HTTP responses or
  large AI payloads. It coerces the value to a string via `inspect/1`
  and clips it to a fixed character budget so a runaway response body
  never floods the logs.

  ## Example

      iex> PhoenixKit.Modules.Publishing.Errors.message(:not_found)
      "Not found"

      iex> PhoenixKit.Modules.Publishing.Errors.message({:ai_translation_failed, :timeout})
      "AI translation failed: :timeout"
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  @max_log_chars 500

  @typedoc "Atoms returned by Publishing's public API on error."
  @type error_atom ::
          :already_exists
          | :cache_miss
          | :cannot_delete_live
          | :conflicts_with_post_slug
          | :db_update_failed
          | :destination_exists
          | :group_not_found
          | :invalid_content
          | :invalid_format
          | :invalid_mode
          | :invalid_name
          | :invalid_path
          | :invalid_slug
          | :invalid_status
          | :invalid_type
          | :invalid_version
          | :last_language
          | :last_version
          | :no_post
          | :no_published_version
          | :no_uuid
          | :not_found
          | :not_published
          | :post_not_found
          | :post_trashed
          | :reserved_language_code
          | :reserved_route_word
          | :slug_already_exists
          | :slug_taken
          | :title_required
          | :unpublished
          | :version_access_disabled
          | :ai_disabled
          | :ai_no_prompt
          | :ai_endpoint_not_found
          | :ai_endpoint_disabled

  @typedoc "Tagged-tuple errors that carry a downstream reason."
  @type tagged_error ::
          {:ai_translation_failed, term()}
          | {:ai_extract_failed, term()}
          | {:ai_request_failed, term()}
          | {:source_post_read_failed, term()}

  @doc """
  Translates an error reason (atom, tagged tuple, or string) into a
  user-facing string via gettext.
  """
  @spec message(error_atom() | tagged_error() | term()) :: String.t()
  def message(:already_exists), do: gettext("Already exists")
  def message(:cache_miss), do: gettext("Cache miss")
  def message(:cannot_delete_live), do: gettext("Cannot delete the live version")
  def message(:conflicts_with_post_slug), do: gettext("URL slug conflicts with another post")
  def message(:db_update_failed), do: gettext("Database update failed")
  def message(:destination_exists), do: gettext("Destination already exists")
  def message(:group_not_found), do: gettext("Group not found")
  def message(:invalid_content), do: gettext("Invalid content")
  def message(:invalid_format), do: gettext("Invalid format")
  def message(:invalid_mode), do: gettext("Invalid mode")
  def message(:invalid_name), do: gettext("Invalid name")
  def message(:invalid_path), do: gettext("Invalid path")
  def message(:invalid_slug), do: gettext("Invalid slug")
  def message(:invalid_status), do: gettext("Invalid status")
  def message(:invalid_type), do: gettext("Invalid type")
  def message(:invalid_version), do: gettext("Invalid version")
  def message(:last_language), do: gettext("Cannot delete the last language")
  def message(:last_version), do: gettext("Cannot delete the last version")
  def message(:no_post), do: gettext("No post")
  def message(:no_published_version), do: gettext("No published version")
  def message(:no_uuid), do: gettext("No UUID")
  def message(:not_found), do: gettext("Not found")
  def message(:not_published), do: gettext("Not published")
  def message(:post_not_found), do: gettext("Post not found")
  def message(:post_trashed), do: gettext("Post is trashed")

  def message(:reserved_language_code),
    do: gettext("Slug conflicts with a reserved language code")

  def message(:reserved_route_word), do: gettext("Slug conflicts with a reserved route word")
  def message(:slug_already_exists), do: gettext("Slug already exists")
  def message(:slug_taken), do: gettext("Slug taken")
  def message(:title_required), do: gettext("Title is required to publish")
  def message(:unpublished), do: gettext("Unpublished")
  def message(:version_access_disabled), do: gettext("Version access is disabled")

  def message(:ai_disabled), do: gettext("AI module is not enabled")
  def message(:ai_no_prompt), do: gettext("No AI prompt selected")
  def message(:ai_endpoint_not_found), do: gettext("AI endpoint not found")
  def message(:ai_endpoint_disabled), do: gettext("AI endpoint is disabled")

  def message({:ai_translation_failed, reason}) do
    gettext("AI translation failed: %{reason}", reason: truncate_for_log(reason))
  end

  def message({:ai_extract_failed, reason}) do
    gettext("Failed to extract AI response: %{reason}", reason: truncate_for_log(reason))
  end

  def message({:ai_request_failed, reason}) do
    gettext("AI request failed: %{reason}", reason: truncate_for_log(reason))
  end

  def message({:source_post_read_failed, reason}) do
    gettext("Failed to read source post: %{reason}", reason: truncate_for_log(reason))
  end

  # Passthrough for strings so legacy callers returning {:error, "..."}
  # still render something. New code should return atoms / tagged tuples.
  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: truncate_for_log(reason))
  end

  @doc """
  Renders any error reason as a log-safe string clipped to `max` chars.

  Use inside `Logger.*` calls that may include external HTTP response
  bodies, AI completions, or other unbounded payloads — without the
  cap a single failed AI request can flood logs with tens of KB.

  Returns the inspected form unchanged when it fits, or appends an
  ellipsis hint when truncated.
  """
  @spec truncate_for_log(term(), pos_integer()) :: String.t()
  def truncate_for_log(reason, max \\ @max_log_chars) when is_integer(max) and max > 0 do
    string =
      cond do
        is_binary(reason) -> reason
        true -> inspect(reason)
      end

    if byte_size(string) > max do
      String.slice(string, 0, max) <>
        "… (truncated, " <> Integer.to_string(byte_size(string)) <> " bytes)"
    else
      string
    end
  end
end
