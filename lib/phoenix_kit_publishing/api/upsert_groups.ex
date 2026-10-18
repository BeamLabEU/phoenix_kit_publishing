defmodule PhoenixKit.Modules.Publishing.API.UpsertGroups do
  @moduledoc false
  # Tool `publishing.upsert_groups`.

  alias PhoenixKit.Modules.Publishing.API.{Common, Refs}
  alias PhoenixKit.Modules.Publishing.{Constants, DBStorage, Groups, GroupSettings}

  @tool "publishing.upsert_groups"

  # Fixed at creation: {key, the row error code of a different value}.
  @locked [
    {"mode", "mode_locked"},
    {"type", "immutable_field"},
    {"item_singular", "immutable_field"},
    {"item_plural", "immutable_field"}
  ]

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    plan = plan(input["groups"])
    if Map.get(ctx, :dry_run?, false), do: preview(plan), else: execute(plan, ctx)
  end

  @doc false
  # [{:create, ref, row} | {:update, ref, group, params, fields} | {:unchanged, ref, group}
  #  | {:error, ref, error_row}]. Reads are strict: a database error raises (the danger function
  # turns it into `true`).
  def plan(rows) do
    {entries, _seen} = Enum.map_reduce(rows, MapSet.new(), &plan_row/2)
    entries
  end

  defp plan_row(%{"slug" => slug} = row, seen) when is_binary(slug) do
    ref = %{"slug" => slug}

    if MapSet.member?(seen, slug) do
      error = Common.row_error(ref, "invalid_ref", "the same group appears twice in the request")
      {{:error, ref, error}, seen}
    else
      {classify(row, ref, Refs.resolve_group(slug)), MapSet.put(seen, slug)}
    end
  end

  defp plan_row(other, seen),
    do: {{:error, other, Common.row_error(other, "invalid_ref", "a row needs a slug")}, seen}

  defp classify(row, ref, {:error, :not_found}), do: create_entry(row, ref)

  defp classify(_row, ref, {:ok, %{status: "trashed"}}),
    do:
      {:error, ref,
       Common.row_error(ref, "group_trashed", "the group is in the trash; restore it first")}

  defp classify(row, ref, {:ok, db_group}) do
    case Groups.fetch_group(db_group.slug) do
      {:ok, group} ->
        update_entry(row, ref, group)

      {:error, :not_found} ->
        {:error, ref, Common.row_error(ref, "not_found", "The group does not exist.")}
    end
  end

  defp create_entry(row, ref) do
    with {:ok, _slug} <- slug_error(Common.validate_slug(row["slug"])),
         :ok <- check_fields(row),
         :ok <- new_mode(row["mode"]),
         {:ok, name} <- new_name(row),
         {:ok, flat} <- settings(row["settings"]) do
      attrs =
        row
        |> Map.take(~w(slug mode type item_singular item_plural name_i18n))
        |> Map.merge(%{"name" => name, "flat_settings" => flat})

      {:create, ref, attrs}
    else
      {:error, code, message} -> {:error, ref, Common.row_error(ref, code, message)}
    end
  end

  # Common.validate_slug/2 answers a handler error; a row wants its reason as the code.
  defp slug_error({:ok, slug}), do: {:ok, slug}

  defp slug_error({:error, :validation_failed, message, %{errors: [%{reason: reason} | _]}}),
    do: {:error, reason, message}

  # add_group/2 would quietly fall back to the default mode for a mode it does not know.
  defp new_mode(nil), do: :ok

  defp new_mode(mode) do
    if mode in Constants.valid_modes(),
      do: :ok,
      else:
        {:error, "invalid_mode",
         "the mode must be one of: " <> Enum.join(Constants.valid_modes(), ", ")}
  end

  defp new_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, "invalid_name", "the name must not be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp new_name(_row), do: {:error, "invalid_name", "a new group needs a name"}

  # Text fields are checked before any write: a NUL byte or invalid UTF-8 would make Postgres
  # raise, and a value over the column width would only fail at the write.
  defp check_fields(row) do
    with :ok <- check_text("name", row["name"], Constants.max_group_name_length()),
         :ok <- check_text("mode", row["mode"], 20),
         :ok <- check_text("type", row["type"], 50),
         :ok <- check_text("item_singular", row["item_singular"], 100),
         :ok <- check_text("item_plural", row["item_plural"], 100),
         do: check_name_i18n(row)
  end

  defp check_name_i18n(row) do
    case Map.fetch(row, "name_i18n") do
      :error -> :ok
      {:ok, map} when is_map(map) -> Enum.find_value(map, :ok, &check_i18n_entry/1)
      {:ok, _other} -> {:error, "validation_failed", "name_i18n must be an object"}
    end
  end

  # `nil` for an acceptable entry, so `Enum.find_value/3` stops at the first error.
  defp check_i18n_entry({key, value}) do
    with :ok <- check_text("name_i18n key", key, Constants.max_language_code_length()),
         :ok <- check_i18n_value(value) do
      nil
    end
  end

  defp check_i18n_value(value) when is_binary(value),
    do: check_text("name_i18n value", value, Constants.max_group_name_length())

  defp check_i18n_value(_value),
    do: {:error, "validation_failed", "name_i18n values must be strings"}

  defp check_text(path, value, max) do
    case Common.check_text(path, value, max_chars: max) do
      :ok -> :ok
      {:error, _code, message, _context} -> {:error, "validation_failed", path <> " " <> message}
    end
  end

  # GroupSettings.validate_params/1 runs BEFORE any call: the module silently drops a wrong enum.
  defp settings(nil), do: {:ok, %{}}

  defp settings(map) when is_map(map) do
    case GroupSettings.validate_params(map) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, [%{key: key} | _]} ->
        {:error, "invalid_setting", "invalid value for the setting #{key}"}
    end
  end

  defp settings(_other), do: {:error, "invalid_setting", "settings must be an object"}

  defp update_entry(row, ref, group) do
    with :ok <- check_fields(row),
         :ok <- blank_name(row),
         :ok <- locked(row, group),
         {:ok, flat} <- settings(row["settings"]) do
      params = row |> Map.take(~w(name name_i18n)) |> trim_name() |> Map.merge(flat)

      case changed_fields(params, group) do
        [] -> {:unchanged, ref, group}
        fields -> {:update, ref, group, Map.take(params, fields), fields}
      end
    else
      {:error, code, message} -> {:error, ref, Common.row_error(ref, code, message)}
    end
  end

  defp blank_name(%{"name" => name}) when is_binary(name) do
    if String.trim(name) == "",
      do: {:error, "invalid_name", "the name must not be blank"},
      else: :ok
  end

  defp blank_name(_row), do: :ok

  defp trim_name(%{"name" => name} = params) when is_binary(name),
    do: %{params | "name" => String.trim(name)}

  defp trim_name(params), do: params

  # mode, type and the item names are fixed at creation: EQUAL (as the module would store it) or
  # blank is ignored, so a retried create converges; a different value is refused.
  defp locked(row, group) do
    Enum.find_value(@locked, :ok, fn {key, code} ->
      with {:ok, value} when is_binary(value) <- Map.fetch(row, key),
           false <- fold(key, value) in ["", group[key]] do
        {:error, code, "#{key} cannot be changed after the group is created"}
      else
        _ignored -> nil
      end
    end)
  end

  defp fold("mode", value), do: String.downcase(value)
  defp fold("type", value), do: value |> String.trim() |> String.downcase()
  defp fold(_item_name, value), do: String.trim(value)

  defp changed_fields(params, group) do
    params
    |> Enum.filter(fn
      {"name_i18n", incoming} -> merge_i18n(stored_i18n(group), incoming) != stored_i18n(group)
      {key, value} -> value != group[key]
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp stored_i18n(group), do: group["name_i18n"] || %{}

  # As Groups.update_group/3 merges it: a non-blank value sets its key, a blank one deletes it,
  # keys not named stay.
  defp merge_i18n(stored, incoming) when is_map(incoming) do
    Enum.reduce(incoming, stored, fn {lang, value}, acc ->
      lang = to_string(lang)

      if is_binary(value) and String.trim(value) != "",
        do: Map.put(acc, lang, String.trim(value)),
        else: Map.delete(acc, lang)
    end)
  end

  defp merge_i18n(stored, _other), do: stored

  @doc false
  # Dangerous = some row UPDATES an existing group and effectively changes it.
  def dangerous?(plan), do: Enum.any?(plan, &match?({:update, _, _, _, _}, &1))

  # --- the dry run -------------------------------------------------------------------------------

  defp preview(plan) do
    counts = post_counts(plan)

    rows =
      Enum.map(plan, fn
        {:create, ref, attrs} ->
          Common.row_ok(ref, "created", nil, %{
            "name" => attrs["name"],
            "mode" => attrs["mode"] || Constants.default_mode()
          })

        {:update, ref, group, params, fields} ->
          changes = Map.new(fields, fn field -> {field, change(group, params, field)} end)

          Common.row_ok(ref, "updated", group["uuid"], %{
            "changes" => changes,
            "post_count" => Map.fetch!(counts, group["slug"])
          })

        {:unchanged, ref, group} ->
          Common.row_ok(ref, "unchanged", group["uuid"])

        {:error, _ref, row} ->
          row
      end)

    term = {:upsert_groups, Enum.map(plan, &term_entry(&1, counts))}
    Common.preview(rows, %{"requires_confirmation" => dangerous?(plan)}, term)
  end

  defp change(group, params, "name_i18n"),
    do: %{
      "from" => stored_i18n(group),
      "to" => merge_i18n(stored_i18n(group), params["name_i18n"])
    }

  defp change(group, params, field), do: %{"from" => group[field], "to" => params[field]}

  defp post_counts(plan) do
    for {:update, _ref, group, _params, _fields} <- plan, into: %{} do
      {group["slug"], DBStorage.count_posts(group["slug"])}
    end
  end

  # The fingerprint covers the group as stored (its whole map), the numbers shown and the hash of
  # the new values.
  defp term_entry({:create, _ref, attrs}, _counts),
    do: {:create, attrs["slug"], Common.fingerprint(attrs)}

  defp term_entry({:update, _ref, group, params, _fields}, counts),
    do:
      {:update, group["uuid"], Common.fingerprint(group), Map.fetch!(counts, group["slug"]),
       Common.fingerprint(params)}

  defp term_entry({:unchanged, _ref, group}, _counts), do: {:unchanged, group["uuid"]}
  defp term_entry({:error, ref, _row}, _counts), do: {:error, ref}

  # --- the write ------------------------------------------------------------------------------

  defp execute(plan, ctx) do
    confirmed? = Map.get(ctx, :confirmation_uuid) != nil
    opts = Common.write_opts(ctx, @tool)

    rows =
      Enum.map(plan, fn
        {:create, ref, attrs} ->
          write_create(ref, attrs, confirmed?, opts)

        {:update, ref, group, params, _fields} ->
          write_update(ref, group, params, confirmed?, opts)

        {:unchanged, ref, group} ->
          Common.row_ok(ref, "unchanged", group["uuid"])

        {:error, _ref, row} ->
          row
      end)

    Common.batch_result(rows)
  end

  # The slug appeared since the plan: this row is an UPDATE now, which the gate did not classify as
  # one. Unconfirmed it is refused.
  defp write_create(ref, attrs, confirmed?, opts) do
    if not confirmed? and match?({:ok, _group}, Refs.resolve_group(attrs["slug"])) do
      flipped(ref)
    else
      # `mode:` is the group's URL mode; the activity mode travels in the opts as `:activity_mode`.
      own =
        [
          mode: attrs["mode"],
          type: attrs["type"],
          slug: attrs["slug"],
          item_singular: attrs["item_singular"],
          item_plural: attrs["item_plural"]
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case Groups.add_group(attrs["name"], own ++ opts) do
        {:ok, group} -> finish_create(ref, group, attrs, opts)
        {:error, reason} -> Common.row_from_error(ref, reason)
      end
    end
  end

  # settings and name_i18n of a NEW group: a second update right after creation (add_group takes
  # neither).
  defp finish_create(ref, group, attrs, opts) do
    extra = attrs |> Map.take(["name_i18n"]) |> Map.merge(attrs["flat_settings"])

    if extra == %{} do
      Common.row_ok(ref, "created", group["uuid"])
    else
      case Groups.update_group(group["slug"], extra, opts) do
        {:ok, _group} -> Common.row_ok(ref, "created", group["uuid"])
        {:error, reason} -> Common.row_from_error(ref, reason)
      end
    end
  end

  defp write_update(ref, group, params, confirmed?, opts) do
    # Read again: an earlier row cannot touch this group (a slug appears once), but another request can.
    case Groups.fetch_group(group["slug"]) do
      {:error, :not_found} ->
        Common.row_error(ref, "not_found", "The group does not exist.")

      {:ok, current} ->
        case changed_fields(params, current) do
          [] -> Common.row_ok(ref, "unchanged", current["uuid"])
          _fields when not confirmed? -> flipped(ref)
          fields -> apply_update(ref, current, Map.take(params, fields), opts)
        end
    end
  end

  defp apply_update(ref, current, params, opts) do
    case Groups.update_group(current["slug"], params, opts) do
      {:ok, updated} -> Common.row_ok(ref, "updated", updated["uuid"])
      {:error, reason} -> Common.row_from_error(ref, reason)
    end
  end

  defp flipped(ref),
    do: Common.row_error(ref, "revision_mismatch", "changed since the check; repeat the call")
end
