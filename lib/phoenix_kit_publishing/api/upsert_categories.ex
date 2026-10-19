defmodule PhoenixKit.Modules.Publishing.API.UpsertCategories do
  @moduledoc false
  # Tool `publishing.upsert_categories`.

  alias PhoenixKit.Modules.Publishing.API.{Common, Refs}
  alias PhoenixKit.Modules.Publishing.Categories

  @tool "publishing.upsert_categories"
  @slug ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @attr_keys ~w(name description name_i18n position)
  @int4 -2_147_483_648..2_147_483_647

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, group} <- input["group"] |> Refs.resolve_group() |> Refs.group_missing(),
         :ok <- group |> Refs.ensure_group_active() |> Refs.group_error() do
      plan = plan(group.slug, input["categories"])
      if Map.get(ctx, :dry_run?, false), do: preview(group, plan), else: execute(group, plan, ctx)
    end
  end

  @doc false
  # The plan resolves every row against the stored categories AND the rows planned before it.
  # Reads are strict: a database error raises (the danger function turns it into `true`).
  def plan(group_slug, rows) do
    stored = Common.categories!(group_slug)

    {entries, _known} =
      Enum.map_reduce(rows, stored, fn row, known ->
        entry = plan_row(row, known)
        {entry, add_planned(known, entry)}
      end)

    entries
  end

  defp plan_row(row, known) when is_map(row) do
    ref = Map.take(row, ["id", "slug"])

    case find(row, known) do
      {:ok, nil} -> create_entry(row, ref, known)
      {:ok, category} -> update_entry(row, ref, category, known)
      {:error, code, message} -> {:error, ref, Common.row_error(ref, code, message)}
    end
  end

  defp plan_row(other, _known),
    do:
      {:error, other,
       Common.row_error(other, "invalid_ref", "a row must be an object with id or slug")}

  defp find(%{"id" => id, "slug" => slug}, known) do
    case Enum.find(known, &(&1.uuid == id)) do
      %{slug: ^slug} = category -> {:ok, category}
      _other -> {:error, "invalid_ref", "id and slug do not name the same category"}
    end
  end

  defp find(%{"id" => id}, known) do
    case Enum.find(known, &(&1.uuid == id)) do
      nil -> {:error, "not_found", "The category does not exist."}
      category -> {:ok, category}
    end
  end

  defp find(%{"slug" => slug}, known) when is_binary(slug),
    do: {:ok, Enum.find(known, &(&1.slug == slug))}

  defp find(_row, _known), do: {:error, "invalid_ref", "give id or slug"}

  defp create_entry(row, ref, known) do
    with :ok <- name_given(row),
         :ok <- slug_shape(row["slug"]),
         :ok <- check_fields(row),
         {:ok, parent} <- parent_attr(row, known, nil) do
      {:create, ref,
       row |> Map.take(@attr_keys) |> Map.merge(parent) |> Map.put("slug", row["slug"])}
    else
      {:error, code, message} -> {:error, ref, Common.row_error(ref, code, message)}
    end
  end

  defp name_given(row),
    do:
      if(Map.has_key?(row, "name"),
        do: :ok,
        else: {:error, "validation_failed", "a new category needs a name"}
      )

  defp slug_shape(slug) when is_binary(slug),
    do:
      if(Regex.match?(@slug, slug),
        do: :ok,
        else:
          {:error, "invalid_slug",
           "the slug must be lowercase letters, digits and single hyphens"}
      )

  defp slug_shape(_slug), do: {:error, "invalid_ref", "a new category needs a slug"}

  # Text fields are checked before any write: a NUL byte or invalid UTF-8 would make Postgres
  # raise, and a value over the column width would only fail at the write.
  defp check_fields(row) do
    with :ok <- check_name(row),
         :ok <- check_text("description", row["description"], 1024),
         :ok <- check_name_i18n(row),
         do: check_position(row)
  end

  defp check_name(row) do
    case Map.fetch(row, "name") do
      :error -> :ok
      {:ok, name} when is_binary(name) -> check_name_text(name)
      {:ok, _other} -> {:error, "validation_failed", "name must be a string"}
    end
  end

  defp check_name_text(name) do
    with :ok <- check_text("name", name, 255) do
      if String.trim(name) == "",
        do: {:error, "validation_failed", "name must not be blank"},
        else: :ok
    end
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
    with :ok <- check_text("name_i18n key", key, 20),
         :ok <- check_i18n_value(value) do
      nil
    end
  end

  defp check_i18n_value(value) when is_binary(value),
    do: check_text("name_i18n value", value, 255)

  defp check_i18n_value(_value),
    do: {:error, "validation_failed", "name_i18n values must be strings"}

  defp check_position(row) do
    case Map.fetch(row, "position") do
      :error -> :ok
      {:ok, position} when is_integer(position) and position in @int4 -> :ok
      {:ok, _other} -> {:error, "validation_failed", "position must be a 32-bit integer"}
    end
  end

  defp check_text(path, value, max) do
    case Common.check_text(path, value, max_chars: max) do
      :ok -> :ok
      {:error, _code, message, _context} -> {:error, "validation_failed", path <> " " <> message}
    end
  end

  defp update_entry(row, ref, category, known) do
    with :ok <- check_fields(row),
         {:ok, parent} <- parent_attr(row, known, category) do
      attrs = row |> Map.take(@attr_keys) |> Map.merge(parent) |> drop_unchanged(category)

      if attrs == %{},
        do: {:unchanged, ref, category},
        else: {:update, ref, category, attrs, attrs |> Map.keys() |> Enum.sort()}
    else
      {:error, code, message} -> {:error, ref, Common.row_error(ref, code, message)}
    end
  end

  @doc false
  # name_i18n is compared as the WHOLE replaced map.
  def drop_unchanged(attrs, category) do
    Map.filter(attrs, fn
      {"parent_uuid", value} -> value != category.parent_uuid
      {"name_i18n", value} -> value != (category.name_i18n || %{})
      {key, value} -> value != Map.get(category, String.to_existing_atom(key))
    end)
  end

  # Absent keeps; null is the top level; {id} / {slug} are resolved over the stored categories AND the
  # rows planned before this one (`known`).
  defp parent_attr(row, known, category) do
    case Map.fetch(row, "parent") do
      :error -> {:ok, %{}}
      {:ok, nil} -> {:ok, %{"parent_uuid" => nil}}
      {:ok, ref} -> resolve_parent(ref, known, category)
    end
  end

  defp resolve_parent(ref, known, category) do
    case Refs.resolve_category(ref, known) do
      {:ok, parent} ->
        if category &&
             (parent.uuid == category.uuid or descendant?(parent, category.uuid, known, 0)),
           do:
             {:error, "category_cycle",
              "a category cannot be moved under itself or its own descendant"},
           else: {:ok, %{"parent_uuid" => parent.uuid}}

      {:error, :invalid_ref} ->
        {:error, "invalid_ref", "parent must be {id} or {slug}"}

      {:error, :not_found} ->
        foreign_or_missing(ref)
    end
  end

  # An id outside the group may still be a real category of another group.
  defp foreign_or_missing(%{"id" => id}) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, _category} <- Categories.fetch_category(uuid) do
      {:error, "parent_wrong_group", "the parent belongs to another group"}
    else
      _ -> {:error, "parent_not_found", "The parent category does not exist."}
    end
  end

  defp foreign_or_missing(_ref),
    do: {:error, "parent_not_found", "The parent category does not exist."}

  defp descendant?(_node, _ancestor, _known, hops) when hops > 100, do: true
  defp descendant?(%{parent_uuid: nil}, _ancestor, _known, _hops), do: false
  defp descendant?(%{parent_uuid: ancestor}, ancestor, _known, _hops), do: true

  defp descendant?(%{parent_uuid: parent_uuid}, ancestor, known, hops) do
    case Enum.find(known, &(&1.uuid == parent_uuid)) do
      nil -> false
      parent -> descendant?(parent, ancestor, known, hops + 1)
    end
  end

  # A planned create joins `known` with a plan-only uuid; a planned update replaces its category.
  defp add_planned(known, {:create, _ref, attrs}) do
    known ++
      [
        %{
          uuid: "planned:" <> attrs["slug"],
          slug: attrs["slug"],
          name: attrs["name"],
          description: attrs["description"],
          name_i18n: attrs["name_i18n"] || %{},
          position: attrs["position"],
          parent_uuid: attrs["parent_uuid"]
        }
      ]
  end

  defp add_planned(known, {:update, _ref, category, attrs, _fields}) do
    atomized = Map.new(attrs, fn {key, value} -> {String.to_existing_atom(key), value} end)
    Enum.map(known, fn c -> if c.uuid == category.uuid, do: Map.merge(c, atomized), else: c end)
  end

  defp add_planned(known, _other), do: known

  @doc false
  def planned?(%{uuid: "planned:" <> _}), do: true
  def planned?(_category), do: false

  # --- the write ------------------------------------------------------------------------------

  defp execute(group, plan, ctx) do
    confirmed? = Map.get(ctx, :confirmation_uuid) != nil
    fresh = Common.categories!(group.slug)
    opts = Common.write_opts(ctx, @tool)

    {rows, _created} =
      Enum.map_reduce(plan, %{}, fn
        {:create, ref, attrs}, created ->
          write_create(group, ref, attrs, fresh, created, confirmed?, opts)

        {:update, ref, category, attrs, _fields}, created ->
          write_update(group, ref, category, attrs, created, confirmed?, opts)

        {:unchanged, ref, category}, created ->
          {Common.row_ok(ref, "unchanged", real_id(category.uuid, created)), created}

        {:error, _ref, row}, created ->
          {row, created}
      end)

    Common.batch_result(rows)
  end

  # The slug appeared since the plan: this row is an UPDATE now. Unconfirmed it is refused (the gate
  # classified it as a create); confirmed it updates.
  defp write_create(group, ref, attrs, fresh, created, confirmed?, opts) do
    case Enum.find(fresh, &(&1.slug == attrs["slug"])) do
      nil ->
        case Categories.create_category(group.slug, real_parent(attrs, created), opts) do
          {:ok, c} ->
            {Common.row_ok(ref, "created", c.uuid), Map.put(created, attrs["slug"], c.uuid)}

          {:error, reason} ->
            {Common.row_from_error(ref, reason), created}
        end

      existing ->
        if confirmed?,
          do:
            apply_update(
              ref,
              existing,
              drop_unchanged(attrs, existing),
              Map.put(created, attrs["slug"], existing.uuid),
              opts
            ),
          else: {flipped(ref), created}
    end
  end

  defp write_update(group, ref, category, attrs, created, confirmed?, opts) do
    uuid = real_id(category.uuid, created)

    # Read again: an earlier row of this request may have changed the category, and a planned
    # category exists only after its create ran.
    case Enum.find(Common.categories!(group.slug), &(&1.uuid == uuid)) do
      nil ->
        {Common.row_error(ref, "not_found", "The category does not exist."), created}

      current ->
        attrs = drop_unchanged(attrs, current)

        cond do
          attrs == %{} -> {Common.row_ok(ref, "unchanged", uuid), created}
          not confirmed? and not planned?(category) -> {flipped(ref), created}
          true -> apply_update(ref, current, attrs, created, opts)
        end
    end
  end

  defp apply_update(ref, current, attrs, created, _opts) when attrs == %{},
    do: {Common.row_ok(ref, "unchanged", current.uuid), created}

  defp apply_update(ref, current, attrs, created, opts) do
    case Categories.update_category(current.uuid, real_parent(attrs, created), opts) do
      {:ok, c} -> {Common.row_ok(ref, "updated", c.uuid), created}
      {:error, reason} -> {Common.row_from_error(ref, reason), created}
    end
  end

  defp flipped(ref),
    do: Common.row_error(ref, "revision_mismatch", "changed since the check; repeat the call")

  defp real("planned:" <> slug = planned, created), do: Map.get(created, slug, planned)
  defp real(uuid, _created), do: uuid

  # The id an answer row shows: never a plan-only uuid.
  defp real_id(uuid, created) do
    case real(uuid, created) do
      "planned:" <> _ -> nil
      id -> id
    end
  end

  defp real_parent(%{"parent_uuid" => parent} = attrs, created),
    do: Map.put(attrs, "parent_uuid", real(parent, created))

  defp real_parent(attrs, _created), do: attrs

  @doc false
  # Dangerous = some row UPDATES an existing category (a category created earlier in the same request does not count).
  def dangerous?(plan) do
    Enum.any?(plan, fn
      {:update, _ref, category, _attrs, _fields} -> not planned?(category)
      _other -> false
    end)
  end

  # --- the dry run -------------------------------------------------------------------------------

  defp preview(group, plan) do
    counts = Common.published_post_counts!(group.slug)

    rows =
      Enum.map(plan, fn
        {:create, ref, attrs} ->
          Common.row_ok(ref, "created", nil, %{
            "slug" => attrs["slug"],
            "name" => attrs["name"],
            "parent_uuid" => attrs["parent_uuid"]
          })

        {:update, ref, category, attrs, _fields} ->
          changes =
            Map.new(attrs, fn {key, to} ->
              {key, %{"from" => clip(from_value(category, key)), "to" => clip(to)}}
            end)

          Common.row_ok(ref, "updated", shown_id(category), %{
            "published_post_count" => Map.get(counts, category.uuid, 0),
            "changes" => changes
          })

        {:unchanged, ref, category} ->
          Common.row_ok(ref, "unchanged", shown_id(category))

        {:error, _ref, row} ->
          row
      end)

    term = {:upsert_categories, group.status, Enum.map(plan, &term_entry(&1, counts))}
    Common.preview(rows, %{"requires_confirmation" => dangerous?(plan)}, term)
  end

  defp shown_id(category), do: if(planned?(category), do: nil, else: category.uuid)

  defp from_value(category, "parent_uuid"), do: category.parent_uuid
  defp from_value(category, key), do: Map.get(category, String.to_existing_atom(key))
  defp clip(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp clip(value), do: value

  defp term_entry({:create, _ref, attrs}, _counts),
    do: {:create, attrs["slug"], Common.fingerprint(attrs)}

  defp term_entry({:update, _ref, c, attrs, _fields}, counts),
    do:
      {:update, c.uuid, c.slug, c.name, c.parent_uuid, c.position,
       Common.fingerprint({c.name_i18n, c.description}), Map.get(counts, c.uuid, 0),
       Common.fingerprint(attrs)}

  defp term_entry({:unchanged, _ref, c}, counts),
    do: {:unchanged, c.uuid, Map.get(counts, c.uuid, 0)}

  defp term_entry({:error, ref, _row}, _counts), do: {:error, ref}
end
