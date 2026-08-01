defmodule PhoenixKit.Modules.Publishing.Web.Controller.Fallback do
  @moduledoc """
  404 fallback handling for the publishing controller.

  ## Policy

  Smart fallback only fires when the requested **group exists**. The signal
  is "you're inside a real publishing URL but I can't find this specific
  post / language / time" — in that case we redirect to the nearest valid
  parent (other-language version, other-time-on-date, group listing) with
  a flash explaining the substitution.

  When the **group itself doesn't exist**, the request gets a clean 404.
  This is critical when `url_prefix` is `"/"`: publishing's catch-all
  routes then sit at the host's absolute root, so any path the host app
  doesn't claim earlier flows into this controller. Falling back to "the
  first group in the DB" (the previous behaviour) would hijack random
  host-app URLs and redirect them to an unrelated page.

  ## Fallback chain (group-existing case only)

  - `:not_found` (post trashed/deleted) → group listing
  - `:post_not_found | :unpublished | :version_access_disabled` on a slug
    path → other languages → group listing
  - same on a timestamp path → other languages → other times on the date →
    group listing
  - any other reason with a known group → group listing
  """

  use Gettext, backend: PhoenixKitPublishing.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML

  # ============================================================================
  # Main Entry Point
  # ============================================================================

  @doc """
  Handles 404 not found responses with smart fallback.
  """
  def handle_not_found(conn, reason) do
    # Try to fall back to nearest valid parent in the breadcrumb chain
    case attempt_breadcrumb_fallback(conn, reason) do
      {:ok, redirect_path} ->
        {:redirect_with_flash, redirect_path,
         gettext("The page you requested was not found. Showing closest match.")}

      :no_fallback ->
        {:render_404}
    end
  end

  # ============================================================================
  # Breadcrumb Fallback Logic
  # ============================================================================

  defp attempt_breadcrumb_fallback(conn, reason) do
    language = conn.assigns[:current_language] || "en"
    group_slug = conn.params["group"]
    path = conn.params["path"] || []

    # Build full path including group slug for proper fallback handling
    # Route params are: %{"group" => "date", "path" => ["2025-12-09", "15:02"]}
    # We need: ["date", "2025-12-09", "15:02"] for pattern matching
    full_path = if group_slug, do: [group_slug | path], else: path

    handle_fallback_case(reason, full_path, language)
  end

  # ============================================================================
  # Fallback Case Handlers
  # ============================================================================

  # Post not found (trashed/deleted) — go straight to group listing, don't try other posts
  defp handle_fallback_case(:not_found, [group_slug | _], language) do
    if group_exists?(group_slug) do
      {:ok, PublishingHTML.group_listing_path(language, group_slug)}
    else
      :no_fallback
    end
  end

  # Slug mode posts (2-element path) - try other languages, then group listing
  defp handle_fallback_case(reason, [group_slug, post_slug], language)
       when reason in [:post_not_found, :unpublished, :version_access_disabled] do
    fallback_to_default_language(group_slug, post_slug, language)
  end

  # Timestamp mode posts (3-element path) - try other languages, then group listing
  defp handle_fallback_case(reason, [group_slug, date, time], language)
       when reason in [:post_not_found, :unpublished, :version_access_disabled] do
    fallback_timestamp_to_other_language(group_slug, date, time, language)
  end

  # Group itself doesn't exist — render 404. Don't redirect to "the first
  # group" because the request had no signal of publishing intent (the bug
  # manifests acutely when url_prefix == "/" and the catch-all sits at
  # the host's root, where /about, /contact, etc. would otherwise be hijacked).
  defp handle_fallback_case(:group_not_found, _path, _language), do: :no_fallback

  # Module/public access disabled — render 404, never redirect. The group still
  # exists in the DB, so the generic group-listing fallback below would 302 to the
  # same disabled URL forever. Must precede the catch-all.
  defp handle_fallback_case(:module_disabled, _path, _language), do: :no_fallback

  # Any post-level error with a 2+ segment path — fall back to group listing
  # Catches errors like :invalid_version, unknown reasons from read_post, etc.
  defp handle_fallback_case(_reason, [group_slug | _rest], language) do
    if group_exists?(group_slug) do
      {:ok, PublishingHTML.group_listing_path(language, group_slug)}
    else
      :no_fallback
    end
  end

  defp handle_fallback_case(_reason, _path, _language), do: :no_fallback

  # ============================================================================
  # Slug Mode Fallback
  # ============================================================================

  defp fallback_to_default_language(group_slug, post_slug, requested_language) do
    if group_exists?(group_slug) do
      find_any_available_language_version(group_slug, post_slug, requested_language)
    else
      :no_fallback
    end
  end

  @doc """
  Tries to find any available published language version of the post.

  Priority:
  1. Check for published versions in the SAME language first (across all versions)
  2. Then try other languages
  3. Falls back to group listing if no published versions exist

  Note: fetch_post now handles finding the latest published version automatically,
  so we can just use base URLs here (no version-specific URLs needed)
  """
  def find_any_available_language_version(group_slug, post_slug, requested_language) do
    default_lang = Language.get_default_language()

    # Find the post in the group to get available languages
    case find_post_by_slug(group_slug, post_slug) do
      {:ok, post} ->
        # The initial fetch failed, so we know no published version exists for the requested_language.
        # Proceed directly to trying other available languages.
        try_other_languages(group_slug, post_slug, post, requested_language, default_lang)

      :not_found ->
        # Post doesn't exist at all - fall back to group listing
        {:ok, PublishingHTML.group_listing_path(default_lang, group_slug)}
    end
  end

  # Finds the latest published version for a specific language
  defp find_published_version_for_language(group_slug, post_slug, language) do
    versions = Publishing.list_versions(group_slug, post_slug)

    published_version =
      versions
      |> Enum.sort(:desc)
      |> Enum.find(fn version ->
        Constants.published?(
          Publishing.get_version_status(group_slug, post_slug, version, language)
        )
      end)

    case published_version do
      nil -> :not_found
      version -> {:ok, version}
    end
  end

  # Tries other languages when requested language has no published versions
  # Cap on how many languages to try in fallback chain to prevent excessive DB queries
  @max_fallback_languages 5

  defp try_other_languages(group_slug, post_slug, post, requested_language, default_lang) do
    available = post.available_languages

    # Build priority list: default first, then others (excluding already-tried language)
    languages_to_try =
      ([default_lang | available] -- [requested_language])
      |> Enum.uniq()
      |> Enum.take(@max_fallback_languages)

    find_first_published_version(group_slug, post_slug, post, languages_to_try, default_lang)
  end

  # Finds a post by its slug using a direct DB query
  defp find_post_by_slug(group_slug, post_slug) do
    case Publishing.read_post(group_slug, post_slug) do
      {:ok, post} -> {:ok, post}
      {:error, _} -> :not_found
    end
  end

  # Tries each language in order until finding a published version
  # Uses find_published_version_for_language to check across all versions
  # fetch_post will automatically find the right version when the URL is visited
  defp find_first_published_version(group_slug, post_slug, post, languages, fallback_lang) do
    result =
      Enum.find_value(languages, fn lang ->
        # Check if any published version exists for this language
        case find_published_version_for_language(group_slug, post_slug, lang) do
          {:ok, _version} ->
            # Published version exists - use base URL
            # fetch_post will find the right version
            {:ok, PublishingHTML.build_post_url(group_slug, post, lang)}

          :not_found ->
            nil
        end
      end)

    # If no published version found, fall back to group listing
    result || {:ok, PublishingHTML.group_listing_path(fallback_lang, group_slug)}
  end

  # ============================================================================
  # Timestamp Mode Fallback
  # ============================================================================

  @doc """
  Fallback for timestamp mode posts - comprehensive fallback chain:
  1. Try other languages for the exact date/time
  2. If time doesn't exist, try other times on the same date
  3. If date has no posts, fall back to group listing
  """
  def fallback_timestamp_to_other_language(group_slug, date, time, requested_language) do
    default_lang = Language.get_default_language()

    if group_exists?(group_slug) do
      # Step 1: Try other languages for this exact time
      # Use DB to get available languages for this timestamp post
      available = get_available_languages_for_timestamp(group_slug, date, time)

      try_other_languages_or_times(
        group_slug,
        date,
        time,
        available,
        requested_language,
        default_lang
      )
    else
      :no_fallback
    end
  end

  defp try_other_languages_or_times(group_slug, date, time, [], _requested_lang, default_lang) do
    fallback_to_other_time_on_date(group_slug, date, time, default_lang)
  end

  defp try_other_languages_or_times(
         group_slug,
         date,
         time,
         available,
         requested_language,
         default_lang
       ) do
    languages_to_try =
      ([default_lang | available] -- [requested_language])
      |> Enum.uniq()

    case find_first_published_timestamp_version(group_slug, date, time, languages_to_try) do
      {:ok, url} -> {:ok, url}
      :not_found -> fallback_to_other_time_on_date(group_slug, date, time, default_lang)
    end
  end

  # Fallback to another time on the same date
  defp fallback_to_other_time_on_date(group_slug, date, exclude_time, default_lang) do
    case Publishing.list_times_on_date(group_slug, date) do
      [] ->
        # No posts on this date at all - try other dates or fall back to group listing
        fallback_to_other_date(group_slug, default_lang)

      times ->
        # Filter out the time we already tried
        other_times = times -- [exclude_time]

        case find_first_published_time(group_slug, date, other_times, default_lang) do
          {:ok, url} ->
            {:ok, url}

          :not_found ->
            # No published posts on this date - try other dates
            fallback_to_other_date(group_slug, default_lang)
        end
    end
  end

  # No posts found on this date - fall back to group listing
  # The group listing will show all available posts
  defp fallback_to_other_date(group_slug, default_lang) do
    {:ok, PublishingHTML.group_listing_path(default_lang, group_slug)}
  end

  # Find the first published post at any of the given times
  defp find_first_published_time(group_slug, date, times, preferred_lang) do
    Enum.find_value(times, fn time ->
      try_languages_for_time(group_slug, date, time, preferred_lang)
    end) || :not_found
  end

  defp try_languages_for_time(group_slug, date, time, preferred_lang) do
    available = get_available_languages_for_timestamp(group_slug, date, time)

    if available != [] do
      languages = [preferred_lang | available] |> Enum.uniq()

      case find_first_published_timestamp_version(group_slug, date, time, languages) do
        {:ok, url} -> {:ok, url}
        :not_found -> nil
      end
    end
  end

  @doc """
  Tries each language for timestamp mode until finding a published version.
  """
  def find_first_published_timestamp_version(group_slug, date, time, languages) do
    identifier = "#{date}/#{time}"

    Enum.find_value(languages, fn lang ->
      published_timestamp_url(group_slug, identifier, date, time, lang)
    end) || :not_found
  end

  # A future-dated post is 404'd as :unpublished by the renderer, so it must NOT
  # be a fallback target either — otherwise two languages of the same future post
  # 302-ping-pong between each other forever.
  defp published_timestamp_url(group_slug, identifier, date, time, lang) do
    with {:ok, post} <- Publishing.read_post(group_slug, identifier, lang),
         true <- Constants.published?(post.metadata.status) and not future_timestamp_post?(post) do
      {:ok, build_timestamp_url(group_slug, date, time, lang)}
    else
      _ -> nil
    end
  end

  defp future_timestamp_post?(post), do: Constants.scheduled_ahead?(post)

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp group_exists?(group_slug) do
    case Listing.fetch_group(group_slug) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp build_timestamp_url(group_slug, date, time, language) do
    PublishingHTML.build_public_path_with_time(language, group_slug, date, time)
  end

  # Gets available languages for a timestamp post using a direct DB query
  defp get_available_languages_for_timestamp(group_slug, date, time) do
    parsed_date = parse_date(date)
    parsed_time = parse_time(time)

    if parsed_date && parsed_time do
      case Publishing.read_post_by_datetime(group_slug, parsed_date, parsed_time) do
        {:ok, post} -> post.available_languages
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp parse_date(%Date{} = d), do: d

  defp parse_date(d) when is_binary(d) do
    case Date.from_iso8601(d) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp parse_time(%Time{} = t), do: t

  defp parse_time(t) when is_binary(t) do
    with [h, m | _] <- String.split(t, ":"),
         {hour, ""} <- Integer.parse(h),
         {minute, ""} <- Integer.parse(m),
         {:ok, time} <- Time.new(hour, minute, 0) do
      time
    else
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
