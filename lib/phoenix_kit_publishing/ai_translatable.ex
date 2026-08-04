defmodule PhoenixKitPublishing.AITranslatable do
  @moduledoc """
  `PhoenixKitAI.Translatable` adapter for publishing posts — the
  per-module hook into PhoenixKitAI's generic AI-translation pipeline
  (`PhoenixKitAI.{Translations,TranslateWorker}`).

  Replaces the bespoke `Workers.TranslatePostWorker`, which translated every
  language **sequentially in a single Oban job**. `Translations.enqueue_all_missing/2`
  dispatches **one job per target language**, so they run in parallel (bounded
  by the Oban queue) — wall-clock drops from the sum of all languages to ~the
  slowest single one.

  ## Resource identity

  `resource_type` is `"publishing_post"`; `resource_uuid` is the post's uuid
  (PhoenixKitAI validates it as a real UUID). Translations target the post's
  **active version** — the version the editor normally works on.

  ## Fields

  `source_fields/2` returns `%{"title", "content"}` read in the source
  language — lowercase to match the `{{title}}`/`{{content}}` placeholders in
  the publishing translation prompt, the same convention as the catalogue and
  projects adapters (PhoenixKitAI's variable substitution is case-sensitive). `put_translation/4` creates the target-language content row (via
  `add_language_to_post` when absent) and writes the translated title/content,
  **generating the per-language `url_slug` locally** from the translated title
  via `SlugHelpers.slugify/1`. That honors the configured slug style and avoids
  trusting an AI-returned slug (which a reasoning model can mangle).

  ## Concurrency

  Each target language is a distinct `phoenix_kit_publishing_contents` row
  (unique on `version_uuid + language`), so concurrent per-language jobs never
  touch the same row — no merge/lock dance is needed (unlike JSONB-on-one-row
  consumers).

  ## Events

  `pubsub_topics/1` returns the post's translations topic, so PhoenixKitAI's
  `{:ai_translation, …}` lifecycle events reach the editor LiveView (already
  subscribed to that topic). Per-language content creation also emits
  publishing's own `:translation_created` via `add_language_to_post`.
  """

  @behaviour PhoenixKitAI.Translatable

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.SlugHelpers
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @resource_type "publishing_post"

  defstruct [:post_uuid, :group_slug, :post_slug, :version]

  @type t :: %__MODULE__{
          post_uuid: String.t(),
          group_slug: String.t(),
          post_slug: String.t() | nil,
          version: pos_integer() | nil
        }

  @impl true
  # Required arity — delegates with a nil scope, i.e. the post's active version
  # (the historical fetch/2 behavior).
  def fetch(resource_type, post_uuid), do: fetch(resource_type, post_uuid, nil)

  @impl true
  def fetch(@resource_type, post_uuid, scope) when is_binary(post_uuid) do
    # `scope` is the version number (as a string from the Oban args) the editor
    # was on; nil → active version. Pin the resolved version and thread it
    # through the read (source_fields) and the write (ensure_language_row) so a
    # published post with a newer draft can't read one version and write another
    # — and so translating a draft targets THAT draft, not the active version.
    version = parse_scope(scope)

    case Publishing.read_post_by_uuid(post_uuid, LanguageHelpers.get_primary_language(), version) do
      {:ok, post} ->
        {:ok,
         %__MODULE__{
           post_uuid: post_uuid,
           group_slug: post.group,
           post_slug: post.slug,
           version: version || Map.get(post, :version)
         }}

      _ ->
        {:error, :resource_not_found}
    end
  end

  def fetch(other, _uuid, _scope), do: {:error, {:unknown_resource_type, other}}

  # resource_scope carries the version number as a decimal string (or nil).
  defp parse_scope(nil), do: nil
  defp parse_scope(v) when is_integer(v), do: v

  defp parse_scope(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_scope(_), do: nil

  @impl true
  def source_fields(%__MODULE__{} = resource, source_lang) do
    case Publishing.read_post_by_uuid(resource.post_uuid, source_lang, resource.version) do
      {:ok, %{language: resolved} = post}
      when resolved != source_lang and not is_nil(resolved) ->
        # Fail closed on a language mismatch: the read falls back to another
        # language when the requested row is missing, and translating THAT
        # text labeled as `source_lang` sends (say) German to the model as
        # English — wrong output fanned out to every target. Exception: a
        # base/dialect family match ("en" row for "en-US") is the legacy
        # promote-in-place shape and is genuinely the same language.
        if LanguageHelpers.url_language_code(resolved) ==
             LanguageHelpers.url_language_code(source_lang) do
          build_source_fields(post)
        else
          %{}
        end

      {:ok, post} ->
        build_source_fields(post)

      _ ->
        %{}
    end
  end

  # Lowercase keys ("title"/"content") match the prompt's {{title}}/
  # {{content}} placeholders — the same convention as the catalogue and
  # projects adapters. Core's prompt substitution is case-SENSITIVE
  # (PhoenixKitAI.Prompt.get_variable_value) and these keys also drive
  # response parsing (markers are upcased either way), so they must line
  # up with the prompt placeholders or the model gets a literal {{title}}
  # and hallucinates. editor_translation_test.exs pins the default
  # prompt's placeholders against these keys.
  defp build_source_fields(post) do
    %{}
    |> put_nonempty("title", extract_title(post))
    |> put_nonempty("content", post.content || "")
  end

  @impl true
  def put_translation(%__MODULE__{} = resource, target_lang, fields, opts) do
    scope = build_scope(Keyword.get(opts, :actor_uuid))

    with {:ok, post} <- ensure_language_row(resource, target_lang) do
      Publishing.update_post(
        resource.group_slug,
        post,
        build_params(fields, resource, target_lang),
        %{scope: scope}
      )
    end
  end

  @impl true
  def pubsub_topics(%__MODULE__{} = resource) do
    [PublishingPubSub.post_translations_topic(resource.group_slug, resource.post_uuid)]
  end

  @doc "The resource_type string this adapter serves."
  @spec resource_type() :: String.t()
  def resource_type, do: @resource_type

  # Returns the post struct for `target_lang`, adding the language row first
  # when it doesn't exist yet (mirrors the legacy worker's create/update split).
  defp ensure_language_row(resource, target_lang) do
    case Publishing.read_post_by_uuid(resource.post_uuid, target_lang, resource.version) do
      {:ok, post} ->
        if post.language == target_lang and not Map.get(post, :is_new_translation, false) do
          {:ok, post}
        else
          Publishing.add_language_to_post(
            resource.group_slug,
            resource.post_uuid,
            target_lang,
            resource.version
          )
        end

      _ ->
        Publishing.add_language_to_post(
          resource.group_slug,
          resource.post_uuid,
          target_lang,
          resource.version
        )
    end
  end

  defp build_params(fields, resource, target_lang) do
    # `fields` comes back from core's parser keyed by the SAME names
    # source_fields/2 emitted ("title"/"content"), which are already the
    # lowercase content-schema field names.
    title = Map.get(fields, "title")

    %{}
    |> maybe_put("title", title)
    |> maybe_put("content", Map.get(fields, "content"))
    |> maybe_put_slug(title, resource, target_lang)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Per-language url_slug generated locally from the translated title (honors
  # the configured slug style; never trusts an AI-returned slug). Only set when
  # the slug is free in this group+language — otherwise omit it so the content
  # row falls back to the post's (unique) default slug. Read-time collision
  # resolution remains the backstop for the rare concurrent race.
  defp maybe_put_slug(map, title, resource, target_lang) when is_binary(title) and title != "" do
    with slug when slug != "" <- SlugHelpers.slugify(title),
         {:ok, _} <-
           SlugHelpers.validate_url_slug(
             resource.group_slug,
             slug,
             target_lang,
             resource.post_slug
           ) do
      Map.put(map, "url_slug", slug)
    else
      _ -> map
    end
  end

  defp maybe_put_slug(map, _title, _resource, _target_lang), do: map

  # Title is the first `# heading` in the body, else the stored metadata title.
  defp extract_title(post) do
    content = post.content || ""

    case Regex.run(~r/^#\s+(.+)$/m, content) do
      [_, title] -> String.trim(title)
      nil -> Map.get(post.metadata, :title, Constants.default_title())
    end
  end

  defp put_nonempty(map, key, value) when is_binary(value) do
    if String.trim(value) == "", do: map, else: Map.put(map, key, value)
  end

  defp put_nonempty(map, _key, _value), do: map

  defp build_scope(nil), do: nil

  defp build_scope(user_uuid) do
    case Auth.get_user(user_uuid) do
      nil -> nil
      user -> Scope.for_user(user)
    end
  end
end
