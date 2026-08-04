defmodule PhoenixKit.Modules.Publishing.DBStorage.Mapper do
  @moduledoc """
  Mapper: converts DB records to the map format expected by
  Publishing's web layer (LiveViews, templates, controllers).

  ## Data Sources (V2)

  - **Post** — routing only: slug, mode, post_date, post_time, active_version_uuid
  - **Version** — source of truth: status, published_at, featured_image, tags, seo, description
  - **Content** — per-language: title, body, url_slug (for routing)
  """

  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Utils.Values

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

    # Derive status from active_version_uuid. `:effective_status` (when the
    # caller mapped a NEWER revision of a post whose active version is live)
    # overrides only the post-level metadata.status below — never the
    # per-language/per-version maps, which stay version-accurate.
    status = derive_status(post, version)

    {effective_status, effective_published_at} =
      effective_overrides(opts, status, version.published_at)

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
      url_slug: Values.blank_to_nil(content.url_slug) || post.slug,
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
      metadata: build_metadata(post, version, content, effective_status, effective_published_at)
    }
    |> maybe_override_title(opts)
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

    {effective_status, effective_published_at} =
      effective_overrides(opts, status, version && version.published_at)

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
      url_slug: Values.blank_to_nil(primary_content && primary_content.url_slug) || post.slug,
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
      metadata:
        build_listing_metadata(
          post,
          version,
          primary_content,
          effective_status,
          effective_published_at
        ),
      # Per-language data for listing pages (so language switching shows correct titles)
      language_titles: Map.new(all_contents, fn c -> {c.language, c.title} end),
      language_excerpts: Map.new(all_contents, fn c -> {c.language, extract_excerpt(c)} end)
    }
    |> maybe_override_title(opts)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # The caller-supplied LIVE overrides (admin listing: a live post mapped by
  # its newest DRAFT revision still reports the live status AND the live
  # publish date at post level — without the date half, "Unsaved draft"
  # rendered beside a Published badge). Never touches the per-language /
  # per-version maps, which stay version-accurate.
  defp effective_overrides(opts, status, published_at) do
    {Keyword.get(opts, :effective_status) || status,
     Keyword.get(opts, :effective_published_at) || published_at}
  end

  # The admin listing's live-title override (see the caller in DBStorage):
  # applied AFTER the map is built so the per-language/per-version maps stay
  # version-accurate — only the card-level metadata.title follows the live
  # version. A no-op when the opt is absent (every non-admin path).
  defp maybe_override_title(map, opts) do
    map =
      case Keyword.get(opts, :effective_title) do
        title when is_binary(title) and title != "" ->
          put_in(map, [:metadata, :title], title)

        _ ->
          map
      end

    # Present only for published posts: the version number the admin card's
    # edit links pin (published → open the live version; drafts → newest).
    case Keyword.get(opts, :effective_live_version) do
      n when is_integer(n) -> Map.put(map, :live_version, n)
      _ -> map
    end
  end

  defp get_group_slug(%PublishingPost{group: %{slug: slug}}), do: slug
  defp get_group_slug(%PublishingPost{} = _post), do: nil

  # Derive status from active_version_uuid: if the post's active version matches
  # this version, the post is "published". Otherwise use the version's own status.
  defp derive_status(%PublishingPost{} = post, %PublishingVersion{uuid: version_uuid} = version) do
    active_uuid = Map.get(post, :active_version_uuid)

    if not is_nil(active_uuid) and active_uuid == version_uuid do
      Constants.status_published()
    else
      version.status
    end
  end

  defp build_metadata(post, version, content, status, published_at) do
    %{
      title: content.title,
      # Version wins (a stored "" is an explicit cleared value); only an
      # ABSENT version key falls back to the row's V1-legacy per-language
      # value — see legacy_content_fallback/2.
      description:
        PublishingVersion.get_description(version) ||
          legacy_content_fallback(content, "description"),
      status: status,
      slug: post.slug,
      version: version.version_number,
      allow_version_access: PublishingVersion.get_allow_version_access(version),
      url_slug: content.url_slug,
      previous_url_slugs: PublishingContent.get_previous_url_slugs(content),
      published_at: format_datetime(published_at),
      featured_image_uuid:
        PublishingVersion.get_featured_image_uuid(version) ||
          legacy_content_fallback(content, "featured_image_uuid"),
      featured: PublishingVersion.get_featured(version),
      tags: PublishingVersion.get_tags(version),
      category_uuids: PublishingVersion.get_category_uuids(version),
      audio_uuid: PublishingVersion.get_audio_uuid(version),
      og: PublishingContent.get_og(content)
    }
  end

  defp build_listing_metadata(_post, nil, _content, status, _published_at) do
    %{
      title: nil,
      description: nil,
      status: status,
      slug: nil,
      # No version → no version-history access.
      allow_version_access: false,
      published_at: nil,
      featured_image_uuid: nil,
      featured: false,
      category_uuids: []
    }
  end

  defp build_listing_metadata(post, version, nil, status, published_at) do
    %{
      title: nil,
      description: PublishingVersion.get_description(version),
      status: status,
      slug: post.slug,
      # Must mirror build_metadata/5 — the public version dropdown reads this
      # from the cached listing map; omitting it hid the dropdown on a warm cache.
      allow_version_access: PublishingVersion.get_allow_version_access(version),
      published_at: format_datetime(published_at),
      featured_image_uuid: PublishingVersion.get_featured_image_uuid(version),
      featured: PublishingVersion.get_featured(version),
      tags: PublishingVersion.get_tags(version),
      category_uuids: PublishingVersion.get_category_uuids(version),
      audio_uuid: PublishingVersion.get_audio_uuid(version)
    }
  end

  defp build_listing_metadata(post, version, content, status, published_at) do
    %{
      title: content.title,
      description:
        PublishingVersion.get_description(version) ||
          legacy_content_fallback(content, "description"),
      status: status,
      slug: post.slug,
      # Must mirror build_metadata/5 — see the clause above.
      allow_version_access: PublishingVersion.get_allow_version_access(version),
      published_at: format_datetime(published_at),
      featured_image_uuid:
        PublishingVersion.get_featured_image_uuid(version) ||
          legacy_content_fallback(content, "featured_image_uuid"),
      featured: PublishingVersion.get_featured(version),
      tags: PublishingVersion.get_tags(version),
      category_uuids: PublishingVersion.get_category_uuids(version),
      audio_uuid: PublishingVersion.get_audio_uuid(version)
    }
  end

  defp build_language_slugs(all_contents, default_slug) do
    Map.new(all_contents, fn c ->
      {c.language, Values.blank_to_nil(c.url_slug) || default_slug}
    end)
  end

  defp build_language_previous_slugs(all_contents) do
    Map.new(all_contents, fn c ->
      {c.language, PublishingContent.get_previous_url_slugs(c)}
    end)
  end

  # V1 stored description/featured_image_uuid per-language on content.data;
  # V2's home is version.data, migrated by promotion-on-first-edit
  # (Posts.collect_legacy_content_promotions/2). A never-edited V1 post lost
  # its featured image and explicit description on every public surface
  # until someone happened to edit it — this read-side fallback restores
  # them, per-language-faithfully (the rendered language's own value), and
  # goes dead for a row the moment promotion runs (the version key then
  # exists, and a stored "" is an explicit cleared value that wins). Same
  # pattern extract_excerpt/1 below has always used for card excerpts.
  defp legacy_content_fallback(%PublishingContent{data: data}, key) when is_map(data) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp legacy_content_fallback(_content, _key), do: nil

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
    # Components first: a body opening with <Gallery>/<Showcase> would
    # otherwise become the "first paragraph", and the 300-char slice below
    # could cut MID-TAG — the broken tag then survives downstream
    # tag-stripping as escaped junk in the card preview.
    |> Shared.strip_components()
    |> String.split(~r/\n\n+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> List.first()
    |> case do
      nil -> ""
      text -> String.slice(text, 0, 300)
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
      if Constants.published?(published), do: Constants.status_published(), else: latest
    end)
  end

  defp safe_mode_atom("timestamp"), do: :timestamp
  defp safe_mode_atom("slug"), do: :slug
  defp safe_mode_atom(_), do: :timestamp
end
