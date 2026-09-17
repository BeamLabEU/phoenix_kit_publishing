defmodule PhoenixKitPublishing.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_publishing` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`. This follows the canonical shape
  documented in `phoenix_kit_hello_world`'s README ("Versioned migrations",
  "Adopting a table core already creates") and its
  `mix phoenix_kit_hello_world.audit_migrations` task: **two readers**
  (`migrated_version/1` for migration context, `migrated_version_runtime/1`
  for Mix-task context), `up/1` re-reading the version before it changes
  anything, and a namespaced `COMMENT ON TABLE` marker on one anchor table.
  `PhoenixKitNewsletters.Migrations` is this chain's closest sibling — same
  adoption situation, same semantic-guard requirement — adapted here for 7
  tables instead of 2, a composite-key pair, one named UNIQUE constraint, a
  GIN index, and two `DESC`-ordered indexes.

  ## Ownership situation — read before touching

  All 7 tables are core's baseline today. Core's `ExpectedSchema` manifest
  records `since: 59` for `phoenix_kit_publishing_contents`/`_groups`/
  `_posts`/`_versions` — a REAL pre-squash migration version, not an internal
  manifest counter — and `since: 159` for `_categories`/`_post_categories`/
  `_post_views`. So the first 4 tables actually originated in core migration
  `V59`, long before the `V135` squash baseline; `V135`'s own literal `CREATE
  TABLE` text is the squash's snapshot of that shape (plus everything layered
  on before the squash was cut: `V62` renamed the `_id` FK columns this
  module's schemas never saw to `_uuid`, `V83` added `groups.status`, `V88`
  added `groups.title_i18n`/`description_i18n`, `posts.active_version_uuid`/
  `trashed_at`, and `versions.published_at`). The other 3 tables are NOT a
  squash artifact — `V159` (PR #665, shipped in core 1.7.214) is the real
  migration that created them, already in inline-constraint form (composite
  primary keys on `_post_categories`/`_post_views`, a named UNIQUE constraint
  on `_categories`, inline `ON DELETE` foreign keys). This module never
  shipped a migration file of its own before this one (`git log --all --
  '*migration*'` in this repo confirms it), so there is no module-side
  predecessor whose shape could have been squashed incorrectly.

  A dedicated research pass — core's literal migration source (`V135`,
  `V159`, `V164`), core's structured `ExpectedSchema.objects/1` `revisions`
  field (not its precomputed `create:`/`check:` text, which reflects only the
  newest shape and is not itself evidence of anything), and a live,
  fully-migrated Postgres catalog on a real, independently-run host
  (`decor_3d_print_dev`, `information_schema.columns`, `pg_indexes`,
  `pg_get_constraintdef`, `pg_get_expr`) — found all three in agreement,
  column-for-column, index-for-index, constraint-for-constraint, for the
  FINAL shape of every one of the 7 tables. `up_statements/2` is therefore
  `CREATE TABLE IF NOT EXISTS` (full final shape) + semantically-guarded PKs
  (including the 2 composite ones), 1 named UNIQUE constraint, 22 indexes,
  and 12 foreign keys, plus the version-marker `COMMENT` — **no `ALTER TABLE
  ... ADD COLUMN`/`DROP NOT NULL` safety-net section anywhere in this file**:
  `V164` (the newest core migration that touches any of these 7 tables)
  shipped in core `2.0.0`, well before this package's `~> 2.14` floor, so
  every host that can install this module today already has the final shape.
  None of the 7 tables carries a `CHECK` constraint (confirmed by the same
  three-source pass), so there is no `check_guard` helper in this file —
  unlike `PhoenixKitNewsletters.Migrations`, which needed one for 2.

  ### `idx_publishing_posts_group_slug` — read `V164`, not just `V135`

  `V135`'s squashed text creates this index as a plain (non-partial) UNIQUE
  index on `(group_uuid, slug)`. `V164` (core `2.0.0`) rebuilds it as a
  PARTIAL unique index, `WHERE (slug IS NOT NULL)` — a real, post-squash
  shape change, not a squash artifact, because a NULL `slug` (every
  timestamp-mode post) must never collide under the old plain-UNIQUE
  semantics that treated all NULLs as multiple violations only on some
  Postgres versions' interpretation quirks; the partial form makes the
  "no NULL blocks anything" intent explicit and portable. Core's own manifest
  records this as a 3rd revision (`{164, %{predicate: "(slug IS NOT NULL)",
  ...}}`) on top of the `V59`/`V62` id-rename revisions — reading only
  `V135`'s literal text here would have adopted the WRONG (pre-`V164`) index
  shape. This chain's DDL reproduces the POST-`V164` form directly; there is
  no intermediate step where an older shape is created and then repaired,
  because every host this package's floor supports already has `V164`.

  ### `posts.slug` nullability — already correct in the squash text

  `V135`'s squashed literal text already declares `slug character
  varying(500)` with no `NOT NULL` — the `V68` revision that made it nullable
  predates the squash and is baked into the snapshot. No action needed here;
  documented so a future reader diffing against `V59`'s ORIGINAL (`NOT NULL`)
  shape does not mistake the squash text for a discrepancy.

  ### Guards are semantic, not name-based — a real host discovery

  A host-level rename bug already hit this exact family of guards on a real
  install (`decor_3d_print`'s `phoenix_kit_posts` table ended up with 3
  duplicate UNIQUE indexes from a name-based guard after a host-level
  rename), and `PhoenixKitNewsletters.Migrations`' first cut crashed outright
  on a renamed host with `42P16 multiple primary keys` for the same reason.
  `ALTER TABLE ... RENAME TO` never renames a table's own constraints or
  indexes, and core's own `V135`/`V159` guards get away with by-name checks
  only because the baseline runs solely on an empty database; an adoption
  chain runs on tables with an arbitrary naming history. Every guard here is
  therefore **semantic**:

    * **Primary keys** (including the 2 composite ones on
      `_post_categories`/`_post_views`) — "does this table already have ANY
      primary key" via `contype = 'p'` on the table (resolved through
      `regclass`, immune to renames), never a check for a specific
      `<table>_pkey` name.
    * **The 1 named UNIQUE constraint** (`_categories_group_slug_uniq`) — via
      `contype = 'u'` PLUS the exact ordered column set (`conkey` resolved to
      column names through `pg_attribute`), not by name — matching
      `PhoenixKitNewsletters.Migrations`' CHECK-guard byte-for-byte-or-name
      caution, applied to the UNIQUE-constraint case this module has instead.
    * **Foreign keys** (all 12, including the 4 auto-named `V159` ones and
      `_categories`' self-referencing `parent_uuid` FK) — by source table,
      target table, and source column (all via `regclass`/`pg_attribute`,
      immune to renames on either end). The referential action
      (`ON DELETE ...`) is deliberately NOT part of the match — this is an
      ADOPTION guard, not a shape-repair tool; a host whose existing FK
      already disagrees on `ON DELETE` is a legitimate V2+ shape change, not
      something V1's adoption should silently override.
    * **Indexes** (all 22, including the GIN index and the 2 `DESC`-ordered
      ones) — by ordered column list, uniqueness, access method (`btree` for
      21, `gin` for `idx_publishing_contents_data_gin`), and canonical
      partial predicate via `pg_get_expr`, with `indexprs IS NULL` and a
      column-count check so an expression index can never masquerade as a
      match (same defense `PhoenixKitNewsletters.Migrations` documents in
      detail). A bare `CREATE INDEX IF NOT EXISTS <name> ...` is not enough —
      it only guards its own literal name, not a second, differently-named
      index with an identical definition (the `phoenix_kit_posts` incident
      above), so every `CREATE INDEX`/`CREATE UNIQUE INDEX` here still runs
      inside a `DO $$ ... $$` guard via `EXECUTE`.

  ### `DESC` ordering — the one guard shape newsletters never needed

  Two indexes are the first in this migration-porting series to sort a key
  column `DESC`: `idx_publishing_posts_group_date_time` (`post_date DESC,
  post_time DESC`) and `idx_publishing_versions_published_at` (`published_at
  DESC`). `pg_get_indexdef(index_oid, column_no, pretty)` — tempting as a
  per-column direction source — was tried and rejected: verified live (both
  `pretty => true` and `pretty => false`) it renders the bare column
  expression only, never the sort direction, on the Postgres version this
  package's CI runs. The direction lives in `pg_index.indoption`, one
  `int2` per key: bit `0x01` set means `DESC`, and Postgres pairs a
  `DESC` key with `NULLS FIRST` by default (bit `0x02`) unless the `CREATE
  INDEX` text overrides it — none of ours do — so a plain ascending column
  reads `indoption = 0` and a plain `col DESC` column reads `indoption = 3`,
  verified against the live `decor_3d_print_dev` catalog for both index guard
  and column-name.

  `pg_index.indoption`, like `pg_index.indkey`, is stored as an `int2vector`,
  whose cast to `int2[]` keeps a **zero-based** array lower bound — comparing
  it directly against a literal `ARRAY[0, 3, 3]::int2[]` (1-based) is FALSE
  even when every element matches, verified live. The fix mirrors what this
  file already does for `indkey`/column names: `unnest(...) WITH ORDINALITY`
  into a plain `array_agg(... ORDER BY ord)`, which normalizes to a 1-based
  array before the comparison. Every index guard call in this file passes an
  explicit per-column direction list (`:asc`/`:desc`), including for the 20
  indexes that are all-ascending, so there is exactly one code path to keep
  correct rather than a default that silently only covers the common case.

  A dedicated test (`migrations_renamed_host_test.exs`) reproduces a
  renamed-host shape — every PK/FK/UNIQUE-constraint/index on all 7 tables
  renamed to an arbitrary name — and runs a real `up/1` through
  `Ecto.Migration.Runner`: no error, no duplicate object of any kind, and the
  version marker still lands correctly on a second run.

  ### Phase 0 — this V1 adopts, and changes NOTHING

  `CREATE TABLE IF NOT EXISTS` shape-identical to core's `V135`-through-
  `V164` baseline, under core's exact object names, then a **namespaced**
  marker stamp on the anchor table (`pkpub_schema:1` — an adopted table may
  already carry a foreign comment, so the reader must treat prose as version
  0, never crash on it, never assume it means V1). Because the shape is
  unchanged, core's `ExpectedSchema` manifest stays accurate for every column
  of all 7 tables: **no core release is required and there is no
  release-ordering hazard.** This package releases alone.

  ### Phase 1 — the first real shape change (V2+) is when core must move too

  Before shipping a version that changes any of the 7 tables' shape:

    1. add the objects that version alters to core's manifest generator's
       `@excluded_exact` (`dev_docs/squash/generate_baseline.exs`) and
       regenerate `ExpectedSchema`;
    2. raise this package's `:phoenix_kit` floor to the release that ships
       that regenerated manifest.

  Skipping step 1 means `mix phoenix_kit.repair` restores the old shape
  after every run, silently undoing the new version.

  ### Phase 2 — creation leaves core's baseline at the next squash cycle

  When core cuts its next baseline, module-owned tables are simply not
  included: fresh installs from then on get all 7
  `phoenix_kit_publishing_*` tables from THIS chain's V1 — which is why
  V1's `up/1` ensures the `uuid_generate_v7()` function (and its `pgcrypto`
  extension) exist rather than assuming core's chain already provided them,
  and why every `CREATE TABLE` statement here is already the full, correct
  definition on its own, not merely a shape-matching no-op for an
  already-existing table. Existing installs are untouched — a baseline
  squash only affects fresh installs and below-floor bridging.

  ## What must NEVER happen

  No conditional core migration of the form "module absent → drop the
  tables" — that is nondeterministic (depends on which packages are compiled
  in) and destroys data on a host that merely removed the package. Removing
  this module's data is a human, manual step — see README.md "Removing this
  module" for the operator SQL (7 `DROP TABLE`s in FK-safe order). There is
  deliberately no automated uninstall path, and `down/1` NEVER drops any of
  the 7 tables for ANY target version, including `0` — it only unstamps (or
  re-stamps) the marker on the anchor table. The rows are every host's real
  content groups, posts, versions, per-language content, categories,
  category assignments, and view counters; rolling back this module's chain
  must not destroy any of them.

  The migrated version is tracked as a `pkpub_schema:<N>` COMMENT on
  `phoenix_kit_publishing_groups` — the root of this chain's FK tree
  (`posts.group_uuid`/`categories.group_uuid` both point at it, and nothing
  in this chain points OUT of it), so it is the one table whose independent
  loss would strand every other table's foreign keys. A marker-less table, or
  one carrying a foreign (non-`pkpub_schema:`) comment, reads as version 0 —
  the core-baseline shape before this chain existed.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Modules.Publishing.PublishingCategory
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion

  @initial_version 1
  @current_version 1
  @default_prefix "public"
  @marker_prefix "pkpub_schema:"

  @groups "phoenix_kit_publishing_groups"
  @posts "phoenix_kit_publishing_posts"
  @versions "phoenix_kit_publishing_versions"
  @contents "phoenix_kit_publishing_contents"
  @categories "phoenix_kit_publishing_categories"
  @post_categories "phoenix_kit_publishing_post_categories"
  @post_views "phoenix_kit_publishing_post_views"

  # The single table this chain's marker lives on — this chain's FK-tree
  # root, not a leaf table (see the moduledoc for why).
  @version_table @groups

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  The version a bare, freshly-created set of tables is at (Phase 2 — a
  future install whose core baseline no longer creates these tables).
  """
  @spec initial_version() :: pos_integer()
  def initial_version, do: @initial_version

  @doc """
  The table carrying the `pkpub_schema:<N>` marker for the whole 7-table
  chain.

  Not part of the protocol `mix phoenix_kit.update` calls. Exported so an
  auditor (`mix phoenix_kit_hello_world.audit_migrations`) can verify the
  marker is really a number without hard-coding this table's name.
  """
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  Applies every chain version up to `opts[:version]` (default
  `current_version/0`). Migration-context only — re-reads the installed
  version via `migrated_version/1` before making any change, so a database
  already at (or ahead of) the target does nothing.
  """
  @spec up(keyword() | map()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)

    if migrated_version(opts) < opts.version do
      # Don't assume core's chain ran first (Phase 2): `uuid_generate_v7()`
      # is built on pgcrypto's `gen_random_bytes`, and
      # `ensure_uuid_v7_function/1` does not install extensions — without
      # this call the function is created and then fails on the first
      # insert.
      Helpers.ensure_extension!("pgcrypto")
      Helpers.ensure_uuid_v7_function(opts.prefix)

      opts.prefix
      |> up_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  Rolls back to `opts[:version]` (default `0`). Migration-context only.
  Never drops a table or a row in any of the 7, for any target — see the
  moduledoc.
  """
  @spec down(keyword() | map()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)

    if migrated_version(opts) > opts.version do
      opts.prefix
      |> down_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  The version currently installed, read INSIDE a migration — through
  `Ecto.Migration`'s own `repo()`. No rescue: inside a migration a version
  that cannot be read must abort the transaction, never be guessed at.
  `up/1` and `down/1` call this — never `migrated_version_runtime/1` —
  before making any change.
  """
  @spec migrated_version(keyword() | map()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(repo(), opts.prefix)
  end

  @doc """
  Runtime-safe reader — the one `mix phoenix_kit.update` calls, from a Mix
  task with no migrator running, through PhoenixKit's configured repo
  instead of `Ecto.Migration`'s.

  An invalid prefix is re-raised, matching core's own reader: `0` means
  "not installed here", so reporting it for a bad prefix would tell the
  operator something false and send the updater off to install a schema
  over live data. Genuine unreachability still yields `0`, which is safe
  only because `up/1` re-reads the version in migration context before
  touching anything — a wrong `0` costs a redundant migration file, never
  wrong DDL.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.prefix)
  rescue
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. The
  ownership test suite parses these statements to prove that the object
  names are core's `V135`/`V159`/`V164` names, that the `CREATE TABLE`
  stays shape-identical to core's `ExpectedSchema` manifest, that every
  varchar width is its owning schema's `column_widths/0`, and that nothing
  here can drop a table.

  `target` selects how much of the chain to emit (default
  `current_version/0`): `0` applies nothing (not an operation — clearing
  the marker is `down/1`'s job); `1` is the pure adoption step across all 7
  tables.
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ @default_prefix, target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix)

    if target == 0 do
      []
    else
      v1_statements(prefix, target)
    end
  end

  @doc """
  The SQL `down/1` executes, as data (marker bookkeeping only, on the
  anchor table). V1 changes no shape of its own — it is pure adoption — so
  there is nothing to drop beyond the marker; all 7 tables and every row in
  them are left untouched, for any target including `0`.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ @default_prefix, target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix)
    qualified = Helpers.qualify_table(@version_table, prefix)

    if target > 0 do
      ["COMMENT ON TABLE #{qualified} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{qualified} IS NULL"]
    end
  end

  # ── V1 statement builder ────────────────────────────────────────────────

  defp v1_statements(prefix, target) do
    users = Helpers.qualify_table("phoenix_kit_users", prefix)
    uuid_default = Helpers.uuid_v7_call(prefix)

    q_groups = Helpers.qualify_table(@groups, prefix)
    q_posts = Helpers.qualify_table(@posts, prefix)
    q_versions = Helpers.qualify_table(@versions, prefix)
    q_contents = Helpers.qualify_table(@contents, prefix)
    q_categories = Helpers.qualify_table(@categories, prefix)
    q_post_categories = Helpers.qualify_table(@post_categories, prefix)
    q_post_views = Helpers.qualify_table(@post_views, prefix)

    gw = PublishingGroup.column_widths()
    pw = PublishingPost.column_widths()
    vw = PublishingVersion.column_widths()
    cw = PublishingContent.column_widths()
    catw = PublishingCategory.column_widths()

    # Creation order follows the FK dependency tree: groups has no FK of its
    # own and everything else eventually points back to it.
    tables = [
      """
      CREATE TABLE IF NOT EXISTS #{q_groups} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "name" character varying(#{gw.name}) NOT NULL,
        "slug" character varying(#{gw.slug}) NOT NULL,
        "mode" character varying(#{gw.mode}) DEFAULT 'timestamp'::character varying NOT NULL,
        "position" integer DEFAULT 0 NOT NULL,
        "data" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "status" character varying(#{gw.status}) DEFAULT 'active'::character varying NOT NULL,
        "title_i18n" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "description_i18n" jsonb DEFAULT '{}'::jsonb NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{q_posts} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "group_uuid" uuid NOT NULL,
        "slug" character varying(#{pw.slug}),
        "mode" character varying(#{pw.mode}) DEFAULT 'timestamp'::character varying NOT NULL,
        "post_date" date,
        "post_time" time without time zone,
        "created_by_uuid" uuid,
        "updated_by_uuid" uuid,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "active_version_uuid" uuid,
        "trashed_at" timestamp with time zone
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{q_versions} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "post_uuid" uuid NOT NULL,
        "version_number" integer NOT NULL,
        "status" character varying(#{vw.status}) DEFAULT 'draft'::character varying NOT NULL,
        "created_by_uuid" uuid,
        "data" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "published_at" timestamp with time zone
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{q_contents} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "version_uuid" uuid NOT NULL,
        "language" character varying(#{cw.language}) NOT NULL,
        "title" character varying(#{cw.title}) NOT NULL,
        "content" text,
        "status" character varying(#{cw.status}) DEFAULT 'draft'::character varying NOT NULL,
        "url_slug" character varying(#{cw.url_slug}),
        "data" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{q_categories} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "group_uuid" uuid NOT NULL,
        "parent_uuid" uuid,
        "name" character varying(#{catw.name}) NOT NULL,
        "slug" character varying(#{catw.slug}) NOT NULL,
        "name_i18n" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "description" character varying(#{catw.description}),
        "position" integer DEFAULT 0 NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{q_post_categories} (
        "post_uuid" uuid NOT NULL,
        "category_uuid" uuid NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{q_post_views} (
        "post_uuid" uuid NOT NULL,
        "view_date" date NOT NULL,
        "count" integer DEFAULT 0 NOT NULL
      )
      """
    ]

    pkeys = [
      pkey_guard(@contents, q_contents, ["uuid"]),
      pkey_guard(@groups, q_groups, ["uuid"]),
      pkey_guard(@posts, q_posts, ["uuid"]),
      pkey_guard(@versions, q_versions, ["uuid"]),
      pkey_guard(@categories, q_categories, ["uuid"]),
      pkey_guard(@post_categories, q_post_categories, ["post_uuid", "category_uuid"]),
      pkey_guard(@post_views, q_post_views, ["post_uuid", "view_date"])
    ]

    unique_constraints = [
      unique_constraint_guard(
        q_categories,
        "phoenix_kit_publishing_categories_group_slug_uniq",
        ["group_uuid", "slug"]
      )
    ]

    # No CHECK constraint exists on any of the 7 tables — confirmed by the
    # three-source research pass documented in the moduledoc.

    indexes = [
      index_guard(
        "idx_publishing_contents_data_gin",
        q_contents,
        false,
        "gin",
        ["data"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_contents_url_slug",
        q_contents,
        false,
        "btree",
        ["url_slug"],
        [:asc],
        "(url_slug IS NOT NULL)"
      ),
      index_guard(
        "idx_publishing_contents_version_id",
        q_contents,
        false,
        "btree",
        ["version_uuid"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_contents_version_language",
        q_contents,
        true,
        "btree",
        ["version_uuid", "language"],
        [:asc, :asc],
        nil
      ),
      index_guard(
        "idx_publishing_groups_slug",
        q_groups,
        true,
        "btree",
        ["slug"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_groups_status",
        q_groups,
        false,
        "btree",
        ["status"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_posts_created_by",
        q_posts,
        false,
        "btree",
        ["created_by_uuid"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_posts_group_date_time",
        q_posts,
        false,
        "btree",
        ["group_uuid", "post_date", "post_time"],
        [:asc, :desc, :desc],
        "(post_date IS NOT NULL)"
      ),
      index_guard(
        "idx_publishing_posts_group_id",
        q_posts,
        false,
        "btree",
        ["group_uuid"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_posts_group_slug",
        q_posts,
        true,
        "btree",
        ["group_uuid", "slug"],
        [:asc, :asc],
        "(slug IS NOT NULL)"
      ),
      index_guard(
        "idx_publishing_posts_updated_by",
        q_posts,
        false,
        "btree",
        ["updated_by_uuid"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_posts_group_date_time_unique",
        q_posts,
        true,
        "btree",
        ["group_uuid", "post_date", "post_time"],
        [:asc, :asc, :asc],
        "((post_date IS NOT NULL) AND (post_time IS NOT NULL))"
      ),
      index_guard(
        "idx_publishing_posts_active_version",
        q_posts,
        false,
        "btree",
        ["active_version_uuid"],
        [:asc],
        "(active_version_uuid IS NOT NULL)"
      ),
      index_guard(
        "idx_publishing_posts_trashed_at",
        q_posts,
        false,
        "btree",
        ["trashed_at"],
        [:asc],
        "(trashed_at IS NULL)"
      ),
      index_guard(
        "idx_publishing_versions_created_by",
        q_versions,
        false,
        "btree",
        ["created_by_uuid"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_versions_post_id",
        q_versions,
        false,
        "btree",
        ["post_uuid"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_versions_post_number",
        q_versions,
        true,
        "btree",
        ["post_uuid", "version_number"],
        [:asc, :asc],
        nil
      ),
      index_guard(
        "idx_publishing_versions_post_status",
        q_versions,
        false,
        "btree",
        ["post_uuid", "status"],
        [:asc, :asc],
        nil
      ),
      index_guard(
        "idx_publishing_versions_published_at",
        q_versions,
        false,
        "btree",
        ["published_at"],
        [:desc],
        "(published_at IS NOT NULL)"
      ),
      index_guard(
        "idx_publishing_categories_group",
        q_categories,
        false,
        "btree",
        ["group_uuid"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_categories_parent",
        q_categories,
        false,
        "btree",
        ["parent_uuid"],
        [:asc],
        nil
      ),
      index_guard(
        "idx_publishing_post_categories_category",
        q_post_categories,
        false,
        "btree",
        ["category_uuid"],
        [:asc],
        nil
      )
    ]

    fks = [
      fk_guard(
        q_contents,
        "fk_publishing_contents_version",
        "version_uuid",
        q_versions,
        "CASCADE"
      ),
      fk_guard(q_posts, "fk_publishing_posts_created_by", "created_by_uuid", users, "SET NULL"),
      fk_guard(q_posts, "fk_publishing_posts_group", "group_uuid", q_groups, "CASCADE"),
      fk_guard(q_posts, "fk_publishing_posts_updated_by", "updated_by_uuid", users, "SET NULL"),
      fk_guard(
        q_posts,
        "fk_publishing_posts_active_version",
        "active_version_uuid",
        q_versions,
        "SET NULL"
      ),
      fk_guard(
        q_versions,
        "fk_publishing_versions_created_by",
        "created_by_uuid",
        users,
        "SET NULL"
      ),
      fk_guard(q_versions, "fk_publishing_versions_post", "post_uuid", q_posts, "CASCADE"),
      fk_guard(
        q_categories,
        "phoenix_kit_publishing_categories_group_uuid_fkey",
        "group_uuid",
        q_groups,
        "CASCADE"
      ),
      fk_guard(
        q_categories,
        "phoenix_kit_publishing_categories_parent_uuid_fkey",
        "parent_uuid",
        q_categories,
        "SET NULL"
      ),
      fk_guard(
        q_post_categories,
        "phoenix_kit_publishing_post_categories_category_uuid_fkey",
        "category_uuid",
        q_categories,
        "CASCADE"
      ),
      fk_guard(
        q_post_categories,
        "phoenix_kit_publishing_post_categories_post_uuid_fkey",
        "post_uuid",
        q_posts,
        "CASCADE"
      ),
      fk_guard(
        q_post_views,
        "phoenix_kit_publishing_post_views_post_uuid_fkey",
        "post_uuid",
        q_posts,
        "CASCADE"
      )
    ]

    marker = ["COMMENT ON TABLE #{q_groups} IS '#{@marker_prefix}#{target}'"]

    tables ++ pkeys ++ unique_constraints ++ indexes ++ fks ++ marker
  end

  # Semantic: "does this table already have ANY primary key", not "does a
  # constraint with this exact name exist" — a table whose PK predates a
  # host-level table rename (renaming a table never renames its own
  # constraints) still has a real, functioning primary key under its old
  # name, and adding a second one is a hard Postgres error, not a silent
  # duplicate. `regclass` resolves `qualified` by the table's CURRENT name
  # regardless of that history, since a rename never changes the OID.
  # `columns` may be more than one element (the composite PKs on
  # `_post_categories`/`_post_views`) — column names are not quoted because
  # every one of ours is a plain lowercase identifier, same convention as
  # `fk_guard` below.
  defp pkey_guard(table, qualified, columns) do
    columns_sql = Enum.join(columns, ", ")

    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = '#{qualified}'::regclass AND contype = 'p'
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (#{columns_sql});
      END IF;
    END
    $$
    """
  end

  # Semantic: "does this table already have a UNIQUE constraint over exactly
  # this ordered column set", via `contype = 'u'` plus `conkey` resolved to
  # column names through `pg_attribute` (same normalization `index_guard`
  # below needs for `indkey`) — not a check for the constraint's exact name.
  # `phoenix_kit_publishing_categories_group_slug_uniq` is the only UNIQUE
  # constraint (as opposed to unique INDEX) across all 7 tables.
  defp unique_constraint_guard(qualified, constraint_name, columns) do
    columns_sql = Enum.join(columns, ", ")
    columns_array = Enum.map_join(columns, ", ", &"'#{&1}'")
    column_count = length(columns)

    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = '#{qualified}'::regclass
          AND contype = 'u'
          AND array_length(conkey, 1) = #{column_count}
          AND (
            SELECT array_agg(a.attname ORDER BY k.ord)
            FROM unnest(conkey) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = conrelid AND a.attnum = k.attnum
          ) = ARRAY[#{columns_array}]::name[]
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{constraint_name} UNIQUE (#{columns_sql});
      END IF;
    END
    $$
    """
  end

  # Semantic: "does this table already have a foreign key from `column` to
  # `references`", matched via `conrelid`/`confrelid` (both resolved through
  # `regclass`, immune to either table having been renamed — including the
  # `_categories.parent_uuid` self-referencing FK, where source and target
  # `regclass` are the same relation) and `conkey` (the source column, by
  # attnum — immune to the constraint's own name). A name-based guard would
  # silently ADD A DUPLICATE FK under the new name next to an
  # already-functioning, differently-named one — this is not hypothetical,
  # the same defect already left 3 duplicate UNIQUE indexes on a real host
  # for a sibling module (`phoenix_kit_posts`) before this fix.
  #
  # Deliberately NOT part of the match: `on_delete` (the referential
  # action). This is an ADOPTION guard, not a shape-repair tool — if a
  # host's existing FK (found by table/column/target alone) already has a
  # different `ON DELETE` behavior than the `on_delete` argument below would
  # create, this guard leaves it exactly as it is rather than trying to
  # converge the two. A real disagreement there would be a legitimate V2+
  # shape change (with its own manifest/floor implications, see the
  # moduledoc's Phase 1), never something V1's silent adoption should paper
  # over by dropping and re-adding someone's live constraint.
  defp fk_guard(qualified, constraint_name, column, references, on_delete) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = '#{qualified}'::regclass
          AND contype = 'f'
          AND confrelid = '#{references}'::regclass
          AND conkey = ARRAY[(
            SELECT attnum FROM pg_attribute
            WHERE attrelid = '#{qualified}'::regclass AND attname = '#{column}'
          )]::smallint[]
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{constraint_name} FOREIGN KEY (#{column}) REFERENCES #{references}(uuid) ON DELETE #{on_delete};
      END IF;
    END
    $$
    """
  end

  # Semantic: "does this table already have an index on these columns, in
  # this order, with this uniqueness, this access method, this partial
  # predicate, and this per-column sort direction" — NOT merely "is there an
  # index with this exact name". A bare `CREATE INDEX IF NOT EXISTS <name>
  # ...` only guards against its own literal name; it does nothing to stop a
  # second, differently-named index with an identical definition (the
  # `phoenix_kit_posts` duplicate-index incident this guard exists to
  # prevent here). `i.indkey::int2[]` resolved to column names via
  # `pg_attribute`, in index-column order, compared against the expected
  # column list; `pg_get_expr(i.indpred, i.indrelid)` is Postgres's own
  # canonical rendering of a partial index's predicate (NULL when the index
  # isn't partial) — both sides of that comparison are verified-live text,
  # not guessed. `CREATE INDEX` goes through `EXECUTE` (with the literal's
  # quotes doubled) so the whole statement is one quoted string inside the
  # block — PL/pgSQL could run it directly, `EXECUTE` is a choice, not a need.
  #
  # `i.indexprs IS NULL` and the `array_length` check below both exist for
  # the same real bug, caught by testing against a live catalog rather than
  # reading the query: an EXPRESSION index stores `0` — not a real attnum —
  # in `indkey` for its expression column. `pg_attribute` has no row for
  # attnum `0`, so the `JOIN pg_attribute` above silently DROPS that
  # position instead of erroring, shortening the aggregated column-name
  # array and making an unrelated expression index misread as a plain-column
  # match. `indexprs IS NULL` alone would already exclude every expression
  # index (none of this chain's own indexes are ever expression-based); the
  # `array_length` check is kept alongside it as an independent guard
  # against the same join silently dropping a row for any other reason.
  #
  # `directions` is a per-column `:asc`/`:desc` list, always explicit (never
  # defaulted) — see the moduledoc's "`DESC` ordering" section for why a
  # direct `indoption::int2[] = ARRAY[...]::int2[]` comparison is FALSE even
  # when every element matches (a zero-based vs. one-based array lower-bound
  # mismatch), and why the fix is the same `unnest/array_agg` normalization
  # `indkey` already needs.
  defp index_guard(name, qualified, unique?, method, columns, directions, predicate) do
    columns_sql =
      columns
      |> Enum.zip(directions)
      |> Enum.map_join(", ", fn
        {column, :desc} -> "#{column} DESC"
        {column, :asc} -> column
      end)

    where_clause = if predicate, do: " WHERE #{predicate}", else: ""
    unique_sql = if unique?, do: "UNIQUE ", else: ""
    columns_array = Enum.map_join(columns, ", ", &"'#{&1}'")
    column_count = length(columns)

    indoption_array =
      Enum.map_join(directions, ", ", fn
        :desc -> "3"
        :asc -> "0"
      end)

    predicate_condition =
      if predicate do
        "pg_get_expr(i.indpred, i.indrelid) = '#{predicate}'"
      else
        "i.indpred IS NULL"
      end

    # The whole dynamic statement is embedded inside a single-quoted
    # `EXECUTE '...'` argument, so any single quote it contains must be
    # SQL-escaped by doubling it — none of this chain's own predicates have
    # one today, but the same rule applies here as everywhere else in this
    # file that builds a string for `EXECUTE`.
    create_index_sql =
      "CREATE #{unique_sql}INDEX IF NOT EXISTS #{name} ON #{qualified} USING #{method} (#{columns_sql})#{where_clause}"

    escaped_create_index_sql = String.replace(create_index_sql, "'", "''")

    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_index i
        JOIN pg_class ic ON ic.oid = i.indexrelid
        JOIN pg_am am ON am.oid = ic.relam
        WHERE i.indrelid = '#{qualified}'::regclass
          AND i.indisunique = #{unique?}
          AND am.amname = '#{method}'
          AND i.indexprs IS NULL
          AND array_length(i.indkey::int2[], 1) = #{column_count}
          AND #{predicate_condition}
          AND (
            SELECT array_agg(elem ORDER BY ord)
            FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord)
          ) = ARRAY[#{indoption_array}]::int2[]
          AND (
            SELECT array_agg(a.attname ORDER BY k.ord)
            FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
          ) = ARRAY[#{columns_array}]::name[]
      ) THEN
        EXECUTE '#{escaped_create_index_sql}';
      END IF;
    END
    $$
    """
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{})
    prefix = validated_prefix(Map.get(opts, :prefix) || @default_prefix)

    opts
    |> Map.put(:prefix, prefix)
    |> Map.put_new(:version, version)
  end

  defp read_version(repo, prefix) do
    if table_exists?(repo, prefix) do
      repo |> table_comment(prefix) |> parse_version()
    else
      0
    end
  end

  defp table_exists?(repo, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = $1 AND table_schema = $2
    )
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[exists?]]}} -> exists?
      {:error, error} -> raise error
    end
  end

  defp table_comment(repo, prefix) do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = $1 AND n.nspname = $2
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[comment]]}} -> comment
      {:ok, %{rows: []}} -> nil
      {:error, error} -> raise error
    end
  end

  defp parse_version(@marker_prefix <> n) do
    case Integer.parse(n) do
      {version, ""} when version >= 0 -> version
      _ -> 0
    end
  end

  defp parse_version(_), do: 0

  defp validate_target!(target) when target > @current_version do
    raise ArgumentError,
          "PhoenixKitPublishing.Migrations has no version #{target} " <>
            "(current_version/0 is #{@current_version}); stamping it would make every " <>
            "later version look already applied"
  end

  defp validate_target!(_target), do: :ok

  # `phoenix_kit` is a normal (non-optional) dependency of this package, so
  # `Helpers` is always loaded.
  defp validated_prefix(prefix) do
    Helpers.validate_prefix!(prefix)
    prefix
  end
end
