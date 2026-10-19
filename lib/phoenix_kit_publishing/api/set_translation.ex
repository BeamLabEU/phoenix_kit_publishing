defmodule PhoenixKit.Modules.Publishing.API.SetTranslation do
  @moduledoc false
  # Tool `publishing.set_translation`: add or update one non-primary language of a version.

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing.API.{Common, Danger, Presenter, Refs, TextScan}
  alias PhoenixKit.Modules.Publishing.{Constants, DBStorage, LanguageHelpers}
  alias PhoenixKit.Modules.Publishing.{Posts, PublishingContent, TranslationManager}

  @tool "publishing.set_translation"
  @og_fields ~w(og_title og_description og_image_id)
  @og_keys %{
    "og_title" => "title",
    "og_description" => "description",
    "og_image_id" => "image_uuid"
  }

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with :ok <- texts(input),
         {:ok, input} <- Common.canonical_image_id(input, "og_image_id"),
         {:ok, hit} <- Refs.resolve_post(input["post"], []) |> Refs.post_error(input["post"]),
         :ok <- Refs.ensure_group_active(hit.group) |> Refs.group_error(),
         {:ok, version} <-
           Refs.resolve_version(hit.db_post, input["version"], :write) |> Refs.version_error(),
         {:ok, language} <- language(input["language"]),
         row = DBStorage.get_content(version.uuid, language),
         :ok <-
           Common.check_revision(
             input,
             hit.db_post,
             version,
             revision_row(input, hit, version, language, row)
           ) do
      t = %{
        input: input,
        hit: hit,
        version: version,
        language: language,
        row: row,
        og_row: og_row(version, language, row)
      }

      dry? = Map.get(ctx, :dry_run?, false)

      cond do
        unchanged?(t) -> unchanged(t, dry?)
        dry? -> preview(t, ctx)
        true -> execute(t, ctx)
      end
    end
  end

  # get_post of a language without a row shows the text it falls back to, and its revision covers
  # that row: a new language is checked against the same row.
  defp revision_row(_input, _hit, _version, _language, %{} = row), do: row

  defp revision_row(%{"if_revision" => expected}, hit, version, language, nil)
       when not is_nil(expected) do
    case Refs.read_post_for_preview(hit.db_post.uuid, language, version.version_number) do
      {:ok, %{language: shown}} -> DBStorage.get_content(version.uuid, shown)
      _other -> nil
    end
  end

  defp revision_row(_input, _hit, _version, _language, nil), do: nil

  defp texts(input) do
    with :ok <-
           Common.check_text("title", input["title"], max_chars: Constants.max_title_length()),
         :ok <-
           Common.check_text("content", input["content"],
             max: TextScan.max_body_bytes(),
             reason: "content_too_large"
           ),
         :ok <- present("title", input["title"]),
         :ok <- present("content", input["content"]) do
      og_texts(input)
    end
  end

  defp og_texts(input) do
    Enum.find_value(~w(og_title og_description), :ok, fn field ->
      case Common.check_text(field, input[field], max: 5000) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp present(path, value) do
    if String.trim(value || "") == "",
      do: Common.invalid(path, "must not be blank", "empty_translation"),
      else: :ok
  end

  defp language(code) do
    case Refs.resolve_language(code) do
      {:ok, resolved} ->
        if resolved == LanguageHelpers.get_primary_language(),
          do: Common.invalid("language", "the primary language is edited with update_post"),
          else: {:ok, resolved}

      {:error, {:language_not_enabled, allowed}} ->
        Common.invalid("language", "is not an enabled language", "language_not_enabled", %{
          allowed: allowed
        })
    end
  end

  # A legacy base-code row ("de" for "de-DE") is promoted by the first write, so its og values
  # are the current ones for the target language.
  defp og_row(_version, _language, %{} = row), do: row

  defp og_row(version, language, nil) do
    case DialectMapper.extract_base(language) do
      ^language -> nil
      base -> DBStorage.get_content(version.uuid, base)
    end
  end

  defp current_og(t), do: (t.og_row && PublishingContent.get_og(t.og_row)) || %{}

  # The og fields the call sends that differ from the stored ones (nil and "" are equal).
  defp og_changes(t) do
    og = current_og(t)

    for {field, key} <- Enum.sort(@og_keys),
        Map.has_key?(t.input, field),
        from = og[key] || "",
        to = t.input[field] || "",
        from != to,
        into: %{} do
      {field, %{"scope" => "language", "from" => clip(from), "to" => clip(to)}}
    end
  end

  defp unchanged?(%{row: nil}), do: false

  defp unchanged?(t) do
    t.row.title == t.input["title"] and t.row.content == t.input["content"] and
      og_changes(t) == %{}
  end

  defp unchanged(t, true) do
    row = %{
      "action" => "unchanged",
      "language" => t.language,
      "version" => t.version.version_number
    }

    contents = DBStorage.list_contents(t.version.uuid)

    Common.preview(
      [row],
      %{"requires_confirmation" => false},
      {:set_translation, :unchanged,
       Common.post_state(t.hit.db_post, t.hit.group, [t.version], contents)}
    )
  end

  defp unchanged(t, false), do: {:ok, answer(t.hit, t.version, t.language, "unchanged")}

  # --- dry run -----------------------------------------------------------------------------

  defp preview(t, ctx) do
    %{input: input, hit: hit, version: version, language: language, row: row} = t

    out = %{
      "action" => if(row, do: "update", else: "add"),
      "language" => language,
      "version" => version.version_number,
      "live" => hit.db_post.active_version_uuid == version.uuid,
      "public" => Presenter.public_state(hit.db_post, version),
      "changes" =>
        Map.merge(og_changes(t), %{
          "title" => %{
            "scope" => "language",
            "from" => clip((row && row.title) || ""),
            "to" => clip(input["title"])
          },
          "content" => Common.content_change((row && row.content) || "", input["content"])
        })
    }

    contents = DBStorage.list_contents(version.uuid)

    term =
      {:set_translation, Common.post_state(hit.db_post, hit.group, [version], contents), language,
       Common.sha256(input["title"]), Common.sha256(input["content"]),
       Common.fingerprint(Common.og_params(input, t.og_row))}

    Common.preview([out], %{"requires_confirmation" => Danger.set_translation(input, ctx)}, term)
  end

  defp clip(value), do: String.slice(value, 0, 500)

  # --- write: the four steps of the tool ---------------------------------------------------

  defp execute(t, ctx) do
    %{hit: hit, version: version, language: language} = t
    base_opts = Common.write_opts(ctx, @tool)

    with :ok <- Danger.recheck(hit.db_post, version, nil, ctx),
         {:ok, created?} <- ensure_row(t, base_opts) do
      case reread(t) do
        {:ok, post} -> write(t, post, created?, base_opts, ctx)
        error -> left_behind(error, created?, language)
      end
    end
  end

  defp write(t, post, created?, base_opts, ctx) do
    %{input: input, hit: hit, version: version, language: language} = t

    check = Common.locked_check(ctx, fn locked, v -> Danger.live_condition(locked, v, nil) end)

    params =
      Map.merge(
        %{"title" => input["title"], "content" => input["content"]},
        Common.og_params(input, t.og_row)
      )

    fields = ["content", "title"] ++ Enum.filter(@og_fields, &Map.has_key?(input, &1))

    opts =
      base_opts
      |> Keyword.merge(publish: false, locked_check: check)
      |> Common.put_log_fields(Enum.sort(fields))

    case Posts.update_post(hit.group.slug, post, params, opts) do
      {:ok, _post} -> {:ok, answer(hit, version, language, action(created?))}
      {:error, reason} -> left_behind(Common.error(reason), created?, language)
    end
  end

  # An existing row skips the call: add_language_to_post logs translation.added unconditionally on
  # success, which for an update would be a misleading row. It also promotes a legacy base-code row.
  defp ensure_row(%{row: %{}}, _opts), do: {:ok, false}

  defp ensure_row(%{row: nil} = t, opts) do
    case TranslationManager.add_language_to_post(
           t.hit.group.slug,
           t.hit.db_post.uuid,
           t.language,
           t.version.version_number,
           opts
         ) do
      {:ok, _} -> {:ok, true}
      {:error, reason} -> Common.error(reason)
    end
  end

  # Require the row for THIS language: the module falls back to another language when it is missing.
  defp reread(t) do
    case Refs.read_post_for_preview(t.hit.db_post.uuid, t.language, t.version.version_number) do
      {:ok, %{language: language} = post} when language == t.language ->
        {:ok, post}

      _other ->
        Common.invalid("language", "the language row could not be read back", "language_missing")
    end
  end

  # The API deletes nothing: an empty row stays and the next publish_post preview warns.
  defp left_behind({:error, code, message, context}, true, language),
    do: {:error, code, message, Map.put(context, :left_behind, "empty row for #{language}")}

  defp left_behind(error, false, _language), do: error

  defp action(true), do: "created"
  defp action(false), do: "updated"

  defp answer(hit, version, language, action) do
    db = DBStorage.get_post_by_uuid(hit.db_post.uuid, [:group])

    %{
      "action" => action,
      "language" => language,
      "version" => version.version_number,
      "post" =>
        Presenter.write_summary(
          db,
          db.group,
          DBStorage.list_versions(db.uuid),
          DBStorage.list_contents(version.uuid)
        )
    }
  end
end
