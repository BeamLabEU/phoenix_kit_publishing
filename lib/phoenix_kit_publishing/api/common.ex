defmodule PhoenixKit.Modules.Publishing.API.Common do
  @moduledoc false
  # Helpers every publishing tool handler shares: write options, errors in the executor's
  # shape (spec §6.6), batch rows, the preview/fingerprint pair of a dry run, strict reads that
  # raise on a database error (spec §8), the bounded line diff of §9.12.

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Publishing.API.TextScan

  alias PhoenixKit.Modules.Publishing.{
    DBStorage,
    PublishingCategory,
    PublishingContent,
    PublishingGroup,
    PublishingPost,
    PublishingVersion,
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

    Keyword.merge(
      [actor_uuid: actor.user_uuid, activity_mode: "auto", scope: scope(ctx), log_metadata: meta],
      extra
    )
  end

  defp put_approver(meta, uuid) when is_binary(uuid), do: Map.put(meta, "approved_by_uuid", uuid)
  defp put_approver(meta, _none), do: meta

  @doc "The acting user's full-union scope (created_by / updated_by come from it), or nil when the user is gone."
  def scope(ctx) do
    case Auth.get_user(ctx.actor.user_uuid) do
      nil -> nil
      user -> Scope.for_user(user, narrow: false)
    end
  end

  # --- errors ----------------------------------------------------------------------------

  @doc "A request-level validation error in the executor's shape; `reason` is this module's convention."
  def invalid(path, message, reason \\ nil, extra \\ %{}) do
    error = Map.merge(%{path: path, message: message}, extra)
    error = if reason, do: Map.put(error, :reason, reason), else: error
    {:error, :validation_failed, message, %{errors: [error]}}
  end

  @doc "A module error as a handler error tuple."
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
    require Logger

    Logger.warning(
      "[Publishing.API] unclassified error: #{inspect(other, limit: 5, printable_limit: 200)}"
    )

    {:internal_error, nil, "The request could not be completed.", %{}}
  end

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
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      messages
      |> List.wrap()
      |> List.flatten()
      |> Enum.map(&%{path: to_string(field), message: &1})
    end)
  end

  defp interpolate_error({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      Enum.find_value(opts, key, &option_value(&1, key))
    end)
  end

  defp option_value({name, value}, key), do: if(Atom.to_string(name) == key, do: to_string(value))

  @doc """
  Checks a text field before any write: valid UTF-8, no NUL byte (Postgres would reject it and
  the write would surface as a 500), at most `:max` bytes (`:reason` names the reason of the
  over-long case, e.g. "content_too_large"). `nil` passes.
  """
  def check_text(_path, nil, _opts), do: :ok

  def check_text(path, value, opts) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        invalid(path, "must be valid UTF-8 text")

      String.contains?(value, <<0>>) ->
        invalid(path, "must not contain a NUL byte")

      byte_size(value) > Keyword.get(opts, :max, TextScan.max_body_bytes()) ->
        invalid(
          path,
          "is longer than #{Keyword.get(opts, :max)} bytes",
          Keyword.get(opts, :reason),
          %{limit: Keyword.get(opts, :max)}
        )

      true ->
        :ok
    end
  end

  def check_text(path, _other, _opts), do: invalid(path, "must be a string")

  # --- batch rows and previews -----------------------------------------------------------

  def row_ok(ref, action, id, extra \\ %{}),
    do: Map.merge(%{"ref" => ref, "action" => action, "id" => id}, extra)

  def row_error(ref, code, message, context \\ %{}),
    do: %{
      "ref" => ref,
      "action" => "error",
      "error" => %{"code" => to_string(code), "message" => message, "context" => context}
    }

  @doc "A batch row error from a module error: the row's code is the reason when there is one, else the core code."
  def row_from_error(ref, reason) do
    {code, why, message, context} = classify(reason)
    row_error(ref, why || code, message, stringify(Map.delete(context, :errors)))
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  def summary(rows), do: Enum.frequencies_by(rows, & &1["action"])
  def batch_result(rows), do: {:ok, %{"results" => rows, "summary" => summary(rows)}}

  @doc """
  A dry run's answer: the would-be rows and a fingerprint (`{:preview, preview, fingerprint}`).
  The fingerprint covers `fingerprint_term` when given (state plus hashes of the new values: it
  must never depend on the diff text, spec §9.12) and the rows otherwise.
  """
  def preview(rows, extra \\ %{}, fingerprint_term \\ nil),
    do:
      {:preview, Map.merge(extra, %{"rows" => rows, "summary" => summary(rows)}),
       fingerprint(fingerprint_term || rows)}

  @doc "The state of a post a tool depends on (spec §9.12): feeds the fingerprint of the post tools."
  def post_state(db_post, group, versions, contents) do
    {db_post.uuid, db_post.slug, db_post.trashed_at, db_post.active_version_uuid,
     db_post.post_date, db_post.post_time, group && group.status,
     Enum.map(versions, &{&1.version_number, &1.status, &1.published_at, fingerprint(&1.data)}),
     Enum.map(contents, &{&1.language, digest(&1.title, &1.content)})}
  end

  @doc "Adds the NAMES (never the values) of the changed fields to the API log metadata."
  def put_log_fields(opts, names),
    do: Keyword.update!(opts, :log_metadata, &Map.put(&1, "fields", names))

  @doc "A safe string for an error reason inside an answer: atoms by name, anything else a fixed word. Never `inspect`."
  def reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_text(_reason), do: "failed"

  @doc "The `if_revision` check (spec §9.12): the `revision` string of get_post must still be current."
  def check_revision(%{"if_revision" => expected}, db_post, version, content)
      when is_binary(expected) do
    current = post_revision(db_post, version, content)

    if current == expected,
      do: :ok,
      else:
        {:error, :revision_mismatch, "The post changed since it was read.",
         %{current_revision: current}}
  end

  def check_revision(_input, _db_post, _version, _content), do: :ok

  @doc "`SlugHelpers.validate_slug/1` as a handler error whose path is `path` (reasons: invalid_slug, reserved_language_code, reserved_route_word)."
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
  The og_* params of a write (F9): when ANY of og_title / og_description / og_image_id is present all
  three are sent, the unspecified ones taken from the current og of `content_row`; null clears.
  """
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

  def with_warnings(body, []), do: body
  def with_warnings(body, warnings), do: Map.put(body, "warnings", warnings)

  @doc "64 lowercase hex characters (core's cap). `updated_at` is never an input."
  def fingerprint(term), do: sha256(:erlang.term_to_binary(term, [:deterministic]))
  def sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  @doc ~S|A content row's digest; the length prefix keeps ("ab", "c") and ("a", "bc") apart.|
  def digest(title, content) do
    title = title || ""
    sha256(Integer.to_string(byte_size(title)) <> ":" <> title <> (content || ""))
  end

  @doc "The `if_revision` value (spec §9.4): values only, never `updated_at`."
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

  # --- strict reads (they raise on a database error, spec §8) -----------------------------

  @doc "All categories of a group in the module's order. The query of Categories.list_categories/1 WITHOUT its rescue."
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

  @doc "Published-post counts per category: the query of Categories.published_post_counts/1 WITHOUT its rescue."
  def published_post_counts!(group_slug) do
    from(p in PublishingPost,
      join: g in PublishingGroup,
      on: g.uuid == p.group_uuid,
      join: v in PublishingVersion,
      on: v.uuid == p.active_version_uuid,
      where: g.slug == ^group_slug and is_nil(p.trashed_at),
      select: {p.uuid, fragment("? -> 'category_uuids'", v.data)}
    )
    |> repo().all()
    |> Enum.reduce(%{}, fn {_post, uuids}, acc ->
      uuids
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.reduce(acc, fn uuid, inner -> Map.update(inner, uuid, 1, &(&1 + 1)) end)
    end)
  end

  @doc "`%{category_uuid => number of versions of the group that name it}`, one query for all uuids."
  def filed_versions_counts!(_group_slug, []), do: %{}

  def filed_versions_counts!(group_slug, uuids) do
    sql = """
    SELECT c.uuid_text, count(*)
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

  @doc "`false`, or `{true, :live | :trashed}`. Raises on a database error, unlike SlugHelpers.slug_exists?/2 (F21)."
  def slug_taken?(group_slug, slug) do
    cond do
      DBStorage.get_post(group_slug, slug) ->
        {true, :live}

      Enum.any?(DBStorage.list_posts(group_slug, "trashed"), &(&1.slug == slug)) ->
        {true, :trashed}

      true ->
        false
    end
  end

  # --- the :locked_check closure (spec §8) -------------------------------------------------

  @doc """
  The hook `Posts.update_post/4` runs under the post row lock. `live_fun.(locked_post, version)`
  recomputes the live-version condition of spec §8 from the two fresh rows. A trashed locked row
  is refused whatever the confirmation; an unconfirmed, non-dry call is refused with `:went_live`
  when the condition now holds; any exception fails closed.
  """
  def locked_check(ctx, live_fun) do
    confirmed? = Map.get(ctx, :confirmation_uuid) != nil
    dry? = Map.get(ctx, :dry_run?, false)

    fn locked, version ->
      try do
        cond do
          locked.trashed_at != nil -> {:error, :post_trashed}
          not confirmed? and not dry? and live_fun.(locked, version) -> {:error, :went_live}
          true -> :ok
        end
      rescue
        _ -> {:error, :locked_check_failed}
      catch
        _kind, _value -> {:error, :locked_check_failed}
      end
    end
  end

  # --- previews of a body change (spec §9.12) ------------------------------------------------

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
  def content_change(old, new) do
    %{
      "scope" => "language",
      "from_bytes" => byte_size(old),
      "to_bytes" => byte_size(new),
      "from_sha256" => sha256(old),
      "to_sha256" => sha256(new),
      "head" => String.slice(new, 0, 300),
      "tail" => String.slice(new, -300, 300),
      "diff" => line_diff(old, new),
      "added_urls" => added_urls(old, new),
      "raw_html" => TextScan.scan(new)
    }
  end

  @url_re ~r{\]\(\s*(https?://[^\s)]*)|\]:\s*(https?://\S*)}i

  defp hosts(text) do
    @url_re
    |> Regex.scan(text)
    |> Enum.flat_map(fn [_all | groups] -> Enum.reject(groups, &(&1 == "")) end)
    |> Enum.map(&(&1 |> URI.parse() |> Map.get(:host)))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp added_urls(old, new),
    do: new |> hosts() |> MapSet.difference(hosts(old)) |> Enum.sort() |> Enum.take(50)

  @doc ~S|A unified line diff, bounded (see spec §9.12): `%{"mode", "text", "hunks", "truncated"}` (+ line counts when coarse).|
  def line_diff(old, new) do
    old_lines = String.split(old, "\n")
    new_lines = String.split(new, "\n")
    {prefix, old_rest, new_rest} = common_prefix(old_lines, new_lines, 0)
    {suffix, rev_old, rev_new} = common_prefix(Enum.reverse(old_rest), Enum.reverse(new_rest), 0)
    old_mid = Enum.reverse(rev_old)
    new_mid = Enum.reverse(rev_new)

    cond do
      old_mid == [] and new_mid == [] ->
        line_result([])

      old_mid == [] or new_mid == [] or
          (length(old_mid) <= @myers_cap and length(new_mid) <= @myers_cap) ->
        before = old_lines |> Enum.take(prefix) |> Enum.take(-@context)
        after_ = old_lines |> Enum.take(-suffix) |> Enum.take(@context)

        ops =
          Enum.map(before, &{:eq, &1}) ++
            middle_ops(old_mid, new_mid) ++
            if(suffix == 0, do: [], else: Enum.map(after_, &{:eq, &1}))

        ops |> hunks(prefix - length(before) + 1) |> line_result()

      true ->
        coarse_result(old_mid, new_mid)
    end
  end

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
    head = lines |> Enum.take(@coarse_edge) |> Enum.map(&(sign <> &1))

    tail =
      if omitted > 0, do: lines |> Enum.take(-@coarse_edge) |> Enum.map(&(sign <> &1)), else: []

    marker = if omitted > 0, do: [sign <> "... #{omitted} lines omitted"], else: []
    head ++ marker ++ tail
  end

  defp common_prefix([h | a], [h | b], n), do: common_prefix(a, b, n + 1)
  defp common_prefix(a, b, n), do: {n, a, b}

  defp middle_ops([], new), do: Enum.map(new, &{:ins, &1})
  defp middle_ops(old, []), do: Enum.map(old, &{:del, &1})

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
