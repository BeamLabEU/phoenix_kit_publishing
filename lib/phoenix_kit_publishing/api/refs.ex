defmodule PhoenixKit.Modules.Publishing.API.Refs do
  @moduledoc false
  # Resolution of post / group / version / language / category references (spec §6.4).
  # Only calls that RAISE on a database error are used here (spec §8, F25).

  alias PhoenixKit.Modules.Publishing.API.Common
  alias PhoenixKit.Modules.Publishing.{Constants, DBStorage, LanguageHelpers}

  @type post_hit :: %{db_post: struct(), group: struct()}

  @spec resolve_post(term(), keyword()) :: {:ok, post_hit()} | {:error, term()}
  def resolve_post(ref, opts \\ [])

  def resolve_post(%{"id" => id} = ref, opts) when map_size(ref) == 1 and is_binary(id) do
    with {:ok, uuid} <- cast_uuid(id),
         %{} = db_post <- DBStorage.get_post_by_uuid(uuid, [:group]) do
      if db_post.trashed_at && not Keyword.get(opts, :include_trashed, false),
        do: {:error, {:post_trashed, db_post}},
        else: {:ok, %{db_post: db_post, group: db_post.group}}
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_post(%{"group" => group, "slug" => slug} = ref, opts)
      when map_size(ref) == 2 and is_binary(group) and is_binary(slug) do
    if storable?(group) and storable?(slug),
      do: lookup_by_slug(group, slug, opts),
      else: {:error, :invalid_ref}
  end

  def resolve_post(_other, _opts), do: {:error, :invalid_ref}

  defp lookup_by_slug(group, slug, opts) do
    with %{} = group_row <- DBStorage.get_group_by_slug(group),
         %{} = db_post <- find_by_slug(group, slug, Keyword.get(opts, :include_trashed, false)) do
      {:ok, %{db_post: %{db_post | group: group_row}, group: group_row}}
    else
      _ -> {:error, :not_found}
    end
  end

  # Postgres refuses a NUL byte and invalid UTF-8 in a query parameter by raising.
  defp storable?(text), do: String.valid?(text) and not String.contains?(text, <<0>>)

  defp find_by_slug(group, slug, include_trashed?) do
    DBStorage.get_post(group, slug) ||
      if include_trashed?,
        do: Enum.find(DBStorage.list_posts(group, "trashed"), &(&1.slug == slug))
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  @spec resolve_group(term()) :: {:ok, struct()} | {:error, :not_found}
  def resolve_group(slug) when is_binary(slug) do
    case storable?(slug) && DBStorage.get_group_by_slug(slug) do
      %{} = group -> {:ok, group}
      _ -> {:error, :not_found}
    end
  end

  def resolve_group(_other), do: {:error, :not_found}

  @spec ensure_group_active(struct()) :: :ok | {:error, :group_trashed}
  def ensure_group_active(%{status: "trashed"}), do: {:error, :group_trashed}
  def ensure_group_active(_group), do: :ok

  @doc """
  The version a call acts on. Mode `:read`: the active version, else the latest. Mode `:write`:
  the highest-numbered DRAFT version; no draft and no explicit number is `:no_draft_version`.
  An explicit number that exists is legal even when it is the active or an archived version.
  """
  def resolve_version(db_post, number, mode) do
    versions = DBStorage.list_versions(db_post.uuid)

    cond do
      is_integer(number) ->
        versions |> Enum.find(&(&1.version_number == number)) |> found(:version_not_found)

      mode == :read ->
        versions |> read_default(db_post) |> found(:version_not_found)

      true ->
        versions |> highest_draft() |> found(:no_draft_version)
    end
  end

  defp read_default(versions, db_post) do
    Enum.find(versions, &(&1.uuid == db_post.active_version_uuid)) ||
      Enum.max_by(versions, & &1.version_number, fn -> nil end)
  end

  defp highest_draft(versions) do
    versions
    |> Enum.filter(&(&1.status == "draft"))
    |> Enum.max_by(& &1.version_number, fn -> nil end)
  end

  defp found(nil, error), do: {:error, error}
  defp found(version, _error), do: {:ok, version}

  @doc """
  A language code of an enabled language: full (`de-DE`) or a bare code matching exactly one
  enabled code. `nil` is the primary language. `extra` are codes the post already HAS (reads
  accept them even when the language was disabled since).
  """
  def resolve_language(input, extra \\ []) do
    enabled = LanguageHelpers.enabled_language_codes()
    known = Enum.uniq(enabled ++ extra)

    cond do
      is_nil(input) ->
        {:ok, LanguageHelpers.get_primary_language()}

      input in known ->
        {:ok, input}

      is_binary(input) ->
        case Enum.filter(known, &(String.split(&1, "-") |> hd() == input)) do
          [one] -> {:ok, one}
          _ -> {:error, {:language_not_enabled, enabled}}
        end

      true ->
        {:error, {:language_not_enabled, enabled}}
    end
  end

  @doc """
  The post map exactly as `Posts.read_post_by_uuid/3` builds it, MINUS the stale fixer: a dry
  run must not write (F20). A stale legacy post may read slightly differently in a preview.
  """
  def read_post_for_preview(uuid, language, version) do
    case DBStorage.get_post_by_uuid(uuid, [:group]) do
      nil ->
        {:error, :not_found}

      db_post ->
        group_slug = db_post.group.slug

        if db_post.post_date && db_post.post_time,
          do:
            DBStorage.read_post_by_datetime(
              group_slug,
              db_post.post_date,
              db_post.post_time,
              language,
              version
            ),
          else: DBStorage.read_post(group_slug, db_post.slug, language, version)
    end
  end

  @doc "The rule of `Versions.validate_primary_title!/…` (versions.ex), including its legacy base-code fallback."
  def primary_title_ok?(version) do
    contents = DBStorage.list_contents(version.uuid)
    primary = LanguageHelpers.get_primary_language()

    row =
      Enum.find(contents, &(&1.language == primary)) ||
        Enum.find(contents, &(&1.language == LanguageHelpers.url_language_code(primary)))

    title = row && row.title
    is_binary(title) and String.trim(title) != "" and title != Constants.default_title()
  end

  # --- handler errors for failed resolutions (shared by every tool) ---------------------------

  @doc "Handler error for a failed `resolve_post/2`: `{:ok, hit}` passes through."
  def post_error({:ok, _} = ok), do: ok

  def post_error({:error, :invalid_ref}),
    do: Common.invalid("post", "give {id} or {group, slug}", "invalid_ref")

  def post_error({:error, {:post_trashed, _}}),
    do: Common.invalid("post", "the post is in the trash", "post_trashed")

  def post_error({:error, :not_found}), do: {:error, :not_found, "The post does not exist.", %{}}

  @doc "Handler error for `ensure_group_active/1`."
  def group_error(:ok), do: :ok

  def group_error({:error, :group_trashed}),
    do: Common.invalid("group", "the group is in the trash; restore it first", "group_trashed")

  @doc "Handler error for a failed `resolve_group/1`."
  def group_missing({:ok, _} = ok), do: ok

  def group_missing({:error, :not_found}),
    do: {:error, :not_found, "The group does not exist.", %{}}

  @doc "Handler error for a failed `resolve_version/3`."
  def version_error({:ok, _} = ok), do: ok

  def version_error({:error, :version_not_found}),
    do: Common.invalid("version", "the version does not exist", "version_not_found")

  def version_error({:error, :no_draft_version}),
    do:
      Common.invalid(
        "version",
        "the post has no draft version; call create_version first or name the version",
        "no_draft_version"
      )

  @doc "A category inside a group by its `id` and/or its `slug` (both must name the same one), over `categories!/1`."
  def resolve_category(ref, categories)

  def resolve_category(%{} = ref, categories) do
    keys = ref |> Map.keys() |> Enum.sort()

    case keys do
      ["id"] ->
        find(categories, &(&1.uuid == ref["id"]))

      ["slug"] ->
        find(categories, &(&1.slug == ref["slug"]))

      ["id", "slug"] ->
        with {:ok, by_id} <- find(categories, &(&1.uuid == ref["id"])),
             true <- by_id.slug == ref["slug"] do
          {:ok, by_id}
        else
          _ -> {:error, :invalid_ref}
        end

      _ ->
        {:error, :invalid_ref}
    end
  end

  def resolve_category(_other, _categories), do: {:error, :invalid_ref}

  defp find(categories, fun) do
    case Enum.find(categories, fun) do
      nil -> {:error, :not_found}
      category -> {:ok, category}
    end
  end
end
