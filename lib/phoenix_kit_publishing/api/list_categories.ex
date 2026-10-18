defmodule PhoenixKit.Modules.Publishing.API.ListCategories do
  @moduledoc false
  # Tool `publishing.list_categories`: the categories of one group, flat in tree order. Strict
  # reads: a database error raises (core answers internal_error) instead of an empty tree.

  alias PhoenixKit.Modules.Publishing.API.{Common, Refs}

  @spec call(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def call(input, _ctx) do
    case Refs.resolve_group(input["group"]) do
      {:error, :not_found} ->
        {:error, :not_found, "The group does not exist.", %{}}

      {:ok, group} ->
        counts = Common.published_post_counts!(group.slug)

        rows =
          for {category, depth} <- Common.category_tree!(group.slug) do
            %{
              "id" => category.uuid,
              "slug" => category.slug,
              "name" => category.name,
              "name_i18n" => category.name_i18n || %{},
              "description" => category.description,
              "position" => category.position,
              "parent_id" => category.parent_uuid,
              "depth" => depth,
              "published_post_count" => Map.get(counts, category.uuid, 0)
            }
          end

        {:ok, %{"categories" => rows, "count" => length(rows)}}
    end
  end
end
