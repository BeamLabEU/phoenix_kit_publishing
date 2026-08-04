defmodule PhoenixKit.Modules.Publishing.PublishingCategory do
  @moduledoc """
  Hierarchical, per-group category (WordPress-parity taxonomy). Backed by
  core migration **V159** (`phoenix_kit_publishing_categories`).

  - The tree is a nullable `parent_uuid` self-FK; the DB lifts children to
    the root when a parent is deleted (`ON DELETE SET NULL`). Same-group
    scope and cycle prevention are context-layer rules
    (`Publishing.Categories`), mirroring the V103 catalogue-categories and
    V116 entity-data conventions.
  - `slug` is unique per group, not globally — two groups can both have
    "news". It is intentionally not translated (single canonical URL
    segment), matching the group-slug rule.
  - `name_i18n` carries per-language display-name overrides keyed by
    language code (`%{"et" => "Uudised"}`); the primary-language name
    lives in `name`. Resolution is base-tolerant via `translated_name/2`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Modules.Publishing.LanguageHelpers

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          name_i18n: map(),
          description: String.t() | nil,
          position: integer(),
          group_uuid: Ecto.UUID.t() | nil,
          parent_uuid: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_categories" do
    field :name, :string
    field :slug, :string
    field :name_i18n, :map, default: %{}
    field :description, :string
    field :position, :integer, default: 0

    belongs_to :group, PhoenixKit.Modules.Publishing.PublishingGroup,
      foreign_key: :group_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :parent, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for create/update. `group_uuid` is cast on create only (a
  category never moves between groups); the context layer validates the
  parent (same group, no cycles) before the DB sees it.
  """
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :slug, :name_i18n, :description, :position, :parent_uuid])
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 255)
    |> validate_length(:slug, max: 255)
    |> validate_length(:description, max: 1024)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must be lowercase letters, numbers, and hyphens"
    )
    |> normalize_name_i18n()
    |> unique_constraint([:group_uuid, :slug],
      name: :phoenix_kit_publishing_categories_group_slug_uniq
    )
    |> foreign_key_constraint(:parent_uuid,
      message: "parent category no longer exists"
    )
  end

  @doc "Create changeset — additionally casts and requires the owning group."
  def create_changeset(category, attrs) do
    category
    |> cast(attrs, [:group_uuid])
    |> validate_required([:group_uuid])
    |> changeset(attrs)
  end

  @doc """
  The category's display name for a language, base-tolerant the same way
  `PublishingGroup.translated_name/2` is: exact code, then any stored code
  sharing the base, then the primary `name`.
  """
  def translated_name(%__MODULE__{} = category, language) when is_binary(language) do
    overrides = category.name_i18n || %{}

    present(Map.get(overrides, language)) ||
      base_override(overrides, language) ||
      category.name
  end

  def translated_name(%__MODULE__{} = category, _), do: category.name

  # The form stores full codes ("fr-FR"); the public side asks by the short
  # one ("fr"), so an exact miss falls back to any override sharing the base.
  defp base_override(overrides, language) do
    base = base_of(language)

    Enum.find_value(overrides, fn {code, value} ->
      if base_of(code) == base, do: present(value)
    end)
  end

  defp base_of(code), do: LanguageHelpers.url_language_code(code) || code

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  # Drop non-binary override values (nested maps from crafted params) and cap
  # lengths — same hardening as the group-name overrides.
  defp normalize_name_i18n(changeset) do
    case get_change(changeset, :name_i18n) do
      %{} = overrides ->
        cleaned =
          overrides
          |> Enum.filter(fn {k, v} -> is_binary(k) and is_binary(v) end)
          |> Map.new(fn {k, v} -> {k, String.slice(v, 0, 255)} end)

        put_change(changeset, :name_i18n, cleaned)

      _ ->
        changeset
    end
  end
end
