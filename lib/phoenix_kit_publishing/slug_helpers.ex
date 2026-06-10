defmodule PhoenixKit.Modules.Publishing.SlugHelpers do
  @moduledoc """
  Slug validation and generation for the Publishing module.

  Handles slug format validation, uniqueness checking (DB-only),
  URL slug validation for per-language slugs, and slug generation.
  """

  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Slug

  require Logger

  @slug_style_key "publishing_slug_style"
  @default_slug_style "transliterate"

  # SEO-preferred slug length. The actual cap is `effective_max_slug_length/0`
  # — the SMALLER of this and the real save limit (`Constants.max_slug_length`).
  # `slugify/2` caps its output to that, so the slugified BASE of any automatic
  # path (title -> slug, AI translation, Cyrillic transliteration which EXPANDS
  # text — щ -> shch) is always <= the save limit and never errors on save.
  # `generate_unique_slug/4` may append a short "-N" uniqueness suffix on top of
  # the capped base; with the 200-vs-500 headroom that stays far under the
  # column limit. 200 is generous for SEO and well under the 500-char columns.
  @seo_slug_length 200

  # ASCII slug shape — produced by the :transliterate and :ascii styles.
  @ascii_slug_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  # Unicode slug shape — produced by the :unicode style (letters/numbers from
  # any script, separated by hyphens).
  @unicode_slug_pattern ~r/^[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*$/u

  # Reserved route words that cannot be used as URL slugs
  @reserved_route_words ~w(admin api assets phoenix_kit auth login logout register settings)

  # Lowercase Cyrillic -> Latin transliteration table (Russian). Applied before
  # the ASCII strip so non-Latin titles produce real slugs instead of
  # collapsing to "untitled".
  @cyrillic_map %{
    "а" => "a",
    "б" => "b",
    "в" => "v",
    "г" => "g",
    "д" => "d",
    "е" => "e",
    "ё" => "e",
    "ж" => "zh",
    "з" => "z",
    "и" => "i",
    "й" => "i",
    "к" => "k",
    "л" => "l",
    "м" => "m",
    "н" => "n",
    "о" => "o",
    "п" => "p",
    "р" => "r",
    "с" => "s",
    "т" => "t",
    "у" => "u",
    "ф" => "f",
    "х" => "h",
    "ц" => "ts",
    "ч" => "ch",
    "ш" => "sh",
    "щ" => "shch",
    "ъ" => "",
    "ы" => "y",
    "ь" => "",
    "э" => "e",
    "ю" => "yu",
    "я" => "ya"
  }

  @doc """
  Returns the configured slug style as an atom.

  `:transliterate` (default) | `:unicode` | `:ascii`. Controlled by the
  `publishing_slug_style` setting; falls back to `:transliterate` on any error.
  """
  @spec slug_style() :: :transliterate | :unicode | :ascii
  def slug_style do
    case Settings.get_setting(@slug_style_key, @default_slug_style) do
      "unicode" -> :unicode
      "ascii" -> :ascii
      _ -> :transliterate
    end
  rescue
    _ -> :transliterate
  end

  @doc """
  Converts text into a slug honoring the configured (or given) style.

    * `:transliterate` — map Cyrillic + strip Latin diacritics to ASCII, then
      `[a-z0-9-]`. Default; keeps URLs ASCII and validation simple.
    * `:unicode` — keep letters/numbers from any script (e.g. `привет-мир`).
    * `:ascii` — legacy behavior: strip everything non-ASCII.

  Pass `style: :unicode` to override the setting (used by tests).
  """
  @spec slugify(String.t() | nil, keyword()) :: String.t()
  def slugify(text, opts \\ [])
  def slugify(nil, _opts), do: ""

  def slugify(text, opts) when is_binary(text) do
    slug = do_slugify(text, Keyword.get(opts, :style) || slug_style())
    if Keyword.get(opts, :cap, true), do: cap_length(slug), else: slug
  end

  def slugify(_text, _opts), do: ""

  @doc """
  Returns true when slugifying `text` would be truncated to fit the cap — i.e.
  the full title did NOT fully fit into the generated slug.

  Lets interactive callers warn the user that not all of the title became the
  slug (automatic generation never errors — it just shortens).
  """
  @spec slug_truncated?(String.t() | nil, keyword()) :: boolean()
  def slug_truncated?(text, opts \\ [])
  def slug_truncated?(nil, _opts), do: false

  def slug_truncated?(text, opts) when is_binary(text) do
    uncapped = slugify(text, Keyword.put(opts, :cap, false))
    String.length(uncapped) > effective_max_slug_length()
  end

  def slug_truncated?(_text, _opts), do: false

  # The effective slug cap: never larger than the save limit, so a generated
  # slug can't fail `validate_length(:slug/:url_slug, max: max_slug_length)`.
  defp effective_max_slug_length, do: min(@seo_slug_length, Constants.max_slug_length())

  # Truncate to the effective cap at a hyphen boundary so we never cut a word in
  # half and never overflow what save accepts.
  defp cap_length(slug) do
    max = effective_max_slug_length()

    if String.length(slug) <= max do
      slug
    else
      slug
      |> String.slice(0, max)
      |> String.replace(~r/-[^-]*$/, "")
      |> String.trim("-")
    end
  end

  defp do_slugify(text, :unicode) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp do_slugify(text, :ascii) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  # :transliterate (default)
  defp do_slugify(text, _style) do
    text
    |> String.downcase()
    |> transliterate()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp transliterate(text) do
    text
    |> String.graphemes()
    |> Enum.map_join("", fn ch -> Map.get(@cyrillic_map, ch, ch) end)
  end

  # Slug-shape regex for the active style.
  defp slug_pattern do
    case slug_style() do
      :unicode -> @unicode_slug_pattern
      _ -> @ascii_slug_pattern
    end
  end

  @doc """
  Returns true when the slug matches the active style's shape pattern.

  Style-aware companion for group-slug validation in the facade.
  """
  @spec matches_shape?(any()) :: boolean()
  def matches_shape?(slug) when is_binary(slug), do: Regex.match?(slug_pattern(), slug)
  def matches_shape?(_), do: false

  # HTML5 `pattern` attribute sources — mirror the shape regexes above but as
  # plain strings (the attribute is compiled Unicode-aware by the browser, so
  # `\p{L}`/`\p{N}` resolve under :unicode).
  @ascii_html_pattern "[a-z0-9]+(-[a-z0-9]+)*"
  @unicode_html_pattern "[\\p{L}\\p{N}]+(-[\\p{L}\\p{N}]+)*"

  @doc """
  Returns the HTML5 `pattern` attribute source matching the active slug style.

  Keeps the editor's `url_slug` input client-side validation in sync with the
  server-side `validate_url_slug/4` — ASCII for `:transliterate`/`:ascii`,
  Unicode letters/numbers for `:unicode`. Without this the input would reject a
  valid Unicode slug the server accepts.
  """
  @spec html_input_pattern() :: String.t()
  def html_input_pattern do
    case slug_style() do
      :unicode -> @unicode_html_pattern
      _ -> @ascii_html_pattern
    end
  end

  @doc """
  Validates whether the given string is a valid slug format and not a reserved language code.
  """
  @spec validate_slug(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_format | :reserved_language_code}
  def validate_slug(slug) when is_binary(slug) do
    cond do
      not Regex.match?(slug_pattern(), slug) ->
        {:error, :invalid_format}

      LanguageHelpers.reserved_language_code?(slug) ->
        {:error, :reserved_language_code}

      true ->
        {:ok, slug}
    end
  end

  @doc """
  Validates whether the given string is a slug and not a reserved language code.
  """
  @spec valid_slug?(String.t()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    case validate_slug(slug) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Validates a per-language URL slug for uniqueness within a group+language combination.
  """
  @spec validate_url_slug(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def validate_url_slug(group_slug, url_slug, language, exclude_post_slug \\ nil) do
    cond do
      not Regex.match?(slug_pattern(), url_slug) ->
        {:error, :invalid_format}

      LanguageHelpers.reserved_language_code?(url_slug) ->
        {:error, :reserved_language_code}

      url_slug in @reserved_route_words ->
        {:error, :reserved_route_word}

      conflicts_with_post_slug?(group_slug, url_slug, exclude_post_slug) ->
        {:error, :conflicts_with_post_slug}

      url_slug_exists?(group_slug, url_slug, language, exclude_post_slug) ->
        {:error, :slug_already_exists}

      true ->
        {:ok, url_slug}
    end
  end

  @doc """
  Checks if a slug already exists within the given publishing group (DB-only).
  """
  @spec slug_exists?(String.t(), String.t()) :: boolean()
  def slug_exists?(group_slug, post_slug) do
    case DBStorage.get_post(group_slug, post_slug) do
      nil -> false
      _post -> true
    end
  rescue
    _ -> false
  end

  @doc """
  Clears custom url_slugs that conflict with a given post slug.
  """
  @spec clear_conflicting_url_slugs(String.t(), String.t()) :: [{String.t(), String.t()}]
  def clear_conflicting_url_slugs(group_slug, post_slug) do
    # On a cache miss, fall back to the SAME source the cache is built from
    # (`list_posts_for_listing/1`), so the conflict scan sees identical
    # `:language_slugs`-bearing maps either way. This is a mutation path:
    # silently returning [] on a miss (memory cache disabled, or a loser of a
    # concurrent regeneration) would skip conflict cleanup and leave a stale
    # custom url_slug pointing at the wrong post.
    posts =
      case ListingCache.read(group_slug) do
        {:ok, posts} -> posts
        {:error, _} -> DBStorage.list_posts_for_listing(group_slug)
      end

    conflicts = find_conflicting_url_slugs(posts, post_slug)
    clear_url_slugs_for_conflicts(group_slug, post_slug, conflicts)
    log_cleared_conflicts(conflicts, post_slug)
    conflicts
  end

  @doc """
  Clears a specific url_slug from all translations of a single post (DB-only).
  """
  @spec clear_url_slug_from_post(String.t(), String.t(), String.t()) :: [String.t()]
  def clear_url_slug_from_post(group_slug, post_slug, url_slug_to_clear) do
    DBStorage.clear_url_slug_from_post(group_slug, post_slug, url_slug_to_clear)
  end

  @doc """
  Generates a unique slug based on title and optional preferred slug.
  """
  @spec generate_unique_slug(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, :invalid_format | :reserved_language_code}
  def generate_unique_slug(group_slug, title, preferred_slug \\ nil, opts \\ []) do
    current_slug = Keyword.get(opts, :current_slug)

    base_slug_result =
      case preferred_slug do
        nil ->
          {:ok, slugify(title)}

        slug when is_binary(slug) ->
          sanitized = slugify(slug)
          if sanitized == "", do: {:ok, slugify(title)}, else: validate_slug(sanitized)
      end

    case base_slug_result do
      {:ok, base_slug} when base_slug != "" ->
        {:ok,
         Slug.ensure_unique(base_slug, fn candidate ->
           slug_exists_for_generation?(group_slug, candidate, current_slug)
         end)}

      {:ok, ""} ->
        {:ok,
         Slug.ensure_unique("untitled", fn candidate ->
           slug_exists_for_generation?(group_slug, candidate, current_slug)
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp conflicts_with_post_slug?(group_slug, url_slug, exclude_post_slug) do
    if url_slug == exclude_post_slug do
      false
    else
      slug_exists?(group_slug, url_slug)
    end
  end

  defp url_slug_exists?(group_slug, url_slug, language, exclude_post_slug) do
    # Always go to the DB (any-version variant) for uniqueness checks —
    # `ListingCache` is built from active versions only, so a cache-hit
    # path would silently miss draft-to-draft collisions and let two
    # authors take the same `url_slug` simultaneously before either
    # publishes. Uniqueness checks fire on create / save, which is
    # infrequent enough that bypassing the cache is fine.
    #
    # The exclusion of the current post happens in SQL (not by inspecting a
    # single fetched row) so a real collision can't be masked when the
    # arbitrarily-ordered match is the post being edited.
    DBStorage.url_slug_taken_by_other_post?(group_slug, language, url_slug, exclude_post_slug)
  rescue
    _ -> false
  end

  defp slug_exists_for_generation?(_group_slug, candidate, current_slug)
       when not is_nil(current_slug) and candidate == current_slug,
       do: false

  defp slug_exists_for_generation?(group_slug, candidate, _current_slug) do
    slug_exists?(group_slug, candidate)
  end

  defp find_conflicting_url_slugs(posts, post_slug) do
    posts
    |> Enum.reject(fn post -> post.slug == post_slug end)
    |> Enum.flat_map(fn post ->
      (post.language_slugs || %{})
      |> Enum.filter(fn {_lang, url_slug} -> url_slug == post_slug end)
      |> Enum.map(fn {lang, _} -> {post.slug, lang} end)
    end)
  end

  defp clear_url_slugs_for_conflicts(group_slug, slug_to_clear, conflicts) do
    Enum.each(conflicts, fn {conflicting_post_slug, _language} ->
      DBStorage.clear_url_slug_from_post(group_slug, conflicting_post_slug, slug_to_clear)
    end)
  end

  defp log_cleared_conflicts([], _post_slug), do: :ok

  defp log_cleared_conflicts(conflicts, post_slug) do
    Logger.warning(
      "[Slugs] Cleared conflicting url_slugs for post slug '#{post_slug}': #{inspect(conflicts)}"
    )
  end
end
