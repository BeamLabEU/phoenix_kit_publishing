defmodule PhoenixKit.Modules.Publishing.FileReferences do
  @moduledoc """
  The places in this module's tables that point at a stored file, for the
  orphan-file check of core's storage (`PhoenixKit.Module.file_references/0`).

  A file one of these rows names is in use and must never be read as an orphan:
  core would queue it for `DeleteOrphanedFileJob`. Each pair is a table and the
  condition "this table does not reference the file"; core leaves the pair out
  when the table does not exist, and ANDs every pair it keeps.

  The first two pairs are the ones core's own copy holds for these tables
  (`Storage.builtin_file_references/0`), verbatim: while this module supplies a
  list, core's copy of its tables steps aside. The rest are the other places a
  post names a file — the same list `MediaAdoption` files into a group's folder:
  a version's `audio_uuid`, a content row's legacy `featured_image_id` and its
  OG image (`og.image_uuid`), and the body's `file_uuid="…"` component
  attributes and baked `/file/<uuid>/…` URLs. Without them a picture shown
  only through an `<Image>` in a live post counted as an orphan, and
  "Delete all orphaned" took it off the page. Trashed posts and drafts count
  too: both can come back.
  """

  import Ecto.Query, only: [dynamic: 2]

  # A PHK component's `file_uuid="…"` and a baked `…/file/<uuid>/…` URL, as in
  # `MediaAdoption`. Postgres ARE syntax; matched case-insensitively below.
  @body_refs ~S<(?:file_uuid=["']|/file/)([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})>

  @spec pairs() :: [{String.t(), Ecto.Query.dynamic_expr()}]
  def pairs do
    [
      {"phoenix_kit_publishing_contents",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_publishing_contents pc WHERE pc.data->>'featured_image_uuid' = ?::text)",
           f.uuid
         )
       )},
      {"phoenix_kit_publishing_versions",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_publishing_versions pv WHERE pv.data->>'featured_image_uuid' = ?::text)",
           f.uuid
         )
       )},
      {"phoenix_kit_publishing_versions",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_publishing_versions pv WHERE pv.data->>'audio_uuid' = ?::text)",
           f.uuid
         )
       )},
      {"phoenix_kit_publishing_contents",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_publishing_contents pc WHERE pc.data->>'featured_image_id' = ?::text OR pc.data->'og'->>'image_uuid' = ?::text)",
           f.uuid,
           f.uuid
         )
       )},
      {"phoenix_kit_publishing_contents",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_publishing_contents pc CROSS JOIN LATERAL regexp_matches(pc.content, ?, 'g') AS m WHERE lower(m[1]) = ?::text)",
           ^@body_refs,
           f.uuid
         )
       )}
    ]
  end
end
