defmodule PhoenixKit.Modules.Publishing.API.Schemas do
  @moduledoc false
  # JSON Schemas (string keys) of the publishing tools. Only the keywords core's validator
  # implements are used (type, enum, required, properties, additionalProperties, minimum,
  # maximum, minLength, maxLength, pattern, minItems, maxItems, items). Every object closes
  # itself: a field a tool does not declare (status, published_at, tags, url_slug, force) is a
  # validation error at any depth.

  @uuid %{"type" => "string", "minLength" => 36, "maxLength" => 36}

  def uuid, do: @uuid
  def text(max), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}
  def nullable_text(max), do: %{"type" => ["string", "null"], "maxLength" => max}

  # ROW-LEVEL and ref fields: the schema checks type and an upper bound only, so a malformed id
  # or slug reaches the handler and answers `invalid_ref` / `not_found` for THAT row instead of
  # one 422 for the whole request.
  def row_id, do: %{"type" => "string", "maxLength" => 200}
  def row_text(max), do: %{"type" => "string", "maxLength" => max}

  @doc "A CLOSED object."
  def object(properties, required \\ []) do
    base = %{"type" => "object", "properties" => properties, "additionalProperties" => false}
    if required == [], do: base, else: Map.put(base, "required", required)
  end

  @doc "A post reference: `{id}` or `{group, slug}`; the handler requires exactly one form."
  def post_ref, do: object(%{"id" => row_id(), "group" => row_text(200), "slug" => row_text(200)})

  @doc "A group reference: `{slug}`."
  def group_ref, do: object(%{"slug" => row_text(200)})

  @doc "A category reference: `{id}` or `{slug}`."
  def category_ref, do: object(%{"id" => row_id(), "slug" => row_text(200)})

  def warnings_output do
    %{"type" => "array", "items" => %{"type" => "object"}}
  end

  # --- group reads ------------------------------------------------------------------------

  def list_groups, do: object(%{"status" => %{"type" => "string", "enum" => ~w(active trashed)}})

  def list_groups_output do
    object_output(%{
      "groups" => %{"type" => "array", "items" => %{"type" => "object"}},
      "count" => %{"type" => "integer"}
    })
  end

  def get_group_settings_schema, do: object(%{})

  def get_group_settings_schema_output do
    object_output(%{
      "settings" => %{"type" => "array", "items" => %{"type" => "object"}},
      "defaults" => %{"type" => "object"},
      "group_fields" => %{"type" => "array", "items" => %{"type" => "string"}}
    })
  end

  @doc "An output schema (open: core does not validate answers strictly)."
  def object_output(properties), do: %{"type" => "object", "properties" => properties}
end
