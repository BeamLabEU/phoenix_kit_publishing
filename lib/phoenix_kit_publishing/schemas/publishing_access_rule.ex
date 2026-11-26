defmodule PhoenixKit.Modules.Publishing.PublishingAccessRule do
  @moduledoc """
  One access rule on a post, or one rule of a group's default for new posts
  (module chain V4, `phoenix_kit_publishing_access_rules`).

  Exactly one of `post_uuid` / `group_uuid` is set. A post with no rule of a
  gating kind is public, as every post was before rules existed.

  Kinds:

    * `"signed_in"` — any signed-in reader.
    * `"role"` — a reader holding one of `config["role_uuids"]` (core role
      uuids; matched against the scope's roles by name at check time, so a
      renamed role keeps its rule).
    * `"user"` — one of `config["user_uuids"]`.
    * `"password"` — `config["hash"]` (Bcrypt, as core's own passwords) and
      `config["rev"]`, the revision a reader's grant carries: rotating the
      password bumps it, which invalidates every grant made before.
    * `"token"` — a secret link: `config["digest"]` is the SHA-256 of the
      32-byte key (the key itself is never stored), `note` names the
      recipient, `revoked_at` ends it.
    * `"settings"` — not a gate: `config["match"]` (`"any"` / `"all"`) for
      the post or group, and for a group also `config["list_protected"]`.

  `expires_at` closes a rule after that moment: the post stays protected, the
  rule just stops granting.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @column_widths %{kind: 20, note: 255}

  @kinds ~w(signed_in role user password token settings)
  @gate_kinds ~w(signed_in role user password token)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          post_uuid: UUIDv7.t() | nil,
          group_uuid: UUIDv7.t() | nil,
          kind: String.t() | nil,
          config: map(),
          note: String.t() | nil,
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          created_by_uuid: UUIDv7.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_access_rules" do
    field :kind, :string
    field :config, :map, default: %{}
    field :note, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :created_by_uuid, UUIDv7

    belongs_to :post, PhoenixKit.Modules.Publishing.PublishingPost,
      foreign_key: :post_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :group, PhoenixKit.Modules.Publishing.PublishingGroup,
      foreign_key: :group_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc "Every rule kind, the `settings` pseudo-rule included."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The kinds that restrict who may open a post."
  @spec gate_kinds() :: [String.t()]
  def gate_kinds, do: @gate_kinds

  @doc "Changeset for a new or edited rule."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :post_uuid,
      :group_uuid,
      :kind,
      :config,
      :note,
      :expires_at,
      :revoked_at,
      :created_by_uuid
    ])
    |> validate_required([:kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:note, max: @column_widths.note)
    |> validate_owner()
    |> foreign_key_constraint(:post_uuid, name: :fk_publishing_access_rules_post)
    |> foreign_key_constraint(:group_uuid, name: :fk_publishing_access_rules_group)
  end

  defp validate_owner(changeset) do
    case {get_field(changeset, :post_uuid), get_field(changeset, :group_uuid)} do
      {nil, nil} -> add_error(changeset, :post_uuid, "a rule belongs to a post or a group")
      {_, nil} -> changeset
      {nil, _} -> changeset
      {_, _} -> add_error(changeset, :group_uuid, "a rule belongs to a post or a group, not both")
    end
  end

  @doc """
  `character varying` column widths for `phoenix_kit_publishing_access_rules`,
  the numbers the chain's V4 DDL interpolates.
  """
  @spec column_widths() :: %{atom() => pos_integer()}
  def column_widths, do: @column_widths
end
