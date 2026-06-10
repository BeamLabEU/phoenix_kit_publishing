defmodule PhoenixKit.Modules.Publishing.Web.Controller.SlugResolution do
  @moduledoc """
  URL slug resolution for the publishing controller.

  Handles resolving URL slugs to internal slugs, including:
  - Per-language custom URL slugs
  - Previous URL slugs for 301 redirects
  - DB-based slug lookups
  """

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML

  # ============================================================================
  # URL Slug Resolution
  # ============================================================================

  @doc """
  Resolves URL slug to internal slug using cache/DB.

  Returns:
  - `{:redirect, url}` for 301 redirect to new URL
  - `{:ok, identifier}` for resolved internal slug
  - `:passthrough` for direct use
  """
  def resolve_url_slug(group_slug, {:slug, url_slug}, language) do
    # Resolve base language codes (de, en) to stored dialect codes (de-DE, en-US)
    # before DB queries, since content rows store full BCP-47 dialect codes
    db_language = resolve_language_for_db(language)

    case Publishing.find_by_url_slug(group_slug, db_language, url_slug) do
      {:ok, cached_post} ->
        internal_slug = cached_post.slug

        if internal_slug == url_slug do
          # URL slug matches internal slug - no resolution needed
          :passthrough
        else
          # URL slug differs from internal slug - use resolved identifier
          {:ok, {:slug, internal_slug}}
        end

      {:error, :not_found} ->
        # Not found in current slugs - check previous slugs for 301 redirect
        case Publishing.find_by_previous_url_slug(group_slug, db_language, url_slug) do
          {:ok, cached_post} ->
            # Found in previous slugs - redirect to current URL. The cache path
            # carries `:language_slugs`; the DB path (db_content_to_post_map/1)
            # does not, so fall back to the row's own `:url_slug` (the canonical
            # custom slug for this language, which the DB map DOES carry) before
            # the internal `:slug`. Without this, a post with a custom url_slug
            # 301s to /group/<internal-slug> instead of the canonical URL.
            current_url_slug =
              Map.get(
                cached_post[:language_slugs] || %{},
                db_language,
                cached_post[:url_slug] || cached_post.slug
              )

            redirect_url =
              build_post_redirect_url(group_slug, cached_post, language, current_url_slug)

            {:redirect, redirect_url}

          {:error, _} ->
            :passthrough
        end
    end
  end

  # Non-slug modes pass through directly
  def resolve_url_slug(_group_slug, _identifier, _language), do: :passthrough

  @doc """
  Resolves a URL slug to the internal post slug.
  Used by versioned URL handler and other places that need the internal slug.
  """
  def resolve_url_slug_to_internal(group_slug, url_slug, language) do
    db_language = resolve_language_for_db(language)

    case Publishing.find_by_url_slug(group_slug, db_language, url_slug) do
      {:ok, cached_post} ->
        cached_post.slug || cached_post[:slug]

      {:error, _} ->
        # Not found in cache/DB - use as-is
        url_slug
    end
  end

  # ============================================================================
  # Redirect URL Building
  # ============================================================================

  @doc """
  Builds redirect URL for 301 redirects from cached post data.
  """
  def build_post_redirect_url(group_slug, cached_post, language, url_slug) do
    # Build post struct with minimal fields needed for URL generation.
    # `cached_post` may be cache-shaped (carries :mode/:date/:time/:language_slugs)
    # or DB-shaped (db_content_to_post_map/1 — only :slug/:url_slug/:language/:metadata),
    # so read the cache-only fields with bracket access + sane fallbacks. This path
    # is only reached for slug-mode resolution, so "slug" is the correct default mode
    # and a nil date/time is never consulted by build_post_url/4 in that branch.
    post = %{
      slug: cached_post.slug,
      url_slug: url_slug,
      mode: Map.get(cached_post, :mode, "slug"),
      date: cached_post[:date],
      time: cached_post[:time],
      language_slugs: cached_post[:language_slugs] || %{}
    }

    PublishingHTML.build_post_url(group_slug, post, language)
  end

  # ============================================================================
  # Language Resolution
  # ============================================================================

  # Resolves a URL language code to the stored dialect code for DB queries.
  # Resolve language for DB lookup. If the language is an enabled code, use it directly.
  # Only resolve base codes to dialects when the base itself isn't enabled.
  defp resolve_language_for_db(language) do
    enabled = Language.get_enabled_languages()

    cond do
      language in enabled ->
        language

      Language.base_code?(language) ->
        Language.find_dialect_for_base(language, enabled) ||
          DialectMapper.base_to_dialect(language)

      true ->
        language
    end
  end
end
