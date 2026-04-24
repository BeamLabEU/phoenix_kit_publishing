defmodule PhoenixKit.Modules.Publishing.LanguageHelpers do
  @moduledoc """
  Pure language utility functions for the Publishing module.

  Provides language detection, display ordering, language info lookup,
  and primary language management.
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Settings

  @default_language_no_prefix_key "publishing_default_language_no_prefix"

  @doc """
  Returns all enabled language codes for multi-language support.
  Falls back to content language if Languages module is disabled.
  """
  @spec enabled_language_codes() :: [String.t()]
  def enabled_language_codes do
    if Languages.enabled?() do
      Languages.get_enabled_language_codes()
    else
      [Settings.get_content_language()]
    end
  end

  @doc """
  Returns the primary/canonical language for versioning.
  Uses Settings.get_content_language().
  """
  @spec get_primary_language() :: String.t()
  def get_primary_language do
    Settings.get_content_language()
  end

  @doc """
  Returns the primary language code as it should appear in public URLs.

  Content rows keep using the full configured language code (for example
  `"en-GB"`), but public routes use the base code (`"en"`).
  """
  @spec get_primary_language_base() :: String.t()
  def get_primary_language_base do
    get_primary_language()
    |> url_language_code()
  end

  @doc """
  Normalizes a content language code for use in public URLs.
  """
  @spec url_language_code(String.t() | nil) :: String.t() | nil
  def url_language_code(nil), do: nil

  def url_language_code(language_code) when is_binary(language_code) do
    DialectMapper.extract_base(language_code)
  end

  @doc """
  Returns true when public URLs should omit the prefix for the default language.
  """
  @spec default_language_no_prefix?() :: boolean()
  def default_language_no_prefix? do
    Settings.get_boolean_setting(@default_language_no_prefix_key, false)
  end

  @doc """
  Returns true when public URLs should include a language prefix.

  Prefixes are omitted when:
  - the site is effectively single-language, or
  - the caller requested the default language and the
    `publishing_default_language_no_prefix` setting is enabled.
  """
  @spec use_language_prefix?(String.t() | nil) :: boolean()
  def use_language_prefix?(language_code) do
    language_code = url_language_code(language_code) || get_primary_language_base()

    not single_language_mode?() and
      not (default_language_no_prefix?() and language_code == get_primary_language_base())
  end

  @doc """
  Returns true when the site should behave as single-language for public URLs.
  """
  @spec single_language_mode?() :: boolean()
  def single_language_mode? do
    not Languages.enabled?() or length(enabled_language_codes()) <= 1
  rescue
    _ -> true
  end

  @doc """
  Gets language details (name, flag) for a given language code.

  Searches in order:
  1. Predefined languages (BeamLabCountries) - for full locale details
  2. User-configured languages - for custom/less common languages
  """
  @spec get_language_info(String.t()) ::
          %{code: String.t(), name: String.t(), flag: String.t()} | nil
  def get_language_info(language_code) do
    find_in_predefined_languages(language_code) ||
      find_in_configured_languages(language_code)
  end

  @doc """
  Checks if a language code is enabled, considering base code matching.

  Handles cases where:
  - The code is `en` and enabled languages has `"en-US"` -> matches
  - The code is `en-US` and enabled languages has `"en"` -> matches
  """
  @spec language_enabled?(String.t(), [String.t()]) :: boolean()
  def language_enabled?(language_code, enabled_languages) do
    if language_code in enabled_languages do
      true
    else
      base_code = DialectMapper.extract_base(language_code)

      Enum.any?(enabled_languages, fn enabled_lang ->
        enabled_lang == language_code or
          DialectMapper.extract_base(enabled_lang) == base_code
      end)
    end
  end

  @doc """
  Determines the display code for a language based on whether multiple dialects
  of the same base language are enabled.

  If only one dialect of a base language is enabled (e.g., just "en-US"),
  returns the base code ("en") for cleaner display.

  If multiple dialects are enabled (e.g., "en-US" and "en-GB"),
  returns the full dialect code ("en-US") to distinguish them.
  """
  @spec get_display_code(String.t(), [String.t()]) :: String.t()
  def get_display_code(language_code, enabled_languages) do
    base_code = DialectMapper.extract_base(language_code)

    dialects_count =
      Enum.count(enabled_languages, fn lang ->
        DialectMapper.extract_base(lang) == base_code
      end)

    if dialects_count > 1 do
      language_code
    else
      base_code
    end
  end

  @doc """
  Orders languages for display in the language switcher.

  Order: primary language first, then languages with translations (sorted),
  then languages without translations (sorted).
  """
  @spec order_languages_for_display([String.t()], [String.t()], String.t() | nil) :: [String.t()]
  def order_languages_for_display(available_languages, enabled_languages, primary_language \\ nil) do
    primary_lang = primary_language || get_primary_language()

    langs_with_content =
      available_languages
      |> Enum.reject(&(&1 == primary_lang))
      |> Enum.sort()

    langs_without_content =
      enabled_languages
      |> Enum.reject(&(&1 in available_languages or &1 == primary_lang))
      |> Enum.sort()

    [primary_lang] ++ langs_with_content ++ langs_without_content
  end

  @doc """
  Checks if a language code is reserved (cannot be used as a slug).
  """
  @spec reserved_language_code?(String.t()) :: boolean()
  def reserved_language_code?(slug) do
    language_codes =
      try do
        Languages.get_language_codes()
      rescue
        _ -> []
      end

    slug in language_codes
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp find_in_predefined_languages(language_code) do
    case Languages.get_available_language_by_code(language_code) do
      nil ->
        base_code = DialectMapper.extract_base(language_code)
        is_base_code = language_code == base_code and not String.contains?(language_code, "-")
        default_dialect = DialectMapper.base_to_dialect(base_code)

        resolve_predefined_by_base(base_code, default_dialect, is_base_code)

      exact_match ->
        exact_match
    end
  end

  defp resolve_predefined_by_base(base_code, default_dialect, is_base_code) do
    case Languages.get_available_language_by_code(default_dialect) do
      nil ->
        all_languages = Languages.get_available_languages()

        Enum.find(all_languages, fn lang -> DialectMapper.extract_base(lang.code) == base_code end)

      default_match when is_base_code ->
        %{default_match | name: extract_base_language_name(default_match.name)}

      default_match ->
        default_match
    end
  end

  defp extract_base_language_name(name) when is_binary(name) do
    case String.split(name, " (", parts: 2) do
      [base_name, _region] -> base_name
      [base_name] -> base_name
    end
  end

  defp extract_base_language_name(name), do: name

  defp find_in_configured_languages(language_code) do
    configured_languages = Languages.get_languages()

    exact_match =
      Enum.find(configured_languages, fn lang -> lang.code == language_code end)

    result = exact_match || find_configured_by_base(configured_languages, language_code)

    if result do
      %{code: result.code, name: result.name || result.code, flag: result.flag || ""}
    else
      nil
    end
  end

  defp find_configured_by_base(configured_languages, language_code) do
    base_code = DialectMapper.extract_base(language_code)
    default_dialect = DialectMapper.base_to_dialect(base_code)

    Enum.find(configured_languages, fn lang -> lang.code == default_dialect end) ||
      Enum.find(configured_languages, fn lang ->
        DialectMapper.extract_base(lang.code) == base_code
      end)
  end

  # ===========================================================================
  # Language Map Key Resolution
  # ===========================================================================

  @doc """
  Resolves a display language code to a key in a language map.

  Language maps (e.g., `language_titles`, `language_slugs`) use full dialect
  codes as keys (e.g., `"en-US"`), but the display/canonical language may be
  a base code (e.g., `"en"`) when only one dialect is enabled.

  Tries exact match first, then falls back to base code matching.
  """
  @spec resolve_language_key(String.t(), [String.t()]) :: String.t()
  def resolve_language_key(language, available_keys) do
    if language in available_keys do
      language
    else
      base = DialectMapper.extract_base(language)
      Enum.find(available_keys, language, fn key -> DialectMapper.extract_base(key) == base end)
    end
  end

  # ===========================================================================
  # Post Language Building
  # ===========================================================================

  @doc """
  Builds language data for a post's language switcher.
  Returns a list of language maps with status, enabled flag, known flag, and metadata.
  """
  def build_post_languages(post, enabled_languages, primary_language \\ nil) do
    primary_lang =
      primary_language || get_primary_language()

    all_languages =
      order_languages_for_display(
        post.available_languages || [],
        enabled_languages,
        primary_lang
      )

    all_languages
    |> Enum.map(&build_language_entry(&1, post, enabled_languages, primary_lang))
    |> Enum.filter(fn lang -> lang.exists || lang.enabled end)
  end

  @doc """
  Builds a single language entry map for a post.
  """
  def build_language_entry(lang_code, post, enabled_languages, primary_lang) do
    lang_info = get_language_info(lang_code)
    available = post.available_languages || []
    content_exists = lang_code in available
    post_status = post[:metadata] && post.metadata.status

    %{
      code: lang_code,
      display_code: get_display_code(lang_code, enabled_languages),
      name: if(lang_info, do: lang_info.name, else: lang_code),
      flag: if(lang_info, do: lang_info.flag, else: ""),
      status: if(content_exists, do: post_status, else: nil),
      exists: content_exists,
      enabled: language_enabled?(lang_code, enabled_languages),
      known: lang_info != nil,
      # is_default is used for ordering only, not for special UI treatment
      is_default: lang_code == primary_lang,
      uuid: post[:uuid]
    }
  end
end
