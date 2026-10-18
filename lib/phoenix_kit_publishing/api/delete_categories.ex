defmodule PhoenixKit.Modules.Publishing.API.DeleteCategories do
  @moduledoc false
  # Tool `publishing.delete_categories` (spec §9.15): the ONE permanent delete the API offers.

  alias PhoenixKit.Modules.Publishing.API.{Common, Refs}
  alias PhoenixKit.Modules.Publishing.Categories

  @tool "publishing.delete_categories"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, group} <- input["group"] |> Refs.resolve_group() |> Refs.group_missing(),
         :ok <- group |> Refs.ensure_group_active() |> Refs.group_error() do
      categories = Common.categories!(group.slug)
      plan = plan(input["refs"], categories)

      if Map.get(ctx, :dry_run?, false),
        do: preview(group, plan, categories),
        else: execute(group, plan, ctx)
    end
  end

  # {:delete, ref, category} | {:error, ref, row}; the same category twice is a row error.
  defp plan(refs, categories) do
    {entries, _seen} =
      Enum.map_reduce(refs, MapSet.new(), fn ref, seen ->
        case Refs.resolve_category(ref, categories) do
          {:ok, category} ->
            if MapSet.member?(seen, category.uuid),
              do: {duplicate(ref), seen},
              else: {{:delete, ref, category}, MapSet.put(seen, category.uuid)}

          {:error, :invalid_ref} ->
            {{:error, ref, Common.row_error(ref, "invalid_ref", "give {id} or {slug}")}, seen}

          {:error, :not_found} ->
            {{:error, ref, Common.row_error(ref, "not_found", "The category does not exist.")},
             seen}
        end
      end)

    entries
  end

  defp duplicate(ref) do
    {:error, ref,
     Common.row_error(ref, "invalid_ref", "the same category appears twice in the request")}
  end

  defp execute(group, plan, ctx) do
    opts = Common.write_opts(ctx, @tool)

    rows =
      Enum.map(plan, fn
        {:delete, ref, category} ->
          case Categories.delete_category(category.uuid, opts) do
            {:ok, _deleted} -> removed_row(group, ref, category)
            {:error, reason} -> Common.row_from_error(ref, reason)
          end

        {:error, _ref, row} ->
          row
      end)

    Common.batch_result(rows)
  end

  # After the delete, the versions that still name the uuid (unfile_deleted_category/1 swallows its
  # own failure and returns :ok): a warning, not an error, because the category is already gone.
  defp removed_row(group, ref, category) do
    left =
      group.slug |> Common.filed_versions_counts!([category.uuid]) |> Map.get(category.uuid, 0)

    extra =
      if left > 0,
        do: %{
          "warnings" => [
            %{
              "code" => "unfile_incomplete",
              "count" => left,
              "message" => "#{left} versions still name the deleted category"
            }
          ]
        },
        else: %{}

    Common.row_ok(ref, "removed", category.uuid, extra)
  end

  defp preview(group, plan, categories) do
    uuids = for {:delete, _ref, category} <- plan, do: category.uuid
    filed = Common.filed_versions_counts!(group.slug, uuids)
    published = Common.published_post_counts!(group.slug)
    cascade = post_category_counts(uuids)

    rows =
      Enum.map(plan, fn
        {:delete, ref, category} ->
          Common.row_ok(ref, "removed", category.uuid, %{
            "irreversible" => true,
            "name" => category.name,
            "children" => Enum.count(categories, &(&1.parent_uuid == category.uuid)),
            "published_posts" => Map.get(published, category.uuid, 0),
            "filed_versions" => Map.get(filed, category.uuid, 0),
            "post_categories" => Map.get(cascade, category.uuid, 0)
          })

        {:error, _ref, row} ->
          row
      end)

    term =
      {:delete_categories, group.status,
       Enum.map(plan, fn
         {:delete, _ref, c} ->
           {:delete, c.uuid, c.slug, c.parent_uuid, Map.get(filed, c.uuid, 0),
            Map.get(published, c.uuid, 0), Map.get(cascade, c.uuid, 0)}

         {:error, ref, row} ->
           {:error, Common.fingerprint(ref), row["error"]["code"]}
       end)}

    Common.preview(rows, %{"requires_confirmation" => true}, term)
  end

  # Rows of the join table that the delete cascades, per category.
  defp post_category_counts([]), do: %{}

  defp post_category_counts(uuids) do
    sql =
      "SELECT category_uuid, count(*) FROM phoenix_kit_publishing_post_categories " <>
        "WHERE category_uuid = ANY($1) GROUP BY category_uuid"

    dumped = Enum.map(uuids, &Ecto.UUID.dump!/1)

    PhoenixKit.RepoHelper.repo().query!(sql, [dumped]).rows
    |> Map.new(fn [raw, count] -> {Ecto.UUID.load!(raw), count} end)
  end
end
