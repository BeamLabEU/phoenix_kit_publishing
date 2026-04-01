defmodule PhoenixKit.Modules.Publishing.DBStorage.Mapper do
  @moduledoc """
  Mapper: converts DB records to the map format expected by
  Publishing's web layer (LiveViews, templates, controllers).

  ## Data Sources (V2)

  - **Post** — routing only: slug, mode, post_date, post_time, active_version_uuid
  - **Version** — source of truth: status, published_at, featured_image, tags, seo, description
  - **Content** — per-language: title, body, url_slug (for routing)
  """

  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion

  @doc """
  Converts a full post read (post + version + content + all contents + all versions)
  into the map format expected by the web layer.
  """
  def to_post_map(
        %PublishingPost{} = post,
        %PublishingVersion{} = version,
        %PublishingContent{} = content,
        all_contents,
        all_versions,
        opts \\ []
      ) do
    available_languages = Enum.map(all_contents, & &1.language) |> Enum.sort()

    # Derive status from active_version_uuid
    status = derive_status(post, version)

    # All languages share the version's status (status is version-level, not per-language)
    language_statuses =
      Map.new(all_contents, fn c -> {c.language, status} end)
      |> merge_published_statuses(Keyword.get(opts, :published_language_statuses, %{}))

    available_versions = Enum.map(all_versions, & &1.version_number) |> Enum.sort()

    version_statuses =
      Map.new(all_versions, fn v -> {v.version_number, v.status} end)

    version_dates =
      Map.new(all_versions, fn v ->
        {v.version_number, format_datetime(v.inserted_at)}
      end)

    group_slug = get_group_slug(post)

    %{
      uuid: post.uuid,
      group: group_slug,
      slug: post.slug,
      url_slug: presence(content.url_slug) || post.slug,
      date: post.post_date,
      time: post.post_time,
      mode: safe_mode_atom(post.mode),
      language: content.language,
      available_languages: available_languages,
      language_statuses: language_statuses,
      language_slugs: build_language_slugs(all_contents, post.slug),
      language_previous_slugs: build_language_previous_slugs(all_contents),
      language_titles: Map.new(all_contents, fn c -> {c.language, c.title} end),
      version: version.version_number,
      available_versions: available_versions,
      version_statuses: version_statuses,
      version_dates: version_dates,
      content: content.content,
      content_updated_at: content.updated_at,
      metadata: build_metadata(post, version, content, status)
    }
  end

  @doc """
  Converts a post to a listing-format map (no content body, just metadata).
  Used for listing pages where full content isn't needed.
  """
  def to_listing_map(%PublishingPost{} = post, version, all_contents, all_versions, opts \\ []) do
    available_languages = Enum.map(all_contents, & &1.language) |> Enum.sort()

    group_slug = get_group_slug(post)
    current_version = if version, do: version.version_number, else: 1
    status = if version, do: derive_status(post, version), else: "draft"

    # All languages share the version's status (status is version-level, not per-language)
    language_statuses =
      Map.new(all_contents, fn c -> {c.language, status} end)
      |> merge_published_statuses(Keyword.get(opts, :published_language_statuses, %{}))

    available_versions = Enum.map(all_versions, & &1.version_number) |> Enum.sort()

    version_statuses =
      Map.new(all_versions, fn v -> {v.version_number, v.status} end)

    version_dates =
      Map.new(all_versions, fn v ->
        {v.version_number, format_datetime(v.inserted_at)}
      end)

    # Use site default language for primary content selection
    primary_content =
      Enum.find(all_contents, fn c -> c.language == LanguageHelpers.get_primary_language() end) ||
        List.first(all_contents)

    %{
      uuid: post.uuid,
      group: group_slug,
      slug: post.slug,
      url_slug: presence(primary_content && primary_content.url_slug) || post.slug,
      date: post.post_date,
      time: post.post_time,
      mode: safe_mode_atom(post.mode),
      language: LanguageHelpers.get_primary_language(),
      available_languages: available_languages,
      language_statuses: language_statuses,
      language_slugs: build_language_slugs(all_contents, post.slug),
      language_previous_slugs: build_language_previous_slugs(all_contents),
      version: current_version,
      available_versions: available_versions,
      version_statuses: version_statuses,
      version_dates: version_dates,
      content: primary_content && extract_excerpt(primary_content),
      metadata: build_listing_metadata(post, version, primary_content, status),
      # Per-language data for listing pages (so language switching shows correct titles)
      language_titles: Map.new(all_contents, fn c -> {c.language, c.title} end),
      language_excerpts: Map.new(all_contents, fn c -> {c.language, extract_excerpt(c)} end)
    }
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp get_group_slug(%PublishingPost{group: %{slug: slug}}), do: slug
  defp get_group_slug(%PublishingPost{} = _post), do: nil

  # Derive status from active_version_uuid: if the post's active version matches
  # this version, the post is "published". Otherwise use the version's own status.
  defp derive_status(%PublishingPost{} = post, %PublishingVersion{uuid: version_uuid} = version) do
    active_uuid = Map.get(post, :active_version_uuid)

    if not is_nil(active_uuid) and active_uuid == version_uuid do
      "published"
    else
      version.status
    end
  end

  defp build_metadata(post, version, content, status) do
    %{
      title: content.title,
      description: PublishingVersion.get_description(version),
      status: status,
      slug: post.slug,
      version: version.version_number,
      allow_version_access: PublishingVersion.get_allow_version_access(version),
      url_slug: content.url_slug,
      previous_url_slugs: PublishingContent.get_previous_url_slugs(content),
      published_at: format_datetime(version.published_at),
      featured_image_uuid: PublishingVersion.get_featured_image_uuid(version)
    }
  end

  defp build_listing_metadata(_post, nil, _content, status) do
    %{
      title: nil,
      description: nil,
      status: status,
      slug: nil,
      published_at: nil,
      featured_image_uuid: nil
    }
  end

  defp build_listing_metadata(post, version, nil, status) do
    %{
      title: nil,
      description: PublishingVersion.get_description(version),
      status: status,
      slug: post.slug,
      published_at: format_datetime(version.published_at),
      featured_image_uuid: PublishingVersion.get_featured_image_uuid(version)
    }
  end

  defp build_listing_metadata(post, version, content, status) do
    %{
      title: content.title,
      description: PublishingVersion.get_description(version),
      status: status,
      slug: post.slug,
      published_at: format_datetime(version.published_at),
      featured_image_uuid: PublishingVersion.get_featured_image_uuid(version)
    }
  end

  defp build_language_slugs(all_contents, default_slug) do
    Map.new(all_contents, fn c ->
      {c.language, presence(c.url_slug) || default_slug}
    end)
  end

  defp build_language_previous_slugs(all_contents) do
    Map.new(all_contents, fn c ->
      {c.language, PublishingContent.get_previous_url_slugs(c)}
    end)
  end

  defp extract_excerpt(%PublishingContent{} = content) do
    case PublishingContent.get_excerpt(content) do
      excerpt when is_binary(excerpt) and excerpt != "" ->
        excerpt

      _ ->
        case PublishingContent.get_description(content) do
          desc when is_binary(desc) and desc != "" ->
            desc

          _ ->
            extract_first_paragraph(content.content)
        end
    end
  end

  defp extract_first_paragraph(nil), do: nil

  defp extract_first_paragraph(content) when is_binary(content) do
    content
    |> String.split(~r/\n\n+/)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> List.first()
    |> case do
      nil -> ""
      text -> text |> String.trim() |> String.slice(0, 300)
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: to_string(other)

  defp merge_published_statuses(latest_statuses, published_statuses)
       when map_size(published_statuses) == 0,
       do: latest_statuses

  defp merge_published_statuses(latest_statuses, published_statuses) do
    Map.merge(latest_statuses, published_statuses, fn _lang, latest, published ->
      if published == "published", do: "published", else: latest
    end)
  end

  defp safe_mode_atom("timestamp"), do: :timestamp
  defp safe_mode_atom("slug"), do: :slug
  defp safe_mode_atom(_), do: :timestamp

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
