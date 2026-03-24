defmodule PhoenixKit.Modules.Publishing.Migrations.PublishingTables do
  @moduledoc """
  Consolidated migration for the Publishing module.

  Creates all 4 publishing tables in their final state. Every statement uses
  IF NOT EXISTS / IF NOT NULL guards so it is safe to run even when the tables
  already exist (e.g. created by PhoenixKit core migrations).

  ## Tables

  - `phoenix_kit_publishing_groups`   — content groups (blog, faq, docs, …)
  - `phoenix_kit_publishing_posts`    — posts within groups
  - `phoenix_kit_publishing_versions` — version history per post
  - `phoenix_kit_publishing_contents` — per-language content per version

  ## Design

  - UUID v7 primary keys (`uuid_generate_v7()` default)
  - JSONB `data` column on every table for extensibility
  - All timestamps use `timestamptz`
  - Slug is nullable (timestamp-mode posts use date/time instead)
  - User FK columns (`created_by_uuid`, `updated_by_uuid`) reference
    `phoenix_kit_users(uuid)` when that table exists; otherwise skipped.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""
    schema_name = if prefix && prefix != "public", do: prefix, else: "public"

    # =========================================================================
    # Table 1: phoenix_kit_publishing_groups
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_publishing_groups (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      mode VARCHAR(20) NOT NULL DEFAULT 'timestamp',
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      position INTEGER NOT NULL DEFAULT 0,
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_groups_slug
    ON #{prefix_str}phoenix_kit_publishing_groups (slug)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_groups_status
    ON #{prefix_str}phoenix_kit_publishing_groups (status)
    """)

    # =========================================================================
    # Table 2: phoenix_kit_publishing_posts
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_publishing_posts (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      group_uuid UUID NOT NULL,
      slug VARCHAR(500),
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      mode VARCHAR(20) NOT NULL DEFAULT 'timestamp',
      primary_language VARCHAR(10) NOT NULL DEFAULT 'en',
      published_at TIMESTAMPTZ,
      scheduled_at TIMESTAMPTZ,
      post_date DATE,
      post_time TIME,
      created_by_uuid UUID,
      updated_by_uuid UUID,
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_publishing_posts_group
        FOREIGN KEY (group_uuid)
        REFERENCES #{prefix_str}phoenix_kit_publishing_groups(uuid)
        ON DELETE CASCADE
    )
    """)

    # User FKs — only add if phoenix_kit_users table exists
    maybe_add_user_fk(prefix_str, schema_name, "phoenix_kit_publishing_posts",
      "fk_publishing_posts_created_by", "created_by_uuid")

    maybe_add_user_fk(prefix_str, schema_name, "phoenix_kit_publishing_posts",
      "fk_publishing_posts_updated_by", "updated_by_uuid")

    # Slug-mode uniqueness (partial — only when slug is present)
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_posts_group_slug
    ON #{prefix_str}phoenix_kit_publishing_posts (group_uuid, slug)
    WHERE slug IS NOT NULL
    """)

    # Timestamp-mode uniqueness
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_posts_group_date_time_unique
    ON #{prefix_str}phoenix_kit_publishing_posts (group_uuid, post_date, post_time)
    WHERE post_date IS NOT NULL AND post_time IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_uuid
    ON #{prefix_str}phoenix_kit_publishing_posts (group_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_status
    ON #{prefix_str}phoenix_kit_publishing_posts (group_uuid, status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_published_at
    ON #{prefix_str}phoenix_kit_publishing_posts (group_uuid, published_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_group_date_time
    ON #{prefix_str}phoenix_kit_publishing_posts (group_uuid, post_date DESC, post_time DESC)
    WHERE post_date IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_scheduled
    ON #{prefix_str}phoenix_kit_publishing_posts (scheduled_at)
    WHERE status = 'scheduled'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_created_by
    ON #{prefix_str}phoenix_kit_publishing_posts (created_by_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_posts_updated_by
    ON #{prefix_str}phoenix_kit_publishing_posts (updated_by_uuid)
    """)

    # =========================================================================
    # Table 3: phoenix_kit_publishing_versions
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_publishing_versions (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      post_uuid UUID NOT NULL,
      version_number INTEGER NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      created_by_uuid UUID,
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_publishing_versions_post
        FOREIGN KEY (post_uuid)
        REFERENCES #{prefix_str}phoenix_kit_publishing_posts(uuid)
        ON DELETE CASCADE
    )
    """)

    maybe_add_user_fk(prefix_str, schema_name, "phoenix_kit_publishing_versions",
      "fk_publishing_versions_created_by", "created_by_uuid")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_versions_post_number
    ON #{prefix_str}phoenix_kit_publishing_versions (post_uuid, version_number)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_versions_post_uuid
    ON #{prefix_str}phoenix_kit_publishing_versions (post_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_versions_post_status
    ON #{prefix_str}phoenix_kit_publishing_versions (post_uuid, status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_versions_created_by
    ON #{prefix_str}phoenix_kit_publishing_versions (created_by_uuid)
    """)

    # =========================================================================
    # Table 4: phoenix_kit_publishing_contents
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix_str}phoenix_kit_publishing_contents (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      version_uuid UUID NOT NULL,
      language VARCHAR(10) NOT NULL,
      title VARCHAR(500) NOT NULL,
      content TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      url_slug VARCHAR(500),
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_publishing_contents_version
        FOREIGN KEY (version_uuid)
        REFERENCES #{prefix_str}phoenix_kit_publishing_versions(uuid)
        ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_contents_version_language
    ON #{prefix_str}phoenix_kit_publishing_contents (version_uuid, language)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_contents_version_uuid
    ON #{prefix_str}phoenix_kit_publishing_contents (version_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_contents_url_slug
    ON #{prefix_str}phoenix_kit_publishing_contents (url_slug)
    WHERE url_slug IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_contents_data_gin
    ON #{prefix_str}phoenix_kit_publishing_contents USING GIN (data)
    """)
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_publishing_contents CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_publishing_versions CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_publishing_posts CASCADE")
    execute("DROP TABLE IF EXISTS #{prefix_str}phoenix_kit_publishing_groups CASCADE")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_add_user_fk(prefix_str, schema_name, table, constraint_name, column) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = '#{schema_name}'
        AND table_name = 'phoenix_kit_users'
      )
      AND NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = '#{schema_name}'
        AND table_name = '#{table}'
        AND constraint_name = '#{constraint_name}'
      )
      THEN
        ALTER TABLE #{prefix_str}#{table}
          ADD CONSTRAINT #{constraint_name}
          FOREIGN KEY (#{column})
          REFERENCES #{prefix_str}phoenix_kit_users(uuid)
          ON DELETE SET NULL;
      END IF;
    END $$;
    """)
  end
end
