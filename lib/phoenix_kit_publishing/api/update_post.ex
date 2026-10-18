defmodule PhoenixKit.Modules.Publishing.API.UpdatePost do
  @moduledoc false
  # Tool `publishing.update_post`. It NEVER publishes, renames only on request, and never
  # sends status / published_at / url_slug / tags.

  alias PhoenixKit.Modules.Publishing.API.{Common, Danger, Presenter, Refs, TextScan}

  alias PhoenixKit.Modules.Publishing.{
    Constants,
    DBStorage,
    LanguageHelpers,
    Posts,
    PublishingContent
  }

  @tool "publishing.update_post"
  @fields ~w(title content description seo_title excerpt featured_image_id featured sitemap_exclude og_title og_description og_image_id category_ids slug)
  @text_fields ~w(title content description seo_title excerpt og_title og_description)
  @image_fields ~w(featured_image_id og_image_id)
  @scope %{
    "title" => "language",
    "content" => "language",
    "og_title" => "language",
    "og_description" => "language",
    "og_image_id" => "language",
    "description" => "version",
    "seo_title" => "version",
    "excerpt" => "version",
    "featured_image_id" => "version",
    "featured" => "version",
    "sitemap_exclude" => "version",
    "category_ids" => "version",
    "slug" => "post"
  }
  @param %{"featured_image_id" => "featured_image_uuid", "category_ids" => "category_uuids"}
  @direct ~w(title content description seo_title excerpt featured_image_id featured sitemap_exclude)

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    dry? = Map.get(ctx, :dry_run?, false)

    with :ok <- not_empty(input),
         :ok <- texts(input),
         :ok <- title_present(input),
         {:ok, input} <- images(input),
         {:ok, hit} <- Refs.resolve_post(input["post"], []) |> Refs.post_error(),
         :ok <- Refs.ensure_group_active(hit.group) |> Refs.group_error(),
         {:ok, version} <-
           Refs.resolve_version(hit.db_post, input["version"], :write) |> Refs.version_error(),
         {:ok, language} <- language(input["language"]),
         {:ok, post} <- read(hit.db_post.uuid, language, version.version_number),
         contents = DBStorage.list_contents(version.uuid),
         row = Enum.find(contents, &(&1.language == language)),
         :ok <- Common.check_revision(input, hit.db_post, version, row),
         {:ok, categories} <- categories(hit.group, input),
         {:ok, slug} <- slug(hit, input) do
      t = %{
        hit: hit,
        version: version,
        contents: contents,
        language: language,
        post: post,
        row: row,
        input: input
      }

      changes = changes(t, categories, slug)

      cond do
        changes == %{} -> unchanged(t, dry?)
        dry? -> preview(t, changes, ctx)
        true -> execute(t, changes, params(t, categories, slug), slug, ctx)
      end
    end
  end

  defp not_empty(input) do
    if Enum.any?(@fields, &Map.has_key?(input, &1)),
      do: :ok,
      else: Common.invalid("", "give at least one field to change", "empty_update")
  end

  defp texts(input) do
    @text_fields
    |> Enum.filter(&Map.has_key?(input, &1))
    |> Enum.find_value(:ok, fn field ->
      case Common.check_text(field, input[field], text_opts(field)) do
        :ok -> nil
        error -> error
      end
    end)
  end

  # create_post refuses a blank title; clearing one here would leave a post that cannot be published.
  defp title_present(%{"title" => title}) do
    if is_binary(title) and String.trim(title) != "",
      do: :ok,
      else: Common.invalid("title", "must not be blank", "title_required")
  end

  defp title_present(_input), do: :ok

  defp images(input) do
    Enum.reduce_while(@image_fields, {:ok, input}, fn field, {:ok, acc} ->
      case Common.canonical_image_id(acc, field) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp text_opts("content"), do: [max: TextScan.max_body_bytes(), reason: "content_too_large"]
  defp text_opts("title"), do: [max_chars: Constants.max_title_length()]
  defp text_opts(_field), do: [max: 5000]

  # A write needs an ENABLED language: a row in a since-disabled language is not editable.
  defp language(code) do
    case Refs.resolve_language(code) do
      {:ok, language} ->
        {:ok, language}

      {:error, {:language_not_enabled, allowed}} ->
        Common.invalid("language", "is not an enabled language", "language_not_enabled", %{
          allowed: allowed
        })
    end
  end

  # Read WITHOUT healing (a dry run must not write); the module silently falls back to another
  # language when the row is missing, which would turn this write into an overwrite of that one.
  defp read(uuid, language, number) do
    case Refs.read_post_for_preview(uuid, language, number) do
      {:ok, %{language: ^language} = post} ->
        {:ok, post}

      {:ok, fallback} ->
        missing(language, fallback)

      {:error, _reason} ->
        {:error, :not_found, "The post could not be read.", %{}}
    end
  end

  # The primary language may sit under its legacy base code until a read repairs it; set_translation
  # refuses the primary language, so the usual advice would be a dead end.
  defp missing(language, fallback) do
    legacy? =
      language == LanguageHelpers.get_primary_language() and
        fallback.language == LanguageHelpers.url_language_code(language)

    message =
      if legacy?,
        do:
          "#{language} is stored under a legacy language code; read the post once to repair it, then retry",
        else: "#{language} has no row on this version; use set_translation to create it"

    Common.invalid("language", message, "language_missing")
  end

  defp categories(group, %{"category_ids" => ids}) when is_list(ids) do
    known = MapSet.new(Common.categories!(group.slug), & &1.uuid)

    case Enum.reject(ids, &MapSet.member?(known, &1)) do
      [] ->
        {:ok, Enum.uniq(ids)}

      unknown ->
        Common.invalid("category_ids", "not categories of this group", "unknown_category", %{
          unknown: unknown
        })
    end
  end

  defp categories(_group, _input), do: {:ok, nil}

  # nil = no rename (absent, or equal to the current slug).
  defp slug(hit, %{"slug" => slug}) when is_binary(slug) do
    cond do
      hit.group.mode != "slug" ->
        Common.invalid("slug", "a timestamp-mode post has no slug", "slug_not_allowed")

      slug == hit.db_post.slug ->
        {:ok, nil}

      true ->
        rename(hit.group.slug, slug)
    end
  end

  defp slug(_hit, _input), do: {:ok, nil}

  defp rename(group_slug, slug) do
    with {:ok, slug} <- Common.validate_slug(slug) do
      if Common.slug_taken?(group_slug, slug) == false,
        do: {:ok, slug},
        else: Common.invalid("slug", "the slug is already in use", "slug_taken")
    end
  end

  # --- the diff ------------------------------------------------------------------------------

  @version_keys %{
    "description" => "description",
    "seo_title" => "seo_title",
    "excerpt" => "excerpt",
    "featured_image_id" => "featured_image_uuid"
  }
  @og_keys %{
    "og_title" => "title",
    "og_description" => "description",
    "og_image_id" => "image_uuid"
  }

  defp current("title", t), do: t.row && t.row.title
  defp current("content", t), do: t.row && t.row.content
  defp current("slug", t), do: t.hit.db_post.slug
  defp current("category_ids", t), do: version_data(t)["category_uuids"] || []

  defp current(field, t) when field in ~w(featured sitemap_exclude),
    do: version_data(t)[field] || false

  defp current(field, t) when is_map_key(@version_keys, field),
    do: version_data(t)[Map.fetch!(@version_keys, field)]

  defp current(field, t), do: current_og(t)[Map.fetch!(@og_keys, field)]

  defp version_data(t), do: t.version.data || %{}
  defp current_og(t), do: (t.row && PublishingContent.get_og(t.row)) || %{}

  defp desired("category_ids", _t, categories, _slug), do: categories
  defp desired("slug", _t, _categories, slug), do: slug
  defp desired(field, t, _categories, _slug), do: t.input[field]

  # nil and "" are equal for the "unchanged" test; lists compare as sets.
  defp norm(nil), do: ""
  defp norm(list) when is_list(list), do: Enum.sort(list)
  defp norm(other), do: other

  defp changes(t, categories, slug) do
    @fields
    |> Enum.filter(&(Map.has_key?(t.input, &1) and not (&1 == "slug" and is_nil(slug))))
    |> Enum.reduce(%{}, fn field, acc ->
      from = current(field, t)
      to = desired(field, t, categories, slug)

      if norm(from) == norm(to),
        do: acc,
        else: Map.put(acc, field, %{"scope" => @scope[field], "from" => from, "to" => to})
    end)
  end

  # The module params: PRESENT keys only; null becomes "" for the text fields; the og_* keys are all
  # sent, the unspecified ones merged from the current og; `slug` only when it really changes.
  defp params(t, categories, slug) do
    input = t.input

    base =
      for field <- @direct, Map.has_key?(input, field), into: %{} do
        value =
          if is_nil(input[field]) and field not in ~w(featured sitemap_exclude),
            do: "",
            else: input[field]

        {Map.get(@param, field, field), value}
      end

    base
    |> put_unless_nil("category_uuids", categories)
    |> put_unless_nil("slug", slug)
    |> Map.merge(Common.og_params(input, t.row))
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  # --- answers ---------------------------------------------------------------------------------

  defp unchanged(t, true) do
    row = %{"action" => "unchanged", "version" => t.version.version_number}

    Common.preview(
      [row],
      %{"requires_confirmation" => false},
      {:update_post, :unchanged,
       Common.post_state(t.hit.db_post, t.hit.group, [t.version], t.contents)}
    )
  end

  defp unchanged(t, false), do: {:ok, answer("unchanged", t, %{})}

  defp preview(t, changes, ctx) do
    shown =
      Map.new(changes, fn
        {"content", c} ->
          {"content", Common.content_change((t.row && t.row.content) || "", c["to"] || "")}

        {field, c} ->
          {field, %{"scope" => c["scope"], "from" => clip(c["from"]), "to" => clip(c["to"])}}
      end)

    row = %{
      "action" => "update",
      "version" => t.version.version_number,
      "live" => t.hit.db_post.active_version_uuid == t.version.uuid,
      "public" => Presenter.public_state(t.hit.db_post, t.version),
      "changes" => shown
    }

    new_values =
      for {field, c} <- Enum.sort(changes),
          do: {field, c["scope"], Common.sha256(:erlang.term_to_binary(c["to"]))}

    term =
      {:update_post, Common.post_state(t.hit.db_post, t.hit.group, [t.version], t.contents),
       new_values}

    Common.preview([row], %{"requires_confirmation" => Danger.update_post(t.input, ctx)}, term)
  end

  defp clip(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp clip(value), do: value

  defp execute(t, changes, params, slug, ctx) do
    with :ok <- Danger.recheck(t.hit.db_post, t.version, slug, ctx) do
      check =
        Common.locked_check(ctx, fn locked, version ->
          Danger.live_condition(locked, version, slug)
        end)

      opts =
        Common.write_opts(ctx, @tool, publish: false, locked_check: check)
        |> Common.put_log_fields(changes |> Map.keys() |> Enum.sort())

      case Posts.update_post(t.hit.group.slug, t.post, params, opts) do
        {:ok, _post} -> {:ok, answer("updated", t, changes)}
        {:error, reason} -> Common.error(reason)
      end
    end
  end

  defp answer(action, t, changes) do
    db = DBStorage.get_post_by_uuid(t.hit.db_post.uuid, [:group])

    %{
      "action" => action,
      "post" =>
        Presenter.write_summary(
          db,
          db.group,
          DBStorage.list_versions(db.uuid),
          DBStorage.list_contents(t.version.uuid)
        ),
      "changed" =>
        for({field, _} <- Enum.sort(changes), do: %{"field" => field, "scope" => @scope[field]})
    }
  end
end
