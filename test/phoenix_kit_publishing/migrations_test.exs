defmodule PhoenixKitPublishing.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKitPublishing.Migrations

  @moduledoc """
  Pins the ownership design for `phoenix_kit_publishing`: this package owns
  all 7 `phoenix_kit_publishing_*` tables' FUTURE shape through its module
  migration chain, while core's `V59`-through-`V164` baseline still creates
  every one of them on every install, and the chain's V1 merely ADOPTS that
  shape (stamps the `pkpub_schema:` marker on the anchor table,
  `phoenix_kit_publishing_groups`, changes no shape at all — see
  `PhoenixKitPublishing.Migrations`' moduledoc).

  Every test here is a pure data/string assertion over
  `up_statements/2`/`down_statements/2`/`up/1`/`down/1`-as-source-text and
  core's static `PhoenixKit.Migrations.ExpectedSchema.objects/1` manifest —
  none of them touch a database.

  Unlike `PhoenixKitNewsletters.Migrations` (this chain's closest sibling),
  none of the 7 tables here carries a CHECK constraint, so there is no
  check-guard section and no CHECK-name-or-definition fallback to test —
  see `Migrations`' own moduledoc, "Ownership situation". A test below
  ("every guard is semantic...") asserts the absence directly, so a future
  edit that copies a CHECK guard in from a sibling chain without adapting it
  is caught rather than silently shipped.
  """

  @publishing_tables ~w(
    phoenix_kit_publishing_groups
    phoenix_kit_publishing_posts
    phoenix_kit_publishing_versions
    phoenix_kit_publishing_contents
    phoenix_kit_publishing_categories
    phoenix_kit_publishing_post_categories
    phoenix_kit_publishing_post_views
  )

  test "PhoenixKit.Modules.Publishing declares the module-owned migration chain" do
    # Assert the VALUE, not `function_exported?/3` — `use PhoenixKit.Module`
    # injects an overridable default `migration_module/0`, so exportedness
    # says nothing about whether this module declares one.
    assert Code.ensure_loaded?(Publishing)

    assert Publishing.migration_module() == Migrations,
           """
           PhoenixKit.Modules.Publishing no longer declares its migration chain \
           (migration_module/0 returned #{inspect(Publishing.migration_module())}).

           The chain is how phoenix_kit_publishing's future shape is versioned
           (pkpub_schema marker) and how `mix phoenix_kit.update` migrates hosts.
           """
  end

  describe "the coordinator implements the protocol" do
    alias PhoenixKit.Migrations.Postgres.Helpers

    test "current_version/0 and version_table/0" do
      assert Migrations.current_version() == 1
      assert Migrations.version_table() == "phoenix_kit_publishing_groups"
    end

    test "initial_version/0" do
      assert Migrations.initial_version() == 1
    end

    # `mix phoenix_kit_hello_world.audit_migrations` (the canonical auditor
    # for this protocol) refuses to drive a coordinator missing any of these
    # five — `mix phoenix_kit.update` itself only calls
    # `migrated_version_runtime/1` + `current_version/0`, but `up/1` needs
    # `migrated_version/1` to re-read the version it is about to change.
    test "exports the full five-function protocol, plus version_table/0 and initial_version/0" do
      for {fun, arity} <- [
            {:current_version, 0},
            {:up, 1},
            {:down, 1},
            {:migrated_version, 1},
            {:migrated_version_runtime, 1},
            {:version_table, 0},
            {:initial_version, 0}
          ] do
        assert function_exported?(Migrations, fun, arity),
               "#{inspect(Migrations)} does not export #{fun}/#{arity}"
      end
    end

    # The marker decides whether any LATER version ever runs: core's
    # `classify/2` reads it and answers `:up_to_date` for every version at or
    # below it. Stamping a version this chain does not have therefore skips
    # V2 and everything after it, silently and permanently.
    test "refuses to stamp a version this chain does not have" do
      too_high = Migrations.current_version() + 1

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.up_statements("public", too_high)
      end

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.down_statements("public", too_high)
      end

      # The ceiling itself stays reachable, or the guard would just break
      # the chain instead of bounding it.
      assert Migrations.up_statements("public", Migrations.current_version()) != []
    end

    # `validate_target!` also gates `migrated_version/1` and
    # `migrated_version_runtime/1` (both default their target to
    # `initial_version/0`, well under the ceiling) — 0 and 1 must both stay
    # reachable for every public builder.
    test "validate_target! admits 0 and 1, and nothing above current_version/0" do
      for target <- [0, 1] do
        assert Migrations.up_statements("public", target) |> is_list()
        assert Migrations.down_statements("public", target) |> is_list()
      end

      assert_raise ArgumentError, fn -> Migrations.up_statements("public", 2) end
      assert_raise ArgumentError, fn -> Migrations.down_statements("public", 2) end
    end

    # This chain interpolates the prefix into every object it creates, and
    # Postgres TRUNCATES an identifier past 63 bytes silently rather than
    # rejecting it — so a prefix core would refuse yields object names that
    # differ from core's while every command still exits 0, breaking the
    # contract adoption rests on. The rules are therefore core's, and this
    # test compares against core rather than restating them.
    test "every public builder that emits SQL validates its own prefix" do
      for fun <- [:up_statements, :down_statements] do
        assert_raise ArgumentError, fn -> apply(Migrations, fun, ["EVIL\";DROP"]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [String.duplicate("a", 30)]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [123]) end
      end
    end

    test "invalid prefix error shape matches Helpers.validate_prefix!/1's own" do
      for fun <- [:up_statements, :down_statements] do
        error =
          try do
            apply(Migrations, fun, ["Bad-Prefix"])
            flunk("expected #{fun} to raise for an invalid prefix")
          rescue
            e in ArgumentError -> e
          end

        assert Exception.message(error) =~ "invalid PhoenixKit schema prefix"
      end

      for fun <- [:migrated_version, :migrated_version_runtime] do
        assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
          apply(Migrations, fun, [[prefix: "Bad-Prefix"]])
        end
      end
    end

    test "the prefix rules are core's, case and length included" do
      for prefix <- [
            "public",
            "publishing_alt",
            "Publishing",
            "9leading_digit",
            "has-dash",
            String.duplicate("a", 20),
            String.duplicate("a", 21),
            String.duplicate("a", 30)
          ] do
        core_accepts =
          try do
            Helpers.validate_prefix!(prefix)
            true
          rescue
            ArgumentError -> false
          end

        ours_accepts =
          try do
            Migrations.up_statements(prefix)
            true
          rescue
            ArgumentError -> false
          end

        assert ours_accepts == core_accepts,
               "prefix #{inspect(prefix)}: core #{if core_accepts, do: "accepts", else: "rejects"}, " <>
                 "this chain #{if ours_accepts, do: "accepts", else: "rejects"} — the two must agree, " <>
                 "or the object names this chain creates stop matching core's"
      end
    end

    test "rejects a prefix that cannot be safely interpolated into DDL" do
      for bad <- ["public.\"; DROP TABLE x; --", "1st", "a-b", ""] do
        assert_raise ArgumentError, fn -> Migrations.up_statements(bad) end
        assert_raise ArgumentError, fn -> Migrations.down_statements(bad, 0) end
      end
    end
  end

  describe "the chain's per-version statement content is pinned (drift guard)" do
    # V1 is a PUBLISHED version once this ships. A host that has already run
    # it will never run it again, so editing its content does not "fix" that
    # host — it silently splits fresh installs from existing ones. Pinning
    # the exact normalised text makes that split a deliberate, visible diff
    # instead of an accidental one buried in a refactor.
    #
    # Captured from a REAL run of `up_statements("public", 1)` in this same
    # process (`mix run`, then pasted verbatim) — never hand-typed.
    defp normalised(statements),
      do: Enum.map(statements, &(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))

    test "V1's published statements are frozen" do
      v1 = Migrations.up_statements("public", 1) |> normalised()

      assert v1 == [
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_publishing_groups ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"name\" character varying(255) NOT NULL, \"slug\" character varying(255) NOT NULL, \"mode\" character varying(20) DEFAULT 'timestamp'::character varying NOT NULL, \"position\" integer DEFAULT 0 NOT NULL, \"data\" jsonb DEFAULT '{}'::jsonb NOT NULL, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL, \"status\" character varying(20) DEFAULT 'active'::character varying NOT NULL, \"title_i18n\" jsonb DEFAULT '{}'::jsonb NOT NULL, \"description_i18n\" jsonb DEFAULT '{}'::jsonb NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_publishing_posts ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"group_uuid\" uuid NOT NULL, \"slug\" character varying(500), \"mode\" character varying(20) DEFAULT 'timestamp'::character varying NOT NULL, \"post_date\" date, \"post_time\" time without time zone, \"created_by_uuid\" uuid, \"updated_by_uuid\" uuid, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL, \"active_version_uuid\" uuid, \"trashed_at\" timestamp with time zone )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_publishing_versions ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"post_uuid\" uuid NOT NULL, \"version_number\" integer NOT NULL, \"status\" character varying(20) DEFAULT 'draft'::character varying NOT NULL, \"created_by_uuid\" uuid, \"data\" jsonb DEFAULT '{}'::jsonb NOT NULL, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL, \"published_at\" timestamp with time zone )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_publishing_contents ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"version_uuid\" uuid NOT NULL, \"language\" character varying(10) NOT NULL, \"title\" character varying(500) NOT NULL, \"content\" text, \"status\" character varying(20) DEFAULT 'draft'::character varying NOT NULL, \"url_slug\" character varying(500), \"data\" jsonb DEFAULT '{}'::jsonb NOT NULL, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_publishing_categories ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"group_uuid\" uuid NOT NULL, \"parent_uuid\" uuid, \"name\" character varying(255) NOT NULL, \"slug\" character varying(255) NOT NULL, \"name_i18n\" jsonb DEFAULT '{}'::jsonb NOT NULL, \"description\" character varying(1024), \"position\" integer DEFAULT 0 NOT NULL, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_publishing_post_categories ( \"post_uuid\" uuid NOT NULL, \"category_uuid\" uuid NOT NULL, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_publishing_post_views ( \"post_uuid\" uuid NOT NULL, \"view_date\" date NOT NULL, \"count\" integer DEFAULT 0 NOT NULL )",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_contents'::regclass AND contype = 'p' ) THEN ALTER TABLE public.phoenix_kit_publishing_contents ADD CONSTRAINT phoenix_kit_publishing_contents_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_groups'::regclass AND contype = 'p' ) THEN ALTER TABLE public.phoenix_kit_publishing_groups ADD CONSTRAINT phoenix_kit_publishing_groups_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_posts'::regclass AND contype = 'p' ) THEN ALTER TABLE public.phoenix_kit_publishing_posts ADD CONSTRAINT phoenix_kit_publishing_posts_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_versions'::regclass AND contype = 'p' ) THEN ALTER TABLE public.phoenix_kit_publishing_versions ADD CONSTRAINT phoenix_kit_publishing_versions_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_categories'::regclass AND contype = 'p' ) THEN ALTER TABLE public.phoenix_kit_publishing_categories ADD CONSTRAINT phoenix_kit_publishing_categories_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_post_categories'::regclass AND contype = 'p' ) THEN ALTER TABLE public.phoenix_kit_publishing_post_categories ADD CONSTRAINT phoenix_kit_publishing_post_categories_pkey PRIMARY KEY (post_uuid, category_uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_post_views'::regclass AND contype = 'p' ) THEN ALTER TABLE public.phoenix_kit_publishing_post_views ADD CONSTRAINT phoenix_kit_publishing_post_views_pkey PRIMARY KEY (post_uuid, view_date); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_categories'::regclass AND contype = 'u' AND array_length(conkey, 1) = 2 AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(conkey) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = conrelid AND a.attnum = k.attnum ) = ARRAY['group_uuid', 'slug']::name[] ) THEN ALTER TABLE public.phoenix_kit_publishing_categories ADD CONSTRAINT phoenix_kit_publishing_categories_group_slug_uniq UNIQUE (group_uuid, slug); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_contents'::regclass AND i.indisunique = false AND am.amname = 'gin' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['data']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_contents_data_gin ON public.phoenix_kit_publishing_contents USING gin (data)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_contents'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND pg_get_expr(i.indpred, i.indrelid) = '(url_slug IS NOT NULL)' AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['url_slug']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_contents_url_slug ON public.phoenix_kit_publishing_contents USING btree (url_slug) WHERE (url_slug IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_contents'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['version_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_contents_version_id ON public.phoenix_kit_publishing_contents USING btree (version_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_contents'::regclass AND i.indisunique = true AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 2 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0, 0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['version_uuid', 'language']::name[] ) THEN EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_contents_version_language ON public.phoenix_kit_publishing_contents USING btree (version_uuid, language)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_groups'::regclass AND i.indisunique = true AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['slug']::name[] ) THEN EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_groups_slug ON public.phoenix_kit_publishing_groups USING btree (slug)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_groups'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['status']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_groups_status ON public.phoenix_kit_publishing_groups USING btree (status)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_posts'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['created_by_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_posts_created_by ON public.phoenix_kit_publishing_posts USING btree (created_by_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_posts'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 3 AND pg_get_expr(i.indpred, i.indrelid) = '(post_date IS NOT NULL)' AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0, 3, 3]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['group_uuid', 'post_date', 'post_time']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_date_time ON public.phoenix_kit_publishing_posts USING btree (group_uuid, post_date DESC, post_time DESC) WHERE (post_date IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_posts'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['group_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_id ON public.phoenix_kit_publishing_posts USING btree (group_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_posts'::regclass AND i.indisunique = true AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 2 AND pg_get_expr(i.indpred, i.indrelid) = '(slug IS NOT NULL)' AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0, 0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['group_uuid', 'slug']::name[] ) THEN EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_posts_group_slug ON public.phoenix_kit_publishing_posts USING btree (group_uuid, slug) WHERE (slug IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_posts'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['updated_by_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_posts_updated_by ON public.phoenix_kit_publishing_posts USING btree (updated_by_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_posts'::regclass AND i.indisunique = true AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 3 AND pg_get_expr(i.indpred, i.indrelid) = '((post_date IS NOT NULL) AND (post_time IS NOT NULL))' AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0, 0, 0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['group_uuid', 'post_date', 'post_time']::name[] ) THEN EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_posts_group_date_time_unique ON public.phoenix_kit_publishing_posts USING btree (group_uuid, post_date, post_time) WHERE ((post_date IS NOT NULL) AND (post_time IS NOT NULL))'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_posts'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND pg_get_expr(i.indpred, i.indrelid) = '(active_version_uuid IS NOT NULL)' AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['active_version_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_posts_active_version ON public.phoenix_kit_publishing_posts USING btree (active_version_uuid) WHERE (active_version_uuid IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_posts'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND pg_get_expr(i.indpred, i.indrelid) = '(trashed_at IS NULL)' AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['trashed_at']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_posts_trashed_at ON public.phoenix_kit_publishing_posts USING btree (trashed_at) WHERE (trashed_at IS NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_versions'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['created_by_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_versions_created_by ON public.phoenix_kit_publishing_versions USING btree (created_by_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_versions'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['post_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_versions_post_id ON public.phoenix_kit_publishing_versions USING btree (post_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_versions'::regclass AND i.indisunique = true AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 2 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0, 0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['post_uuid', 'version_number']::name[] ) THEN EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_versions_post_number ON public.phoenix_kit_publishing_versions USING btree (post_uuid, version_number)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_versions'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 2 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0, 0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['post_uuid', 'status']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_versions_post_status ON public.phoenix_kit_publishing_versions USING btree (post_uuid, status)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_versions'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND pg_get_expr(i.indpred, i.indrelid) = '(published_at IS NOT NULL)' AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[3]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['published_at']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_versions_published_at ON public.phoenix_kit_publishing_versions USING btree (published_at DESC) WHERE (published_at IS NOT NULL)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_categories'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['group_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_categories_group ON public.phoenix_kit_publishing_categories USING btree (group_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_categories'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['parent_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_categories_parent ON public.phoenix_kit_publishing_categories USING btree (parent_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam WHERE i.indrelid = 'public.phoenix_kit_publishing_post_categories'::regclass AND i.indisunique = false AND am.amname = 'btree' AND i.indexprs IS NULL AND array_length(i.indkey::int2[], 1) = 1 AND i.indpred IS NULL AND ( SELECT array_agg(elem ORDER BY ord) FROM unnest(i.indoption::int2[]) WITH ORDINALITY AS u(elem, ord) ) = ARRAY[0]::int2[] AND ( SELECT array_agg(a.attname ORDER BY k.ord) FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord) JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ) = ARRAY['category_uuid']::name[] ) THEN EXECUTE 'CREATE INDEX IF NOT EXISTS idx_publishing_post_categories_category ON public.phoenix_kit_publishing_post_categories USING btree (category_uuid)'; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_contents'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_publishing_versions'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_contents'::regclass AND attname = 'version_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_contents ADD CONSTRAINT fk_publishing_contents_version FOREIGN KEY (version_uuid) REFERENCES public.phoenix_kit_publishing_versions(uuid) ON DELETE CASCADE; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_posts'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_users'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_posts'::regclass AND attname = 'created_by_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_posts ADD CONSTRAINT fk_publishing_posts_created_by FOREIGN KEY (created_by_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_posts'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_publishing_groups'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_posts'::regclass AND attname = 'group_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_posts ADD CONSTRAINT fk_publishing_posts_group FOREIGN KEY (group_uuid) REFERENCES public.phoenix_kit_publishing_groups(uuid) ON DELETE CASCADE; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_posts'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_users'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_posts'::regclass AND attname = 'updated_by_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_posts ADD CONSTRAINT fk_publishing_posts_updated_by FOREIGN KEY (updated_by_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_posts'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_publishing_versions'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_posts'::regclass AND attname = 'active_version_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_posts ADD CONSTRAINT fk_publishing_posts_active_version FOREIGN KEY (active_version_uuid) REFERENCES public.phoenix_kit_publishing_versions(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_versions'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_users'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_versions'::regclass AND attname = 'created_by_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_versions ADD CONSTRAINT fk_publishing_versions_created_by FOREIGN KEY (created_by_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_versions'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_publishing_posts'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_versions'::regclass AND attname = 'post_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_versions ADD CONSTRAINT fk_publishing_versions_post FOREIGN KEY (post_uuid) REFERENCES public.phoenix_kit_publishing_posts(uuid) ON DELETE CASCADE; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_categories'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_publishing_groups'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_categories'::regclass AND attname = 'group_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_categories ADD CONSTRAINT phoenix_kit_publishing_categories_group_uuid_fkey FOREIGN KEY (group_uuid) REFERENCES public.phoenix_kit_publishing_groups(uuid) ON DELETE CASCADE; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_categories'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_publishing_categories'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_categories'::regclass AND attname = 'parent_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_categories ADD CONSTRAINT phoenix_kit_publishing_categories_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES public.phoenix_kit_publishing_categories(uuid) ON DELETE SET NULL; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_post_categories'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_publishing_categories'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_post_categories'::regclass AND attname = 'category_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_post_categories ADD CONSTRAINT phoenix_kit_publishing_post_categories_category_uuid_fkey FOREIGN KEY (category_uuid) REFERENCES public.phoenix_kit_publishing_categories(uuid) ON DELETE CASCADE; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_post_categories'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_publishing_posts'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_post_categories'::regclass AND attname = 'post_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_post_categories ADD CONSTRAINT phoenix_kit_publishing_post_categories_post_uuid_fkey FOREIGN KEY (post_uuid) REFERENCES public.phoenix_kit_publishing_posts(uuid) ON DELETE CASCADE; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint WHERE conrelid = 'public.phoenix_kit_publishing_post_views'::regclass AND contype = 'f' AND confrelid = 'public.phoenix_kit_publishing_posts'::regclass AND conkey = ARRAY[( SELECT attnum FROM pg_attribute WHERE attrelid = 'public.phoenix_kit_publishing_post_views'::regclass AND attname = 'post_uuid' )]::smallint[] ) THEN ALTER TABLE public.phoenix_kit_publishing_post_views ADD CONSTRAINT phoenix_kit_publishing_post_views_post_uuid_fkey FOREIGN KEY (post_uuid) REFERENCES public.phoenix_kit_publishing_posts(uuid) ON DELETE CASCADE; END IF; END $$",
               "COMMENT ON TABLE public.phoenix_kit_publishing_groups IS 'pkpub_schema:1'"
             ]
    end
  end

  describe "the chain DDL adopts core's V59-through-V164 shape" do
    test "V1 uses core's exact object names (shape-identical adoption)" do
      statements = Enum.join(Migrations.up_statements(), "\n")

      for name <- [
            "phoenix_kit_publishing_contents_pkey",
            "phoenix_kit_publishing_groups_pkey",
            "phoenix_kit_publishing_posts_pkey",
            "phoenix_kit_publishing_versions_pkey",
            "phoenix_kit_publishing_categories_pkey",
            "phoenix_kit_publishing_post_categories_pkey",
            "phoenix_kit_publishing_post_views_pkey",
            "phoenix_kit_publishing_categories_group_slug_uniq",
            "idx_publishing_contents_data_gin",
            "idx_publishing_contents_url_slug",
            "idx_publishing_contents_version_id",
            "idx_publishing_contents_version_language",
            "idx_publishing_groups_slug",
            "idx_publishing_groups_status",
            "idx_publishing_posts_created_by",
            "idx_publishing_posts_group_date_time",
            "idx_publishing_posts_group_id",
            "idx_publishing_posts_group_slug",
            "idx_publishing_posts_updated_by",
            "idx_publishing_posts_group_date_time_unique",
            "idx_publishing_posts_active_version",
            "idx_publishing_posts_trashed_at",
            "idx_publishing_versions_created_by",
            "idx_publishing_versions_post_id",
            "idx_publishing_versions_post_number",
            "idx_publishing_versions_post_status",
            "idx_publishing_versions_published_at",
            "idx_publishing_categories_group",
            "idx_publishing_categories_parent",
            "idx_publishing_post_categories_category",
            "fk_publishing_contents_version",
            "fk_publishing_posts_created_by",
            "fk_publishing_posts_group",
            "fk_publishing_posts_updated_by",
            "fk_publishing_posts_active_version",
            "fk_publishing_versions_created_by",
            "fk_publishing_versions_post",
            "phoenix_kit_publishing_categories_group_uuid_fkey",
            "phoenix_kit_publishing_categories_parent_uuid_fkey",
            "phoenix_kit_publishing_post_categories_category_uuid_fkey",
            "phoenix_kit_publishing_post_categories_post_uuid_fkey",
            "phoenix_kit_publishing_post_views_post_uuid_fkey"
          ] do
        assert statements =~ name,
               "V1 no longer creates #{name} — it must stay shape-identical to core's V59-through-V164"
      end
    end

    test "up stamps the version marker, and stamps it last" do
      statements = Migrations.up_statements()

      assert List.last(statements) ==
               "COMMENT ON TABLE public.phoenix_kit_publishing_groups IS 'pkpub_schema:1'",
             "the marker must be stamped after the DDL it certifies, not before"
    end

    test "applying up to version 0 is not an operation" do
      assert Migrations.up_statements("public", 0) == []
      assert Migrations.up_statements("publishing_alt", 0) == []
    end

    test "every up statement is guarded (IF NOT EXISTS / DO-block idempotence)" do
      # V1 runs on installs where core's V59-through-V164 already created
      # everything, so every statement must be a no-op against an object
      # that is already there. One exemption: the marker COMMENT — not a
      # guarded operation, it's the thing being stamped. Unlike
      # customer_support's chain, there is no safety-net ALTER exemption
      # here — see the moduledoc for why this adoption needs none.
      exempt = ["COMMENT ON TABLE public.phoenix_kit_publishing_groups IS 'pkpub_schema:1'"]

      ddl = Enum.reject(Migrations.up_statements(), &(&1 in exempt))

      for stmt <- ddl do
        assert stmt =~ "IF NOT EXISTS",
               "statement is not idempotent against a core-created table:\n#{stmt}"
      end
    end

    # No `ALTER TABLE` safety-net phase, and — unlike
    # `PhoenixKitNewsletters.Migrations` — no CHECK-constraint section at
    # all, because none of the 7 tables carries one (confirmed by the
    # moduledoc's three-source research pass). Every guard (pkey, unique
    # constraint, index, fk) is wrapped in its own `DO $$ ... $$` block, so
    # classification looks at what EACH block does, not just that it is a
    # `DO` block — otherwise pkeys/unique-constraints/fks would all
    # collapse into one indistinguishable bucket and this test could not
    # tell them apart.
    test "statement sections appear in the order tables -> pkeys -> unique_constraints -> indexes -> fks -> marker" do
      statements = Migrations.up_statements()

      sections =
        Enum.map(statements, fn stmt ->
          cond do
            String.starts_with?(stmt, "CREATE TABLE") -> :table
            String.starts_with?(stmt, "COMMENT ON TABLE") -> :marker
            stmt =~ "PRIMARY KEY" -> :pkey
            stmt =~ "ADD CONSTRAINT" and stmt =~ " UNIQUE (" -> :unique_constraint
            stmt =~ "EXECUTE 'CREATE" -> :index
            stmt =~ "FOREIGN KEY" -> :fk
          end
        end)

      order = Enum.dedup(sections)

      assert order == [:table, :pkey, :unique_constraint, :index, :fk, :marker],
             "sections are out of order: #{inspect(order)}"
    end
  end

  describe "the chain can never destroy any of the 7 tables" do
    alias PhoenixKit.Migrations.ExpectedSchema

    # Compared against the WHOLE expected content, not scanned for a
    # forbidden substring — a substring check only sees statements the
    # builder produced, so anything appended past it (a literal
    # `execute("DROP TABLE ...")` in `up/1`) would be invisible to it. That
    # path is closed by the source-text test below, which checks what is
    # executed rather than what is built.
    test "down/1 emits exactly the marker bookkeeping, in every target and prefix" do
      assert Migrations.down_statements("public", 0) ==
               ["COMMENT ON TABLE public.phoenix_kit_publishing_groups IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               ["COMMENT ON TABLE public.phoenix_kit_publishing_groups IS 'pkpub_schema:1'"]

      assert Migrations.down_statements("publishing_alt", 0) ==
               ["COMMENT ON TABLE publishing_alt.phoenix_kit_publishing_groups IS NULL"]

      assert Migrations.down_statements("publishing_alt", 1) ==
               [
                 "COMMENT ON TABLE publishing_alt.phoenix_kit_publishing_groups IS 'pkpub_schema:1'"
               ]
    end

    # For `up/1` the expected content is the full set of OPERATIONS rather
    # than the full SQL text. An operation is `{verb, object}`, immune to
    # reformatting and still failing on any statement added, removed or
    # retargeted — including a destructive one, which cannot enter this set
    # without changing it. Captured from a real run, same as the pinned
    # literal list above.
    @up_operations [
      {"CREATE TABLE", "phoenix_kit_publishing_groups"},
      {"CREATE TABLE", "phoenix_kit_publishing_posts"},
      {"CREATE TABLE", "phoenix_kit_publishing_versions"},
      {"CREATE TABLE", "phoenix_kit_publishing_contents"},
      {"CREATE TABLE", "phoenix_kit_publishing_categories"},
      {"CREATE TABLE", "phoenix_kit_publishing_post_categories"},
      {"CREATE TABLE", "phoenix_kit_publishing_post_views"},
      {"DO", "phoenix_kit_publishing_contents_pkey"},
      {"DO", "phoenix_kit_publishing_groups_pkey"},
      {"DO", "phoenix_kit_publishing_posts_pkey"},
      {"DO", "phoenix_kit_publishing_versions_pkey"},
      {"DO", "phoenix_kit_publishing_categories_pkey"},
      {"DO", "phoenix_kit_publishing_post_categories_pkey"},
      {"DO", "phoenix_kit_publishing_post_views_pkey"},
      {"DO", "phoenix_kit_publishing_categories_group_slug_uniq"},
      {"CREATE INDEX", "idx_publishing_contents_data_gin"},
      {"CREATE INDEX", "idx_publishing_contents_url_slug"},
      {"CREATE INDEX", "idx_publishing_contents_version_id"},
      {"CREATE UNIQUE INDEX", "idx_publishing_contents_version_language"},
      {"CREATE UNIQUE INDEX", "idx_publishing_groups_slug"},
      {"CREATE INDEX", "idx_publishing_groups_status"},
      {"CREATE INDEX", "idx_publishing_posts_created_by"},
      {"CREATE INDEX", "idx_publishing_posts_group_date_time"},
      {"CREATE INDEX", "idx_publishing_posts_group_id"},
      {"CREATE UNIQUE INDEX", "idx_publishing_posts_group_slug"},
      {"CREATE INDEX", "idx_publishing_posts_updated_by"},
      {"CREATE UNIQUE INDEX", "idx_publishing_posts_group_date_time_unique"},
      {"CREATE INDEX", "idx_publishing_posts_active_version"},
      {"CREATE INDEX", "idx_publishing_posts_trashed_at"},
      {"CREATE INDEX", "idx_publishing_versions_created_by"},
      {"CREATE INDEX", "idx_publishing_versions_post_id"},
      {"CREATE UNIQUE INDEX", "idx_publishing_versions_post_number"},
      {"CREATE INDEX", "idx_publishing_versions_post_status"},
      {"CREATE INDEX", "idx_publishing_versions_published_at"},
      {"CREATE INDEX", "idx_publishing_categories_group"},
      {"CREATE INDEX", "idx_publishing_categories_parent"},
      {"CREATE INDEX", "idx_publishing_post_categories_category"},
      {"DO", "fk_publishing_contents_version"},
      {"DO", "fk_publishing_posts_created_by"},
      {"DO", "fk_publishing_posts_group"},
      {"DO", "fk_publishing_posts_updated_by"},
      {"DO", "fk_publishing_posts_active_version"},
      {"DO", "fk_publishing_versions_created_by"},
      {"DO", "fk_publishing_versions_post"},
      {"DO", "phoenix_kit_publishing_categories_group_uuid_fkey"},
      {"DO", "phoenix_kit_publishing_categories_parent_uuid_fkey"},
      {"DO", "phoenix_kit_publishing_post_categories_category_uuid_fkey"},
      {"DO", "phoenix_kit_publishing_post_categories_post_uuid_fkey"},
      {"DO", "phoenix_kit_publishing_post_views_post_uuid_fkey"},
      {"COMMENT ON TABLE", "phoenix_kit_publishing_groups"}
    ]

    test "up_statements/2 emits exactly these operations and no others" do
      for prefix <- ["public", "publishing_alt"] do
        actual = Enum.map(Migrations.up_statements(prefix), &operation/1)

        assert Enum.sort(actual) == Enum.sort(@up_operations),
               """
               up_statements(#{inspect(prefix)}) does not emit the expected set of
               operations.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(@up_operations))}
               missing:    #{inspect(Enum.sort(@up_operations) -- Enum.sort(actual))}

               Every statement this chain emits runs against a core-created
               table. Adding one is a chain version (V2+), not something to
               slip past this list.
               """
      end
    end

    # Core's manifest for the 7 publishing tables' index/constraint objects,
    # not a hand-typed list — a hand-typed list is maintained by the same
    # hand that adds a statement, so it catches a slip but never a
    # deliberate one; the manifest is written on core's side, so this fails
    # both when the chain emits an object core does not declare AND when
    # core declares an object the chain stopped adopting. The pkeys and the
    # 1 unique constraint are `class: :constraint` in the manifest too, so
    # they are picked up by the same filter as the FKs — no separate
    # handling needed.
    test "up_statements/2 emits exactly the index/constraint operations core's manifest declares for the 7 publishing tables" do
      for prefix <- ["public", "publishing_alt"] do
        actual =
          Migrations.up_statements(prefix, 1)
          |> Enum.reject(
            &(String.starts_with?(&1, "CREATE TABLE") or
                String.starts_with?(&1, "COMMENT ON TABLE"))
          )
          |> Enum.map(&operation/1)

        expected = expected_index_constraint_operations()

        assert Enum.sort(actual) == Enum.sort(expected),
               """
               up_statements(#{inspect(prefix)}, 1) does not emit the operation set
               core's ExpectedSchema declares for the 7 publishing tables' indexes
               and constraints.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(expected))}
               missing:    #{inspect(Enum.sort(expected) -- Enum.sort(actual))}
               """
      end
    end

    test "the 5 real unique indexes are present, and only them" do
      unique_indexes =
        Migrations.up_statements()
        |> Enum.map(&operation/1)
        |> Enum.filter(&(elem(&1, 0) == "CREATE UNIQUE INDEX"))
        |> Enum.map(&elem(&1, 1))
        |> Enum.sort()

      assert unique_indexes == [
               "idx_publishing_contents_version_language",
               "idx_publishing_groups_slug",
               "idx_publishing_posts_group_date_time_unique",
               "idx_publishing_posts_group_slug",
               "idx_publishing_versions_post_number"
             ]
    end

    test "the 1 gin index is present, and only it" do
      gin_statements =
        Migrations.up_statements()
        |> Enum.filter(&(&1 =~ "USING gin"))

      assert length(gin_statements) == 1
      assert hd(gin_statements) =~ "idx_publishing_contents_data_gin"
    end

    defp expected_index_constraint_operations do
      publishing_tables = @publishing_tables

      ExpectedSchema.objects("public")
      |> Enum.filter(fn object ->
        case object.check do
          {_kind, %{table: table}} ->
            table in publishing_tables and object.class in [:index, :constraint] and
              Map.get(object, :presence) == :required

          _ ->
            false
        end
      end)
      |> Enum.map(fn object ->
        name = object.check |> elem(1) |> Map.fetch!(:name)

        case object.class do
          :constraint -> {"DO", name}
          :index -> {index_verb(object.create), name}
        end
      end)
    end

    defp index_verb(create) do
      if String.starts_with?(create, "CREATE UNIQUE INDEX"),
        do: "CREATE UNIQUE INDEX",
        else: "CREATE INDEX"
    end

    # `ON DELETE ...` is part of the foreign key's DEFINITION — the word
    # DELETE there describes what Postgres does to a child row when the
    # PARENT is deleted, and adoption reproducing core's FK means
    # reproducing core's referential action verbatim. Scanning the raw text
    # for the token would flag it, so the clause is removed before the scan.
    defp strip_referential_actions(statement) do
      String.replace(
        statement,
        ~r/ON\s+(DELETE|UPDATE)\s+(CASCADE|RESTRICT|NO\s+ACTION|SET\s+NULL|SET\s+DEFAULT)/i,
        "ON <referential action>"
      )
    end

    test "the referential-action strip does not blind the destructive scan" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      mutant =
        "ALTER TABLE public.phoenix_kit_publishing_versions ADD CONSTRAINT x FOREIGN KEY (post_uuid) " <>
          "REFERENCES public.phoenix_kit_publishing_posts(uuid) ON DELETE CASCADE; DROP TABLE public.phoenix_kit_publishing_versions"

      assert strip_referential_actions(mutant) =~ forbidden

      assert strip_referential_actions("DELETE FROM public.phoenix_kit_publishing_groups") =~
               forbidden

      assert strip_referential_actions("TRUNCATE public.phoenix_kit_publishing_groups") =~
               forbidden
    end

    test "no statement anywhere in the data-level chain can drop a table, truncate, or delete rows" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      for prefix <- ["public", "publishing_alt"] do
        for stmt <- Migrations.up_statements(prefix) do
          refute strip_referential_actions(stmt) =~ forbidden,
                 "up_statements(#{inspect(prefix)}) contains: #{stmt}"
        end

        for target <- [0, 1] do
          for stmt <- Migrations.down_statements(prefix, target) do
            refute strip_referential_actions(stmt) =~ forbidden,
                   "down_statements(#{inspect(prefix)}, #{target}) contains: #{stmt}"
          end
        end
      end
    end

    # `{verb, object}` for one statement. A pkey/unique-constraint/fk DO
    # block is identified by the constraint it adds; an index DO block
    # (guarded via `EXECUTE` — see the moduledoc's "Guards are semantic, not
    # name-based") is identified by the `CREATE [UNIQUE] INDEX` text inside
    # its own `EXECUTE '...'` argument, since the DO block's own verb says
    # nothing about either kind of target.
    defp operation(statement) do
      normalized = statement |> String.replace(~r/\s+/, " ") |> String.trim()

      cond do
        String.starts_with?(normalized, "DO ") and
            normalized =~ ~r/EXECUTE '(CREATE|CREATE UNIQUE)/ ->
          [_, verb, name] =
            Regex.run(
              ~r/EXECUTE '(CREATE UNIQUE INDEX|CREATE INDEX) IF NOT EXISTS (\w+)/,
              normalized
            )

          {verb, name}

        String.starts_with?(normalized, "DO ") ->
          [_, constraint] = Regex.run(~r/ADD CONSTRAINT (\w+)/, normalized)
          {"DO", constraint}

        true ->
          [_, verb, object] =
            Regex.run(
              ~r/^(CREATE UNIQUE INDEX|CREATE INDEX|CREATE TABLE|COMMENT ON TABLE|DROP TABLE|DROP INDEX|TRUNCATE|DELETE FROM|ALTER TABLE)(?: IF NOT EXISTS)? (?:\w+\.)?(\w+)/,
              normalized
            )

          {verb, object}
      end
    end
  end

  describe "what reaches the database is what the tests above inspect" do
    # The tests above read `up_statements/2` and `down_statements/2`. The
    # database gets `up/1` and `down/1`. Nothing connected the two, so a
    # literal `execute("DROP TABLE ...")` written straight into `up/1` would
    # have passed every one of them — the guard was watching the data while
    # the function did the work.
    @source "lib/phoenix_kit_publishing/migrations.ex"

    test "neither direction executes SQL of its own" do
      source = File.read!(@source)

      refute source =~ ~r/execute\(/,
             """
             #{@source} calls execute/1 with an argument of its own.

             Every DDL statement this chain runs via execute/1 must come from
             up_statements/2 or down_statements/2, because those are what the
             tests above compare against their expected content. A statement
             executed directly (rather than piped in via &execute/1) is
             invisible to all of them. (up/1's own ensure_extension!/1 and
             ensure_uuid_v7_function/1 calls are unaffected by this check —
             they run their own idempotent setup outside of execute/1
             entirely, and are exercised for real by
             migrations_data_safety_test.exs instead.)
             """

      assert length(Regex.scan(~r/&execute\/1/, source)) == 2,
             "expected exactly two `&execute/1` references — one per direction — " <>
               "in #{@source}"
    end

    test "each direction executes its own builder" do
      source = File.read!(@source)

      assert source =~ ~r/up_statements\(opts\.version\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "up/1 no longer pipes up_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what the up_statements-based tests above check"

      assert source =~ ~r/down_statements\(opts\.version\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "down/1 no longer pipes down_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what `down/1 emits exactly the marker " <>
               "bookkeeping` checks"
    end

    # Scoped to the two functions' own bodies, not the whole file — the
    # moduledoc legitimately discusses "never drops a table" in prose, which
    # a whole-file, case-insensitive scan would flag as a false positive on
    # the English word rather than a SQL token.
    test "up/1 and down/1 themselves contain no DROP/TRUNCATE/DELETE token" do
      source = File.read!(@source)

      [up_body] = Regex.run(~r/def up\(.*?\n  end\n/s, source)
      [down_body] = Regex.run(~r/def down\(.*?\n  end\n/s, source)

      for {name, body} <- [{"up/1", up_body}, {"down/1", down_body}] do
        refute body =~ ~r/DROP|TRUNCATE|DELETE/i,
               "#{name}'s own body in #{@source} contains a DROP/TRUNCATE/DELETE token"
      end
    end

    # There is deliberately no CHECK-guard helper in this file (unlike
    # `PhoenixKitNewsletters.Migrations`, which needs one for 2 real CHECK
    # constraints) — see this file's moduledoc, "Ownership situation": none
    # of the 7 tables carries a CHECK constraint. A future edit that copies
    # a `check_guard/4`-shaped helper in from a sibling chain without a
    # real CHECK to guard would be dead code at best and a silent
    # name-based guard at worst — assert its absence directly.
    test "there is no check_guard helper — this chain has no CHECK constraints to guard" do
      source = File.read!(@source)

      # A `defp check_guard` function definition, not a bare substring scan —
      # the moduledoc's own prose discusses (in backticks) the ABSENCE of
      # this helper by name, so a plain `source =~ "check_guard"` would
      # false-positive on that sentence, exactly like a whole-file
      # DROP/TRUNCATE scan would false-positive on this file's own "never
      # drops a table" prose (see the up/1-and-down/1-body test above).
      refute source =~ ~r/defp\s+check_guard/,
             "#{@source} defines a check_guard helper, but the moduledoc documents " <>
               "that none of the 7 tables has a CHECK constraint — either a real " <>
               "CHECK was added (update the moduledoc and this test) or this is " <>
               "dead code copied from a sibling chain"

      refute source =~ ~r/contype = 'c'/,
             "#{@source} guards a CHECK constraint (contype = 'c'), but none of the " <>
               "7 tables is documented to have one"
    end

    # Every guard in this file is semantic (keyed off `contype`/`indrelid`/
    # `conrelid`/`confrelid`/`indkey`/`indoption` — shape), never a bare
    # name-equality check as its ONLY match criterion (see the moduledoc's
    # "Guards are semantic, not name-based") — a name-based guard already
    # caused real duplicate-index/crash bugs on a live host for a sibling
    # module. Each guarded `DO $$ ... $$` block is already its own element
    # of `up_statements/2`'s return list (not re-parsed out of raw source
    # text, which would need to track nested parens correctly), so this
    # asserts directly over that list: every `DO` statement carries a
    # shape-based key, and none matches purely by `conname`/`indexname`.
    test "every DO-block guard is semantic (shape-based), never name-equality alone" do
      do_blocks =
        Migrations.up_statements("public", 1)
        |> Enum.filter(&String.starts_with?(&1, "DO $$"))

      # 7 pkeys + 1 unique constraint + 22 indexes + 12 fks.
      assert length(do_blocks) == 42

      for block <- do_blocks do
        refute block =~ ~r/WHERE\s+conname\s*=\s*'[^']+'/,
               "a guard matches purely by conname — this is the exact bug class " <>
                 "documented in the moduledoc:\n#{block}"

        refute block =~ ~r/WHERE\s+indexname\s*=\s*'[^']+'/,
               "a guard matches purely by indexname — this is the exact bug class " <>
                 "documented in the moduledoc:\n#{block}"

        assert block =~ ~r/contype|indrelid|conrelid|confrelid|indkey|indoption/,
               "a guard block has no shape-based key at all:\n#{block}"
      end
    end
  end

  describe "V1 stays aligned with core's manifest (while core audits the tables)" do
    alias PhoenixKit.Migrations.ExpectedSchema
    alias PhoenixKit.Migrations.ExpectedSchema.Object
    alias PhoenixKit.Modules.Publishing.PublishingCategory
    alias PhoenixKit.Modules.Publishing.PublishingContent
    alias PhoenixKit.Modules.Publishing.PublishingGroup
    alias PhoenixKit.Modules.Publishing.PublishingPost
    alias PhoenixKit.Modules.Publishing.PublishingVersion

    @width_schemas %{
      "phoenix_kit_publishing_groups" => PublishingGroup,
      "phoenix_kit_publishing_posts" => PublishingPost,
      "phoenix_kit_publishing_versions" => PublishingVersion,
      "phoenix_kit_publishing_contents" => PublishingContent,
      "phoenix_kit_publishing_categories" => PublishingCategory
    }

    # The lesson phoenix_kit_legal paid for once (three disagreeing DDLs of
    # one table): never a second copy of a width. Parsed back out of each
    # CREATE rather than trusted, so a hard-coded number slipped into
    # up_statements/2 instead of a schema's column_widths/0 fails here even
    # though the two happen to agree today. `_post_categories`/`_post_views`
    # are not in this map — neither has a varchar column
    # (`PublishingPostCategory` declares no `column_widths/0`, and there is
    # no schema module for `post_views` at all).
    test "every varchar width in each CREATE is that table's schema's column_widths/0" do
      statements = Migrations.up_statements("public", 1)

      for {table, schema} <- @width_schemas do
        columns = v1_columns(statements, table)

        parsed =
          columns
          |> Enum.filter(fn {_col, %{type: type}} -> type =~ "character varying" end)
          |> Map.new(fn {col, %{type: type}} ->
            [_, width] = Regex.run(~r/character varying\((\d+)\)/, type)
            {String.to_existing_atom(col), String.to_integer(width)}
          end)

        assert parsed == schema.column_widths(),
               """
               #{table}: the CREATE widths and #{inspect(schema)}.column_widths/0 disagree.

               parsed from DDL: #{inspect(parsed)}
               declared:        #{inspect(schema.column_widths())}
               """
      end
    end

    # Core's V59-through-V164 baseline still creates all 7 tables and core's
    # ExpectedSchema audits that shape, so until the first shape-changing
    # chain version the two DDLs must agree — with NO documented exception
    # (unlike customer_support's `changed_by_uuid`): core's source, core's
    # manifest, and this chain's V1 all agree byte-for-byte today (see the
    # moduledoc's "Ownership situation"). Bidirectional: checks both that V1
    # creates nothing core doesn't declare AND that V1 is missing nothing
    # core does declare.
    test "every column core declares matches V1's, in full, for every table" do
      statements = Migrations.up_statements("public", 1)

      for table <- @publishing_tables do
        core = core_columns(table)
        ours = v1_columns(statements, table)

        assert Map.keys(ours) -- Map.keys(core) == [],
               "#{table}: V1 creates columns core's manifest does not declare: " <>
                 inspect(Map.keys(ours) -- Map.keys(core))

        assert Map.keys(core) -- Map.keys(ours) == [],
               "#{table}: V1 does not create columns core's manifest declares: " <>
                 inspect(Map.keys(core) -- Map.keys(ours))

        for {column, expected} <- core do
          assert Map.fetch!(ours, column) == expected,
                 """
                 #{table}.#{column}: V1 and core's manifest disagree on the column's shape.

                 V1:              #{inspect(Map.fetch!(ours, column))}
                 core's manifest: #{inspect(expected)}

                 V1 is an adoption and must be shape-identical to core's
                 baseline. A deliberate change is a chain version (V2+).
                 """
        end
      end
    end

    # Full PK/UNIQUE/FK inventory: parses every `ADD CONSTRAINT` statement
    # V1 emits back into {table, name, kind, columns, foreign_table,
    # foreign_column, on_delete} and cross-checks each against core's
    # manifest's own structured shape for that exact constraint id
    # (`Object.newest_shape/1`) — never a hand-typed duplicate of the
    # expected shape.
    test "every PK/UNIQUE/FK constraint's columns, target, and on_delete match core's manifest" do
      statements = Migrations.up_statements("public", 1)
      manifest = ExpectedSchema.objects("public")

      constraint_statements = Enum.filter(statements, &(&1 =~ "ADD CONSTRAINT"))

      assert length(constraint_statements) == 20,
             "expected 7 pkeys + 1 unique constraint + 12 fks = 20 ADD CONSTRAINT " <>
               "statements, got #{length(constraint_statements)}"

      for stmt <- constraint_statements do
        {table, name, kind, columns, foreign_table, foreign_column, on_delete} =
          parse_constraint(stmt)

        manifest_object =
          Enum.find(manifest, &(&1.id == "constraint:#{table}.#{name}")) ||
            flunk(
              "no manifest object constraint:#{table}.#{name} — V1 emits a " <>
                "constraint core's manifest doesn't declare"
            )

        shape = Object.newest_shape(manifest_object)

        assert shape.columns == columns,
               "#{table}.#{name}: columns #{inspect(columns)} != manifest #{inspect(shape.columns)}"

        case kind do
          "FOREIGN KEY" ->
            assert shape.type == "f"
            assert shape.foreign_table == foreign_table
            assert shape.foreign_columns == [foreign_column]
            assert shape.on_delete == on_delete

          "PRIMARY KEY" ->
            assert shape.type == "p"

          "UNIQUE" ->
            assert shape.type == "u"
        end
      end
    end

    # Full index inventory: parses every `EXECUTE 'CREATE ... INDEX ...'`
    # argument V1 emits back into {name, unique, method, keys, predicate}
    # and cross-checks each against core's manifest's own structured shape —
    # columns-in-order, uniqueness, access method, and partial predicate,
    # all parsed from the real DDL text rather than hand-typed.
    test "every index's columns-in-order, uniqueness, method, and predicate match core's manifest" do
      statements = Migrations.up_statements("public", 1)
      manifest = ExpectedSchema.objects("public")

      index_statements = Enum.filter(statements, &(&1 =~ "EXECUTE '"))
      assert length(index_statements) == 22

      for stmt <- index_statements do
        {name, unique, method, keys, predicate} = parse_index(stmt)

        manifest_object =
          Enum.find(manifest, &(&1.id == "index:#{name}")) ||
            flunk(
              "no manifest object index:#{name} — V1 emits an index core's " <>
                "manifest doesn't declare"
            )

        shape = Object.newest_shape(manifest_object)

        assert unique == shape.unique, "#{name}: unique #{unique} != manifest #{shape.unique}"
        assert method == shape.method, "#{name}: method #{method} != manifest #{shape.method}"

        assert keys == shape.keys,
               "#{name}: keys #{inspect(keys)} != manifest #{inspect(shape.keys)}"

        assert predicate == shape.predicate,
               "#{name}: predicate #{inspect(predicate)} != manifest #{inspect(shape.predicate)}"
      end
    end

    defp on_delete_code("CASCADE"), do: "c"
    defp on_delete_code("SET NULL"), do: "n"
    defp on_delete_code("RESTRICT"), do: "r"
    defp on_delete_code("NO ACTION"), do: "a"
    defp on_delete_code("SET DEFAULT"), do: "d"

    defp parse_constraint(statement) do
      normalized = statement |> String.replace(~r/\s+/, " ") |> String.trim()

      regex =
        ~r/ALTER TABLE \S+\.(\w+) ADD CONSTRAINT (\w+) (PRIMARY KEY|UNIQUE|FOREIGN KEY) \(([^)]+)\)(?: REFERENCES \S+\.(\w+)\((\w+)\) ON DELETE ([A-Z ]+))?/

      case Regex.run(regex, normalized) do
        [_, table, name, kind, cols] ->
          {table, name, kind, String.split(cols, ", "), nil, nil, nil}

        [_, table, name, kind, cols, foreign_table, foreign_column, on_delete] ->
          {table, name, kind, String.split(cols, ", "), foreign_table, foreign_column,
           on_delete_code(String.trim(on_delete))}
      end
    end

    defp parse_index(statement) do
      [_, execute_sql] = Regex.run(~r/EXECUTE '([^']*)'/, statement)

      regex =
        ~r/^CREATE (UNIQUE )?INDEX IF NOT EXISTS (\w+) ON \S+ USING (\w+) \(([^)]+)\)(?: WHERE (.+))?$/

      [_, unique_flag, name, method, cols_raw | rest] = Regex.run(regex, execute_sql)

      predicate =
        case rest do
          [p] when p != "" -> p
          _ -> nil
        end

      keys =
        cols_raw
        |> String.split(", ")
        |> Enum.map(&String.replace(&1, ~r/\s+(DESC|ASC)$/, ""))

      {name, unique_flag == "UNIQUE ", method, keys, predicate}
    end

    defp v1_columns(statements, table) do
      create = table_create(statements, table)

      ~r/^\s*"(\w+)"\s+(.+?),?$/m
      |> Regex.scan(create)
      |> Map.new(fn [_line, name, definition] -> {name, parse_column(definition)} end)
    end

    defp table_create(statements, table) do
      Enum.find(
        statements,
        &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} (")
      )
    end

    defp parse_column(definition) do
      {definition, not_null} =
        case String.replace_suffix(definition, " NOT NULL", "") do
          ^definition -> {definition, false}
          trimmed -> {trimmed, true}
        end

      case String.split(definition, " DEFAULT ", parts: 2) do
        [type] -> %{type: type, default: nil, not_null: not_null}
        [type, default] -> %{type: type, default: default, not_null: not_null}
      end
    end

    # `%{type, default, not_null}` per column, from the newest revision —
    # e.g. groups.status's not_null/default were added by V83, so its
    # newest revision (not the V59 original, which has no such column at
    # all) is what V1 must match.
    defp core_columns(table) do
      prefix = "column:#{table}."

      ExpectedSchema.objects("public")
      |> Enum.filter(&(&1.class == :column and String.starts_with?(&1.id, prefix)))
      |> Map.new(fn object ->
        {_version, shape} = List.last(object.revisions)

        {String.replace_prefix(object.id, prefix, ""),
         %{type: shape.type, default: shape.default, not_null: shape.not_null}}
      end)
    end
  end
end
