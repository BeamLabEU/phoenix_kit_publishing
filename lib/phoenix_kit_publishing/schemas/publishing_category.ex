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
  - `data` (module chain V3) holds what a category says about itself beyond
    its name: `color` (`#rgb` / `#rrggbb`, or a daisyUI theme colour such as
    `"primary"`, see `colors/0`), `icon` (a heroicon name, `"hero-cube"`),
    `seo_title` and `seo_description` for its archive page. They are cast
    from flat attrs of the same names (`changeset/2`); a blank value removes
    the key. Read them through `color/1`, `color_css/1`, `icon/1`,
    `seo_title/1` and `seo_description/1`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Modules.Publishing.LanguageHelpers

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  # `phoenix_kit_publishing_categories` `character varying` column widths,
  # interpolated into `PhoenixKitPublishing.Migrations`' V1 DDL — the single
  # source of truth so the migration chain and core's `ExpectedSchema`
  # manifest can never independently disagree on a number.
  @column_widths %{name: 255, slug: 255, description: 1024}

  @type t :: %__MODULE__{
          uuid: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          name_i18n: map(),
          description: String.t() | nil,
          position: integer(),
          group_uuid: Ecto.UUID.t() | nil,
          parent_uuid: Ecto.UUID.t() | nil,
          data: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_categories" do
    field :name, :string
    field :slug, :string
    field :name_i18n, :map, default: %{}
    field :description, :string
    field :position, :integer, default: 0
    field :data, :map, default: %{}

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
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
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
    |> put_display_data(attrs)
    |> unique_constraint([:group_uuid, :slug],
      name: :phoenix_kit_publishing_categories_group_slug_uniq
    )
    |> foreign_key_constraint(:parent_uuid,
      message: "parent category no longer exists"
    )
  end

  @doc "Create changeset — additionally casts and requires the owning group."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(category, attrs) do
    category
    |> cast(attrs, [:group_uuid])
    |> validate_required([:group_uuid])
    |> changeset(attrs)
  end

  @colors ~w(primary secondary accent neutral info success warning error)
  @hex_color ~r/\A#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/
  @icon ~r/\Ahero-[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @display_keys ~w(color icon seo_title seo_description)
  @display_limits %{"seo_title" => 120, "seo_description" => 320}

  # Icons a category can use that always render: each name is written out
  # here, in this module's source, which the host's Tailwind scans through
  # `css_sources/0`, so its `hero-*` class is generated. Any other heroicon
  # name is accepted too, but renders only once the host's Tailwind sees the
  # class (e.g. `@source inline("hero-…")` in its app.css).
  @suggested_icons ~w(
    hero-tag hero-folder hero-newspaper hero-megaphone hero-light-bulb hero-sparkles
    hero-star hero-heart hero-bolt hero-fire hero-rocket-launch hero-wrench-screwdriver
    hero-cog-6-tooth hero-cube hero-puzzle-piece hero-code-bracket hero-command-line
    hero-cpu-chip hero-server-stack hero-cloud hero-globe-alt hero-map hero-calendar
    hero-clock hero-chart-bar hero-banknotes hero-shopping-cart hero-credit-card
    hero-users hero-user-group hero-chat-bubble-left-right hero-envelope hero-book-open
    hero-academic-cap hero-document-text hero-photo hero-film hero-musical-note
    hero-shield-check hero-lock-closed hero-beaker hero-building-office hero-home
    hero-truck hero-gift hero-trophy hero-flag hero-information-circle
    hero-question-mark-circle hero-exclamation-triangle
  )

  @doc """
  Icons that render on every host without setup (see the module source for
  why); any other heroicon name works once the host's Tailwind sees it.
  """
  @spec suggested_icons() :: [String.t()]
  def suggested_icons, do: @suggested_icons

  @doc "The daisyUI theme colours a category's `color` may name instead of a hex value."
  @spec colors() :: [String.t()]
  def colors, do: @colors

  @doc "The `data` keys `changeset/2` casts from flat attrs."
  @spec display_keys() :: [String.t()]
  def display_keys, do: @display_keys

  # The flat display attrs (string or atom keys) into `data`, validated. A
  # key the attrs do not mention keeps its stored value; a blank one is
  # removed. The values reach a `style` attribute and a class, so the
  # formats are strict: a hex colour or a theme colour name, a heroicon name.
  defp put_display_data(changeset, attrs) when is_map(attrs) do
    given =
      for key <- @display_keys,
          {:ok, value} <- [fetch_attr(attrs, key)],
          into: %{},
          do: {key, value |> to_string() |> String.trim()}

    if given == %{} do
      changeset
    else
      data = Map.merge(get_field(changeset, :data) || %{}, given)
      data = for {k, v} <- data, v != "", into: %{}, do: {k, v}

      # Only what this write gives is checked: a stored value that fails
      # today's rules reads as absent (`color/1`, `icon/1`) and must not
      # refuse an edit of another field.
      changeset
      |> put_change(:data, data)
      |> validate_display_data(Map.take(data, Map.keys(given)))
    end
  end

  defp put_display_data(changeset, _attrs), do: changeset

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) or is_nil(value) -> {:ok, value || ""}
      {:ok, _other} -> :error
      :error -> fetch_atom_attr(attrs, key)
    end
  end

  @atom_keys %{
    "color" => :color,
    "icon" => :icon,
    "seo_title" => :seo_title,
    "seo_description" => :seo_description
  }

  defp fetch_atom_attr(attrs, key) do
    case Map.fetch(attrs, Map.fetch!(@atom_keys, key)) do
      {:ok, value} when is_binary(value) or is_nil(value) -> {:ok, value || ""}
      _ -> :error
    end
  end

  defp validate_display_data(changeset, data) do
    changeset
    |> check_display(
      data["color"],
      &valid_color?/1,
      :data,
      "color must be #rgb, #rrggbb or a theme colour"
    )
    |> check_display(
      data["icon"],
      &Regex.match?(@icon, &1),
      :data,
      "icon must be a heroicon name such as hero-cube"
    )
    |> check_lengths(data)
  end

  defp check_display(changeset, nil, _valid?, _field, _message), do: changeset

  defp check_display(changeset, value, valid?, field, message) do
    if valid?.(value), do: changeset, else: add_error(changeset, field, message)
  end

  defp check_lengths(changeset, data) do
    Enum.reduce(@display_limits, changeset, fn {key, max}, acc ->
      if String.length(data[key] || "") > max,
        do: add_error(acc, :data, "#{key} must be at most #{max} characters"),
        else: acc
    end)
  end

  defp valid_color?(value), do: value in @colors or Regex.match?(@hex_color, value)

  @doc "The category's colour as stored (`#hex` or a theme colour name), or nil."
  @spec color(t()) :: String.t() | nil
  def color(%__MODULE__{data: data}), do: display_value(data, "color", &valid_color?/1)

  @doc """
  The category's colour as a CSS value: the hex as stored, a theme colour as
  `var(--color-<name>)`; nil when it has none (or holds something invalid —
  it is read straight into a `style` attribute).
  """
  @spec color_css(t()) :: String.t() | nil
  def color_css(%__MODULE__{} = category) do
    case color(category) do
      nil -> nil
      "#" <> _ = hex -> hex
      token -> "var(--color-#{token})"
    end
  end

  @doc "The category's heroicon name, or nil."
  @spec icon(t()) :: String.t() | nil
  def icon(%__MODULE__{data: data}), do: display_value(data, "icon", &Regex.match?(@icon, &1))

  @doc "The SEO title of the category's archive page, or nil."
  @spec seo_title(t()) :: String.t() | nil
  def seo_title(%__MODULE__{data: data}), do: display_value(data, "seo_title", &(&1 != ""))

  @doc "The meta description of the category's archive page, or nil."
  @spec seo_description(t()) :: String.t() | nil
  def seo_description(%__MODULE__{data: data}),
    do: display_value(data, "seo_description", &(&1 != ""))

  defp display_value(data, key, valid?) when is_map(data) do
    case Map.get(data, key) do
      value when is_binary(value) -> if valid?.(value), do: value
      _ -> nil
    end
  end

  defp display_value(_data, _key, _valid?), do: nil

  @doc """
  `character varying` column widths for `phoenix_kit_publishing_categories`,
  keyed by field name.

  The single source of truth `PhoenixKitPublishing.Migrations`' V1 DDL
  interpolates, so the migration chain and core's `ExpectedSchema` manifest
  can never independently disagree on a number.
  """
  @spec column_widths() :: %{atom() => pos_integer()}
  def column_widths, do: @column_widths

  @doc """
  The category's display name for a language, base-tolerant the same way
  `PublishingGroup.translated_name/2` is: exact code, then any stored code
  sharing the base, then the primary `name`.
  """
  @spec translated_name(t(), term()) :: String.t() | nil
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
