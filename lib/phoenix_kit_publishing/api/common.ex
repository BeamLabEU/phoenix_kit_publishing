defmodule PhoenixKit.Modules.Publishing.API.Common do
  @moduledoc false
  # Helpers every publishing tool handler shares: write options, errors in the executor's
  # shape, batch rows, the preview/fingerprint pair of a dry run, strict reads that raise on a
  # database error, and the bounded line diff.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Modules.Publishing.API.TextScan
  alias PhoenixKit.Modules.Publishing.Errors

  alias PhoenixKit.Modules.Publishing.{
    PublishingCategory,
    PublishingContent,
    PublishingGroup,
    PublishingPost,
    SlugHelpers
  }

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # --- who and how ---------------------------------------------------------------------

  @doc """
  The options every API write passes to the context functions. The activity mode travels in
  `:activity_mode`, NEVER `:mode` (`Groups.add_group/2` reads the group's URL mode from `:mode`).
  `extra` is merged over the defaults and adds only options the called function documents.

  The scope costs a user and a role query, so a handler calls this ONCE per request. A batch
  handler that needs the options per row builds them once and reuses them, or passes the scope it
  already has as `scope: scope` in `extra` (then no lookup is made).
  """
  @spec write_opts(map(), String.t(), keyword()) :: keyword()
  def write_opts(ctx, tool, extra \\ []) do
    actor = ctx.actor

    meta =
      %{
        "via" => "api",
        "key_prefix" => actor.key_prefix,
        "request_id" => ctx.request_id,
        "tool" => tool
      }
      |> put_approver(Map.get(ctx, :approved_by_uuid))

    [actor_uuid: actor.user_uuid, activity_mode: "auto", log_metadata: meta]
    |> Keyword.merge(extra)
    |> Keyword.put_new_lazy(:scope, fn -> scope(ctx) end)
  end

  defp put_approver(meta, uuid) when is_binary(uuid), do: Map.put(meta, "approved_by_uuid", uuid)
  defp put_approver(meta, _none), do: meta

  @doc "The acting user's full-union scope (created_by / updated_by come from it), or nil when the user is gone."
  @spec scope(map()) :: Scope.t() | nil
  def scope(ctx) do
    case Auth.get_user(ctx.actor.user_uuid) do
      nil -> nil
      user -> Scope.for_user(user, narrow: false)
    end
  end

  # --- errors ----------------------------------------------------------------------------

  @doc "A request-level validation error in the executor's shape; `reason` is this module's convention."
  @spec invalid(String.t(), String.t(), String.t() | nil, map()) ::
          {:error, :validation_failed, String.t(), map()}
  def invalid(path, message, reason \\ nil, extra \\ %{}) do
    error = Map.merge(%{path: path, message: message}, extra)
    error = if reason, do: Map.put(error, :reason, reason), else: error
    {:error, :validation_failed, message, %{errors: [error]}}
  end

  @doc "A module error as a handler error tuple."
  @spec error(term()) :: {:error, atom(), String.t(), map()}
  def error(reason) do
    {code, _reason, message, context} = classify(reason)
    {:error, code, message, context}
  end

  @not_found ~w(not_found post_not_found group_not_found resource_not_found no_post)a
  @version ~w(source_not_found invalid_version version_not_found)a
  @slug_taken ~w(slug_already_exists slug_taken already_exists conflicts_with_post_slug conflicts_with_previous_slug)a
  @invalid_slug ~w(invalid_slug invalid_format)a
  @same_name ~w(reserved_language_code reserved_route_word invalid_name invalid_mode invalid_type post_trashed
                category_cycle parent_not_found parent_wrong_group title_required)a
  @not_published ~w(not_published no_published_version)a
  @ai ~w(ai_disabled ai_no_prompt ai_endpoint_not_found ai_endpoint_disabled)a

  @doc """
  `{code, reason, message, context}`: `code` is a core error code, `reason` the validation
  reason (nil for none). Unclassified errors are `:internal_error` and the reason is logged,
  never returned.
  """
  @spec classify(term()) :: {atom(), String.t() | nil, String.t(), map()}
  def classify(reason) when reason in @not_found,
    do: {:not_found, nil, "The record does not exist.", %{}}

  def classify(reason) when reason in @version,
    do: reasoned("version_not_found", "The version does not exist.")

  def classify(reason) when reason in @slug_taken,
    do: reasoned("slug_taken", "The slug is already in use.")

  def classify(reason) when reason in @invalid_slug,
    do: reasoned("invalid_slug", "The slug is not valid.")

  def classify(reason) when reason in @same_name,
    do: reasoned(Atom.to_string(reason), sentence(reason))

  def classify(reason) when reason in @not_published,
    do: reasoned("not_published", "The post has no live version.")

  def classify(:timestamp_collision_unresolvable),
    do: reasoned("slot_taken", "No free minute slot is left on that date.")

  def classify(reason) when reason in @ai,
    do: reasoned("ai_not_configured", "AI translation is not configured.")

  def classify(:went_live),
    do:
      {:revision_mismatch, nil, "The version went live; repeat the call to get a confirmation.",
       %{reason: "went_live"}}

  def classify(:locked_check_failed) do
    Logger.warning("[Publishing.API] the locked check raised; the write was refused")
    {:internal_error, nil, "The request could not be completed.", %{}}
  end

  def classify(%Ecto.Changeset{} = changeset) do
    names = constraint_names(changeset)

    cond do
      "idx_publishing_posts_group_slug" in names ->
        reasoned("slug_taken", "The slug is already in use.")

      "idx_publishing_posts_group_date_time_unique" in names ->
        reasoned("slot_taken", "That date and time slot is taken.")

      true ->
        {:validation_failed, nil, "The data is not valid.",
         %{errors: changeset_errors(changeset)}}
    end
  end

  def classify(other) do
    Logger.warning("[Publishing.API] unclassified error: #{log_tag(other)}")

    {:internal_error, nil, "The request could not be completed.", %{}}
  end

  # What may be logged about an unknown error: its shape and tag, never its payload (it can hold
  # request text or an upstream response body).
  defp log_tag(reason) when is_atom(reason),
    do: Errors.truncate_for_log(Atom.to_string(reason), 80)

  defp log_tag(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> "{" <> Errors.truncate_for_log(Atom.to_string(tag), 80) <> ", ...}"
      _other -> "tuple"
    end
  end

  defp log_tag(%module{}), do: "%" <> Errors.truncate_for_log(inspect(module), 80) <> "{}"
  defp log_tag(reason) when is_binary(reason), do: "string"
  defp log_tag(reason) when is_map(reason), do: "map"
  defp log_tag(reason) when is_list(reason), do: "list"
  defp log_tag(_reason), do: "term"

  defp reasoned(reason, message),
    do:
      {:validation_failed, reason, message,
       %{errors: [%{path: "", message: message, reason: reason}]}}

  defp sentence(:post_trashed), do: "The post is in the trash."
  defp sentence(:title_required), do: "The primary-language title is required."

  defp sentence(reason),
    do:
      reason
      |> Atom.to_string()
      |> String.replace("_", " ")
      |> String.capitalize()
      |> Kernel.<>(".")

  defp constraint_names(%Ecto.Changeset{errors: errors}) do
    for {_field, {_msg, opts}} <- errors,
        name = Keyword.get(opts, :constraint_name),
        do: to_string(name)
  end

  @doc ~S|A changeset's errors as `[%{path: field, message: text}]`, options interpolated, never `inspect`.|
  @spec changeset_errors(Ecto.Changeset.t()) :: [%{path: String.t(), message: String.t()}]
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate_error/1)
    |> flatten_errors(nil)
  end

  # Nested embeds and associations give maps (and lists of maps) of messages; the path of a
  # nested error is the dotted field chain.
  defp flatten_errors(errors, path) when is_map(errors) do
    Enum.flat_map(errors, fn {field, value} -> flatten_errors(value, join_path(path, field)) end)
  end

  defp flatten_errors(errors, path) when is_list(errors),
    do: Enum.flat_map(errors, &flatten_errors(&1, path))

  defp flatten_errors(message, path) when is_binary(message),
    do: [%{path: path || "", message: message}]

  defp join_path(nil, field), do: to_string(field)
  defp join_path(path, field), do: path <> "." <> to_string(field)

  defp interpolate_error({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn placeholder, key ->
      Enum.find_value(opts, placeholder, &option_value(&1, key))
    end)
  end

  defp option_value({name, value}, key), do: if(Atom.to_string(name) == key, do: to_string(value))

  @doc """
  Checks a text field before any write: valid UTF-8, no NUL byte (Postgres would reject it and
  the write would surface as a 500), and a length limit. `:max_chars` limits the length in
  characters (short fields such as titles); otherwise `:max` limits it in bytes (default: the
  body cap, whose over-long reason is "content_too_large"). `:reason` overrides the reason of an
  over-long value. `nil` passes.
  """
  @spec check_text(String.t(), term(), keyword()) ::
          :ok | {:error, :validation_failed, String.t(), map()}
  def check_text(_path, nil, _opts), do: :ok

  def check_text(path, value, opts) when is_binary(value) do
    cond do
      not String.valid?(value) -> invalid(path, "must be valid UTF-8 text")
      String.contains?(value, <<0>>) -> invalid(path, "must not contain a NUL byte")
      true -> check_length(path, value, opts)
    end
  end

  def check_text(path, _other, _opts), do: invalid(path, "must be a string")

  defp check_length(path, value, opts) do
    {size, max, unit, default_reason} =
      case Keyword.fetch(opts, :max_chars) do
        {:ok, max} ->
          {String.length(value), max, "characters", nil}

        :error ->
          case Keyword.fetch(opts, :max) do
            {:ok, max} -> {byte_size(value), max, "bytes", nil}
            :error -> {byte_size(value), TextScan.max_body_bytes(), "bytes", "content_too_large"}
          end
      end

    if size > max,
      do:
        invalid(
          path,
          "is longer than #{max} #{unit}",
          Keyword.get(opts, :reason, default_reason),
          %{limit: max}
        ),
      else: :ok
  end

  @doc """
  An image id field (a media file UUID; `null` or "" clears), stored in canonical (lowercase)
  form. An absent field passes. A file that is not in the media library, is trashed or is a
  system file (tile chunks, hidden originals) is `unknown_file`: a dangling id would be accepted
  silently, and any library file could be attached.
  """
  @spec canonical_image_id(map(), String.t()) ::
          {:ok, map()} | {:error, :validation_failed, String.t(), map()}
  def canonical_image_id(input, field) do
    case Map.fetch(input, field) do
      :error ->
        {:ok, input}

      {:ok, empty} when empty in [nil, ""] ->
        {:ok, input}

      {:ok, value} when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> existing_file(input, field, uuid)
          :error -> invalid(field, "must be a media file id (UUID) or null")
        end

      {:ok, _other} ->
        invalid(field, "must be a string")
    end
  end

  defp existing_file(input, field, uuid) do
    case PhoenixKit.Modules.Storage.get_file(uuid) do
      %{status: status, system_managed: false} when status != "trashed" ->
        {:ok, Map.put(input, field, uuid)}

      _missing_or_hidden ->
        invalid(field, "is not a file of the media library", "unknown_file")
    end
  end

  # --- batch rows and previews -----------------------------------------------------------

  @spec row_ok(term(), String.t(), term(), map()) :: map()
  def row_ok(ref, action, id, extra \\ %{}),
    do: Map.merge(%{"ref" => ref, "action" => action, "id" => id}, extra)

  @spec row_error(term(), atom() | String.t(), String.t(), map()) :: map()
  def row_error(ref, code, message, context \\ %{}),
    do: %{
      "ref" => ref,
      "action" => "error",
      "error" => %{"code" => to_string(code), "message" => message, "context" => context}
    }

  @doc "A batch row error from a module error: the row's code is the reason when there is one, else the core code."
  @spec row_from_error(term(), term()) :: map()
  def row_from_error(ref, reason) do
    {code, why, message, context} = classify(reason)
    {errors, context} = Map.pop(context, :errors, [])

    context =
      if why == nil and errors != [],
        do: Map.put(context, :errors, Enum.map(errors, &stringify/1)),
        else: context

    row_error(ref, why || code, message, stringify(context))
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  @spec summary([map()]) :: %{optional(String.t()) => pos_integer()}
  def summary(rows), do: Enum.frequencies_by(rows, & &1["action"])
  @spec batch_result([map()]) :: {:ok, map()}
  def batch_result(rows), do: {:ok, %{"results" => rows, "summary" => summary(rows)}}

  @doc """
  A dry run's answer: the would-be rows and a fingerprint (`{:preview, preview, fingerprint}`).
  The fingerprint covers `fingerprint_term` when given (state plus hashes of the new values: it
  must never depend on the diff text) and the rows otherwise.
  """
  @spec preview([map()], map(), term()) :: {:preview, map(), String.t()}
  def preview(rows, extra \\ %{}, fingerprint_term \\ nil),
    do:
      {:preview, Map.merge(extra, %{"rows" => rows, "summary" => summary(rows)}),
       fingerprint(fingerprint_term || rows)}

  @doc "The state of a post a tool depends on: feeds the fingerprint of the post tools."
  @spec post_state(map(), map() | nil, [map()], [map()]) :: tuple()
  def post_state(db_post, group, versions, contents) do
    {db_post.uuid, db_post.slug, db_post.trashed_at, db_post.active_version_uuid,
     db_post.post_date, db_post.post_time, group && group.status,
     Enum.map(versions, &{&1.version_number, &1.status, &1.published_at, fingerprint(&1.data)}),
     Enum.map(contents, &{&1.language, digest(&1.title, &1.content)})}
  end

  @doc "Adds the NAMES (never the values) of the changed fields to the API log metadata."
  @spec put_log_fields(keyword(), [String.t()]) :: keyword()
  def put_log_fields(opts, names),
    do: Keyword.update!(opts, :log_metadata, &Map.put(&1, "fields", names))

  @doc "A safe string for an error reason inside an answer: atoms by name, anything else a fixed word. Never `inspect`."
  @spec reason_text(term()) :: String.t()
  def reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_text(_reason), do: "failed"

  @doc "The `if_revision` check: the `revision` string of get_post must still be current. A value that is not that string (any other type) never matches."
  @spec check_revision(map(), map(), map() | nil, map() | nil) ::
          :ok | {:error, :revision_mismatch, String.t(), map()}
  def check_revision(%{"if_revision" => expected}, db_post, version, content)
      when not is_nil(expected) do
    current = post_revision(db_post, version, content)

    if current == expected,
      do: :ok,
      else:
        {:error, :revision_mismatch, "The post changed since it was read.",
         %{current_revision: current}}
  end

  def check_revision(_input, _db_post, _version, _content), do: :ok

  @doc "`SlugHelpers.validate_slug/1` as a handler error whose path is `path` (reasons: invalid_slug, reserved_language_code, reserved_route_word)."
  @spec validate_slug(term(), String.t()) ::
          {:ok, String.t()} | {:error, atom(), String.t(), map()}
  def validate_slug(slug, path \\ "slug") do
    case SlugHelpers.validate_slug(slug) do
      {:ok, slug} ->
        {:ok, slug}

      {:error, reason} ->
        {:error, code, message, %{errors: [error | rest]} = context} = error(reason)
        {:error, code, message, %{context | errors: [%{error | path: path} | rest]}}
    end
  end

  @doc """
  The og_* params of a write: when ANY of og_title / og_description / og_image_id is present all
  three are sent, the unspecified ones taken from the current og of `content_row`; null clears.
  """
  @spec og_params(map(), map() | nil) :: map()
  def og_params(input, content_row) do
    keys = ~w(og_title og_description og_image_id)

    if Enum.any?(keys, &Map.has_key?(input, &1)) do
      og = (content_row && PublishingContent.get_og(content_row)) || %{}

      %{
        "og_title" => og_value(input, "og_title", og["title"]),
        "og_description" => og_value(input, "og_description", og["description"]),
        "og_image_uuid" => og_value(input, "og_image_id", og["image_uuid"])
      }
    else
      %{}
    end
  end

  defp og_value(input, key, current),
    do: if(Map.has_key?(input, key), do: input[key] || "", else: current || "")

  @spec with_warnings(map(), list()) :: map()
  def with_warnings(body, []), do: body
  def with_warnings(body, warnings), do: Map.put(body, "warnings", warnings)

  @doc "64 lowercase hex characters (core's cap). `updated_at` is never an input."
  @spec fingerprint(term()) :: String.t()
  def fingerprint(term), do: sha256(:erlang.term_to_binary(term, [:deterministic]))
  @spec sha256(binary()) :: String.t()
  def sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  @doc ~S|A content row's digest; the length prefix keeps ("ab", "c") and ("a", "bc") apart.|
  @spec digest(String.t() | nil, String.t() | nil) :: String.t()
  def digest(title, content) do
    title = title || ""
    sha256(Integer.to_string(byte_size(title)) <> ":" <> title <> (content || ""))
  end

  @doc "The `if_revision` value: values only, never `updated_at`."
  @spec post_revision(map(), map() | nil, map() | nil) :: String.t()
  def post_revision(db_post, version, content) do
    fingerprint({
      db_post.uuid,
      db_post.slug,
      db_post.trashed_at,
      db_post.active_version_uuid,
      db_post.post_date,
      db_post.post_time,
      version &&
        {version.version_number, version.status, version.published_at, fingerprint(version.data)},
      content && {content.language, digest(content.title, content.content)}
    })
  end

  # --- strict reads (they raise on a database error) -----------------------------

  @doc "All categories of a group in the module's order. The query of Categories.list_categories/1 WITHOUT its rescue."
  @spec categories!(String.t()) :: [PublishingCategory.t()]
  def categories!(group_slug) do
    from(c in PublishingCategory,
      join: g in PublishingGroup,
      on: g.uuid == c.group_uuid,
      where: g.slug == ^group_slug,
      order_by: [asc: c.position, asc: c.name]
    )
    |> repo().all()
  end

  @doc "`[{category, depth}]` in tree order, computed in memory over `categories!/1` (the algorithm of Categories.list_tree/1)."
  @spec category_tree!(String.t()) :: [{PublishingCategory.t(), non_neg_integer()}]
  def category_tree!(group_slug) do
    categories = categories!(group_slug)
    by_parent = Enum.group_by(categories, & &1.parent_uuid)
    known = MapSet.new(categories, & &1.uuid)

    roots =
      Enum.filter(
        categories,
        &(is_nil(&1.parent_uuid) or not MapSet.member?(known, &1.parent_uuid))
      )

    walk(roots, by_parent, 0, %{})
  end

  defp walk(nodes, by_parent, depth, seen) do
    Enum.flat_map(nodes, fn node ->
      if Map.has_key?(seen, node.uuid),
        do: [],
        else: [
          {node, depth}
          | walk(
              Map.get(by_parent, node.uuid, []),
              by_parent,
              depth + 1,
              Map.put(seen, node.uuid, true)
            )
        ]
    end)
  end

  @doc """
  Published-post counts per category (a post counts once per category, by its live version), the
  numbers of Categories.published_post_counts/1 WITHOUT its rescue, grouped in the database: one
  row per category comes back, not one per post.
  """
  @spec published_post_counts!(String.t()) :: %{optional(String.t()) => pos_integer()}
  def published_post_counts!(group_slug) do
    sql = """
    SELECT c.item #>> '{}', count(DISTINCT p.uuid)
    FROM phoenix_kit_publishing_posts p
    JOIN phoenix_kit_publishing_groups g ON g.uuid = p.group_uuid
    JOIN phoenix_kit_publishing_versions v ON v.uuid = p.active_version_uuid,
    jsonb_array_elements(CASE jsonb_typeof(v.data -> 'category_uuids')
                           WHEN 'array' THEN v.data -> 'category_uuids'
                           WHEN 'string' THEN jsonb_build_array(v.data -> 'category_uuids')
                           ELSE '[]'::jsonb END) AS c(item)
    WHERE g.slug = $1 AND p.trashed_at IS NULL AND jsonb_typeof(c.item) = 'string'
    GROUP BY c.item #>> '{}'
    """

    repo().query!(sql, [group_slug]).rows |> Map.new(fn [uuid, count] -> {uuid, count} end)
  end

  @doc """
  `%{"post_count" => posts that are not trashed, "live_posts" => those with a live version}` of a
  group, counted in one query.
  """
  @spec group_post_counts!(String.t()) :: %{String.t() => non_neg_integer()}
  def group_post_counts!(group_slug) do
    {posts, live} =
      from(p in PublishingPost,
        join: g in PublishingGroup,
        on: g.uuid == p.group_uuid,
        where: g.slug == ^group_slug and is_nil(p.trashed_at),
        select: {count(p.uuid), count(p.active_version_uuid)}
      )
      |> repo().one()

    %{"post_count" => posts, "live_posts" => live}
  end

  @doc "`%{category_uuid => number of versions of the group that name it}`, one query for all uuids."
  @spec filed_versions_counts!(String.t(), [String.t()]) :: %{
          optional(String.t()) => pos_integer()
        }
  def filed_versions_counts!(_group_slug, []), do: %{}

  def filed_versions_counts!(group_slug, uuids) do
    sql = """
    SELECT c.uuid_text, count(DISTINCT v.uuid)
    FROM phoenix_kit_publishing_versions v
    JOIN phoenix_kit_publishing_posts p ON p.uuid = v.post_uuid
    JOIN phoenix_kit_publishing_groups g ON g.uuid = p.group_uuid,
    jsonb_array_elements_text(CASE WHEN jsonb_typeof(v.data -> 'category_uuids') = 'array'
                                   THEN v.data -> 'category_uuids' ELSE '[]'::jsonb END) AS c(uuid_text)
    WHERE g.slug = $1 AND c.uuid_text = ANY($2)
    GROUP BY c.uuid_text
    """

    repo().query!(sql, [group_slug, uuids]).rows |> Map.new(fn [uuid, count] -> {uuid, count} end)
  end

  @doc "`false`, or `{true, :live | :trashed}`. Raises on a database error, unlike SlugHelpers.slug_exists?/2, which rescues to false."
  @spec slug_taken?(String.t(), String.t()) :: false | {true, :live | :trashed}
  def slug_taken?(group_slug, slug) do
    cond do
      slug_row?(group_slug, slug, true) -> {true, :live}
      slug_row?(group_slug, slug, false) -> {true, :trashed}
      true -> false
    end
  end

  defp slug_row?(group_slug, slug, live?) do
    query =
      from(p in PublishingPost,
        join: g in PublishingGroup,
        on: g.uuid == p.group_uuid,
        where: g.slug == ^group_slug and p.slug == ^slug
      )

    query =
      if live?,
        do: from(p in query, where: is_nil(p.trashed_at)),
        else: from(p in query, where: not is_nil(p.trashed_at))

    repo().exists?(query)
  end

  # --- the :locked_check closure -------------------------------------------------

  @doc """
  The hook `Posts.update_post/4` runs under the post row lock. `live_fun.(locked_post, version)`
  recomputes the live-version condition from the two fresh rows. A trashed locked row
  is refused whatever the confirmation; an unconfirmed, non-dry call is refused with `:went_live`
  unless the function answers exactly `false` (any doubtful answer counts as live); any exception
  or throw fails closed.
  """
  @spec locked_check(map(), (map(), map() -> term())) :: (map(), map() -> :ok | {:error, atom()})
  def locked_check(ctx, live_fun) do
    confirmed? = Map.get(ctx, :confirmation_uuid) != nil
    dry? = Map.get(ctx, :dry_run?, false)

    fn locked, version ->
      try do
        cond do
          locked.trashed_at != nil -> {:error, :post_trashed}
          confirmed? or dry? -> :ok
          live_fun.(locked, version) == false -> :ok
          true -> {:error, :went_live}
        end
      rescue
        _ -> {:error, :locked_check_failed}
      catch
        _kind, _value -> {:error, :locked_check_failed}
      end
    end
  end

  # --- previews of a body change ------------------------------------------------

  @myers_cap 400
  @diff_bytes 4096
  @line_clip 300
  @context 2
  @coarse_edge 10

  @doc """
  The `content` object of an `update_post` / `set_translation` / `create_post` preview row:
  sizes, hashes, head, tail, the bounded line diff, and facts computed over the WHOLE new body
  (`added_urls`, `raw_html`), because a coarse or truncated diff can miss a harmful hunk.
  """
  @spec content_change(String.t() | nil, String.t()) :: map()
  def content_change(old, new) do
    old = old || ""
    {added_urls, urls_truncated?} = added_urls(old, new)

    %{
      "scope" => "language",
      "from_bytes" => byte_size(old),
      "to_bytes" => byte_size(new),
      "from_sha256" => sha256(old),
      "to_sha256" => sha256(new),
      "head" => String.slice(new, 0, 300),
      "tail" => String.slice(new, -300, 300),
      "diff" => line_diff(old, new),
      "added_urls" => added_urls,
      "added_urls_truncated" => urls_truncated?,
      "raw_html" => TextScan.scan(new)
    }
  end

  # Every http(s) URL anywhere in the body (autolinks, angle-bracket destinations, bare URLs,
  # reference definitions, raw attributes) plus scheme-relative `//host` destinations, which are
  # external links too. Advice for the approver, so it errs on the side of listing more.
  @absolute_url_re ~r{https?://[^\s<>()\[\]"'`\\]+}i
  @relative_url_re ~r{(?:\]\(|\]:)\s*<?\s*(//[^\s<>()\[\]"'`\\]+)}
  @max_added_urls 50

  defp hosts(text) do
    absolute = @absolute_url_re |> Regex.scan(text) |> Enum.map(&hd/1)
    relative = @relative_url_re |> Regex.scan(text) |> Enum.map(&Enum.at(&1, 1))

    (absolute ++ relative)
    |> Enum.map(&url_host/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  # Hosts compare case-insensitively; sentence punctuation glued to a bare URL is not part of it.
  defp url_host(url) do
    (URI.parse(url).host || "")
    |> String.replace(~r/[,;!*].*\z/s, "")
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp added_urls(old, new) do
    added = new |> hosts() |> MapSet.difference(hosts(old)) |> Enum.sort()
    {Enum.take(added, @max_added_urls), length(added) > @max_added_urls}
  end

  @doc ~S|A unified line diff, bounded: `%{"mode", "text", "hunks", "truncated"}` (+ line counts when coarse).|
  @spec line_diff(String.t(), String.t()) :: map()
  def line_diff(old, new) do
    old_lines = split_lines(old)
    new_lines = split_lines(new)
    {prefix, old_rest, new_rest} = common_prefix(old_lines, new_lines, 0)
    {suffix, rev_old, rev_new} = common_prefix(Enum.reverse(old_rest), Enum.reverse(new_rest), 0)
    old_mid = Enum.reverse(rev_old)
    new_mid = Enum.reverse(rev_new)
    before = old_lines |> Enum.take(prefix) |> Enum.take(-@context)
    after_ = if suffix == 0, do: [], else: old_lines |> Enum.take(-suffix) |> Enum.take(@context)
    first_line = prefix - length(before) + 1

    cond do
      old_mid == [] and new_mid == [] ->
        line_result([])

      old_mid == [] or new_mid == [] ->
        line_result([one_sided_hunk(before, old_mid, new_mid, after_, first_line)])

      length(old_mid) <= @myers_cap and length(new_mid) <= @myers_cap ->
        ops =
          Enum.map(before, &{:eq, &1}) ++
            middle_ops(old_mid, new_mid) ++ Enum.map(after_, &{:eq, &1})

        ops |> hunks(first_line) |> line_result()

      true ->
        coarse_result(old_mid, new_mid)
    end
  end

  # An empty body has no lines (String.split("", "\n") is [""], a phantom empty line).
  defp split_lines(""), do: []
  defp split_lines(text), do: String.split(text, "\n")

  # A pure insertion or deletion is ONE hunk. Only as many changed lines as can fit the output cap
  # are built (every line costs at least two bytes), so a body of 260,000 new lines is not
  # turned into 260,000 strings; the header carries the real counts.
  defp one_sided_hunk(before, old_mid, new_mid, after_, first_line) do
    {tag, changed} = if old_mid == [], do: {:ins, new_mid}, else: {:del, old_mid}
    shown = Enum.take(changed, div(@diff_bytes, 2) + 1)

    entries =
      Enum.map(before, &{:eq, &1}) ++
        Enum.map(shown, &{tag, &1}) ++ Enum.map(after_, &{:eq, &1})

    context = length(before) + length(after_)
    old_len = context + length(old_mid)
    new_len = context + length(new_mid)

    {"@@ -#{hunk_start(first_line, old_len)},#{old_len} +#{hunk_start(first_line, new_len)},#{new_len} @@",
     Enum.map(entries, fn {tag, line} -> prefix(tag) <> clip(line) end)}
  end

  # An empty range is positioned at the line before it (unified diff convention).
  defp hunk_start(first_line, 0), do: first_line - 1
  defp hunk_start(first_line, _len), do: first_line

  # Both middles are too big for a diff: the edges of each, with the omitted count between.
  defp coarse_result(old_mid, new_mid) do
    lines = ["@@ coarse @@"] ++ coarse_edge(old_mid, "-") ++ coarse_edge(new_mid, "+")
    {text, _cut} = cap(lines)

    %{
      "mode" => "coarse",
      "text" => text,
      "hunks" => 1,
      "truncated" => true,
      "old_lines" => length(old_mid),
      "new_lines" => length(new_mid)
    }
  end

  defp coarse_edge(lines, sign) do
    omitted = max(length(lines) - 2 * @coarse_edge, 0)
    head = lines |> Enum.take(@coarse_edge) |> Enum.map(&(sign <> clip(&1)))

    tail =
      if omitted > 0,
        do: lines |> Enum.take(-@coarse_edge) |> Enum.map(&(sign <> clip(&1))),
        else: []

    marker = if omitted > 0, do: [sign <> "... #{omitted} lines omitted"], else: []
    head ++ marker ++ tail
  end

  defp common_prefix([h | a], [h | b], n), do: common_prefix(a, b, n + 1)
  defp common_prefix(a, b, n), do: {n, a, b}

  defp middle_ops(old, new) do
    old
    |> List.myers_difference(new)
    |> Enum.flat_map(fn {tag, lines} -> Enum.map(lines, &{tag, &1}) end)
  end

  # Hunks of changed ops with @context lines around them: a list of `{header, lines}`.
  defp hunks(ops, first_line) do
    total = length(ops)
    changed = for {{tag, _line}, i} <- Enum.with_index(ops), tag != :eq, do: i

    keep =
      changed
      |> Enum.flat_map(fn i ->
        Enum.to_list(max(i - @context, 0)..min(i + @context, total - 1))
      end)
      |> Enum.uniq()
      |> Enum.sort()

    {positions, _} =
      Enum.map_reduce(ops, {first_line, first_line}, fn {tag, _line}, {o, n} ->
        {{o, n}, step(tag, o, n)}
      end)

    positions = List.to_tuple(positions)
    ops = List.to_tuple(ops)

    keep
    |> Enum.chunk_while(
      [],
      fn i, run ->
        case run do
          [last | _] when i != last + 1 -> {:cont, Enum.reverse(run), [i]}
          _ -> {:cont, [i | run]}
        end
      end,
      fn run -> {:cont, Enum.reverse(run), []} end
    )
    |> Enum.reject(&(&1 == []))
    |> Enum.map(&build_hunk(&1, ops, positions))
  end

  defp step(:eq, o, n), do: {o + 1, n + 1}
  defp step(:del, o, n), do: {o + 1, n}
  defp step(:ins, o, n), do: {o, n + 1}

  defp build_hunk([first | _] = run, ops, positions) do
    {o, n} = elem(positions, first)
    entries = Enum.map(run, &elem(ops, &1))
    old_len = Enum.count(entries, fn {tag, _} -> tag in [:eq, :del] end)
    new_len = Enum.count(entries, fn {tag, _} -> tag in [:eq, :ins] end)

    {"@@ -#{o},#{old_len} +#{n},#{new_len} @@",
     Enum.map(entries, fn {tag, line} -> prefix(tag) <> clip(line) end)}
  end

  defp prefix(:eq), do: " "
  defp prefix(:del), do: "-"
  defp prefix(:ins), do: "+"

  defp clip(line) do
    if String.length(line) > @line_clip,
      do: String.slice(line, 0, @line_clip) <> "... (+#{String.length(line) - @line_clip} chars)",
      else: line
  end

  defp line_result(hunks) do
    lines = Enum.flat_map(hunks, fn {header, lines} -> [header | lines] end)
    {text, cut?} = cap(lines)
    %{"mode" => "line", "text" => text, "hunks" => length(hunks), "truncated" => cut?}
  end

  # Joins lines up to @diff_bytes, cut at a line boundary; a line longer than the cap on its own
  # is already clipped by clip/1.
  defp cap(lines) do
    {kept, _size, cut?} =
      Enum.reduce_while(lines, {[], 0, false}, fn line, {acc, size, _} ->
        next = size + byte_size(line) + 1

        if next > @diff_bytes,
          do: {:halt, {acc, size, true}},
          else: {:cont, {[line | acc], next, false}}
      end)

    {kept |> Enum.reverse() |> Enum.join("\n"), cut?}
  end
end
