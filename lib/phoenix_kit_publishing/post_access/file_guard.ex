defmodule PhoenixKit.Modules.Publishing.PostAccess.FileGuard do
  @moduledoc """
  Publishing's answer to core's file access guard
  (`PhoenixKit.Modules.Storage.AccessGuard`, through
  `PhoenixKit.Modules.Publishing.file_access_guard/2`): a stored file that
  only protected posts use is served to the readers who may open one of
  those posts, and to nobody else.

    * A file no protected post uses, or one a public post's live version
      also shows: `:allow`, served as ever.
    * A file only protected posts use (any of their versions, any language:
      the featured image, the OG image, the audio, a component's
      `file_uuid`, a baked `/file/<uuid>/…` URL in the body):
      * `:private` for a holder of `publishing` or `media` (editors, the
        media browser and pickers load the same route) and for a reader
        `PostAccess.authorize_view/2` lets into one of those posts (their
        grants cookie, their account);
      * `:deny` for everyone else: core answers it as a missing file.

  The index of guarded files is built in a few queries and kept in
  `:persistent_term` for #{60} s; every listing rebuild after a write (each
  post or rule write, `ListingCache.regenerate/2`) drops it on every node
  (`invalidate_everywhere/0`, over the kit's PubSub). A deep-zoom view
  asks once per tile, so a file outside the index costs a map lookup.

  What it cannot see: a file another module (a product page, a profile)
  shows publicly while a protected post also uses it. Such a file is
  guarded too; keep files shared with other public pages out of protected
  posts, or give the post its own copy.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.PostAccess
  alias PhoenixKit.Modules.Publishing.PostAccess.Viewer
  alias PhoenixKit.Modules.Publishing.PublishingAccessRule, as: Rule
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Users.Auth.Scope

  @ttl_ms 60_000

  # The same references `FileReferences` / `MediaAdoption` read in a body.
  @body_refs ~r/(?:file_uuid\s*=\s*["']|\/file\/)([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/

  @type answer :: :allow | :private | :deny

  @doc "The answer for `file` (anything with a `:uuid`) on this request."
  @spec check(map(), Plug.Conn.t()) :: answer()
  def check(%{uuid: uuid}, conn) when is_binary(uuid) do
    case Map.get(index(), String.downcase(uuid)) do
      nil -> :allow
      post_uuids -> decide(post_uuids, conn)
    end
  end

  def check(_file, _conn), do: :allow

  defp decide(post_uuids, conn) do
    scope = conn.assigns[:phoenix_kit_current_scope]

    cond do
      manager?(scope) -> :private
      Enum.any?(post_uuids, &openable?(&1, conn)) -> :private
      true -> :deny
    end
  end

  defp manager?(nil), do: false

  defp manager?(scope) do
    Scope.can?(scope, "publishing") or Scope.has_module_access?(scope, "media")
  rescue
    _ -> false
  end

  defp openable?(post_uuid, conn) do
    # A reader's grant applies only while the owning post is live.
    case repo().one(
           from p in live_posts(),
             where: p.uuid == ^post_uuid,
             select: %{mode: p.mode, date: p.post_date, time: p.post_time}
         ) do
      nil ->
        false

      post ->
        not Constants.scheduled_ahead?(post) and
          PostAccess.authorize_view(PostAccess.access_for_post(post_uuid), Viewer.from_conn(conn)) ==
            :ok
    end
  end

  @doc "Drops this node's index (a post or a rule changed)."
  @spec invalidate() :: :ok
  def invalidate do
    :persistent_term.put({key(), :generation}, make_ref())
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Drops the index on this node and tells every other node to drop theirs
  (`PubSub.broadcast_file_guard_invalidated/1`, received by `CacheSync`). The
  60 s lifetime stays as the backstop for a node the broadcast misses.
  """
  @spec invalidate_everywhere() :: :ok
  def invalidate_everywhere do
    invalidate()
    PublishingPubSub.broadcast_file_guard_invalidated()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  `%{file_uuid => [post_uuid]}`: the files only protected posts use, with
  the posts that use them.
  """
  @spec index() :: %{optional(String.t()) => [String.t()]}
  def index do
    now = System.monotonic_time(:millisecond)

    generation = current_generation()

    case :persistent_term.get(key(), nil) do
      {^generation, index, until} when until > now ->
        index

      _ ->
        index = if PostAccess.rules_table?(), do: build(), else: %{}
        store_index(generation, index, now + @ttl_ms)
        if current_generation() == generation, do: index, else: index()
    end
  end

  # Invalidation changes a separate slot. A late writer can replace the
  # cached value, but readers can never accept it under a newer generation.
  @doc false
  def store_index(generation, index, until),
    do: :persistent_term.put(key(), {generation, index, until})

  @doc false
  def current_generation, do: :persistent_term.get({key(), :generation}, nil)

  defp key, do: {__MODULE__, PhoenixKit.RepoHelper.repo()}

  defp build do
    case protected_posts() do
      [] ->
        %{}

      posts ->
        by_file = protected_refs(posts)
        Map.drop(by_file, public_refs(Map.keys(by_file), posts))
    end
  end

  defp protected_posts do
    from(r in Rule,
      where: not is_nil(r.post_uuid) and r.kind in ^Rule.gate_kinds(),
      distinct: true,
      select: r.post_uuid
    )
    |> repo().all()
  end

  # Every version and language of the protected posts.
  defp protected_refs(post_uuids) do
    from(v in PublishingVersion,
      left_join: c in PublishingContent,
      on: c.version_uuid == v.uuid,
      where: v.post_uuid in ^post_uuids,
      select: {v.post_uuid, v.data, c.data, c.content}
    )
    |> repo().all()
    |> Enum.reduce(%{}, fn {post_uuid, vdata, cdata, body}, acc ->
      vdata
      |> refs(cdata, body)
      |> Enum.reduce(acc, fn file, acc ->
        Map.update(acc, file, [post_uuid], &Enum.uniq([post_uuid | &1]))
      end)
    end)
  end

  # Of these files, the ones the LIVE version of a public (no rule, not
  # trashed) post shows: those stay public.
  defp public_refs([], _protected), do: []

  defp public_refs(files, protected) do
    patterns = Enum.map(files, &"%#{&1}%")
    wanted = MapSet.new(files)

    now = DateTime.utc_now()
    tz = Constants.site_tz()

    from([p, v] in live_posts(),
      left_join: c in PublishingContent,
      on: c.version_uuid == v.uuid,
      where: p.uuid not in ^protected,
      where:
        fragment("? ILIKE ANY(?)", c.content, ^patterns) or
          fragment("?::text ILIKE ANY(?)", c.data, ^patterns) or
          fragment("?::text ILIKE ANY(?)", v.data, ^patterns),
      select: {%{mode: p.mode, date: p.post_date, time: p.post_time}, v.data, c.data, c.content}
    )
    |> repo().all()
    |> Enum.reject(fn {post, _, _, _} -> Constants.scheduled_ahead?(post, now, tz) end)
    |> Enum.flat_map(fn {_, vdata, cdata, body} -> refs(vdata, cdata, body) end)
    |> Enum.filter(&MapSet.member?(wanted, &1))
  end

  defp live_posts do
    from(p in PublishingPost,
      join: v in assoc(p, :active_version),
      join: g in assoc(p, :group),
      where: is_nil(p.trashed_at) and g.status == "active" and v.status == "published"
    )
  end

  defp refs(vdata, cdata, body) do
    vdata = vdata || %{}
    cdata = cdata || %{}

    data_refs = [
      vdata["featured_image_uuid"],
      vdata["audio_uuid"],
      cdata["featured_image_uuid"],
      cdata["featured_image_id"],
      og_image(cdata["og"])
    ]

    body_refs =
      if is_binary(body),
        do: @body_refs |> Regex.scan(body, capture: :all_but_first) |> List.flatten(),
        else: []

    (data_refs ++ body_refs)
    |> Enum.filter(&(is_binary(&1) and match?({:ok, _}, Ecto.UUID.cast(&1))))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp og_image(%{"image_uuid" => uuid}), do: uuid
  defp og_image(_og), do: nil

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
