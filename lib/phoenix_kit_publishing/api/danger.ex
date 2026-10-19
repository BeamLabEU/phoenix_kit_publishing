defmodule PhoenixKit.Modules.Publishing.API.Danger do
  @moduledoc false
  # `{Module, :function}` danger checks. Each is `fun(input, ctx) :: boolean()`, called
  # by core with a dry-run context, read-only and FAIL CLOSED:
  #   1. unprovable means true (an unresolvable reference, a missing row, a bad id);
  #   2. an error means true, and no read may hide one: only raising reads are used (Refs,
  #      DBStorage reads, Common.*!), never a read that rescues to an empty or false result;
  #   3. each function body is wrapped in `guard/1`, `rescue _ -> true`.

  alias PhoenixKit.Modules.Publishing.API.{Refs, TextScan, UpsertCategories, UpsertGroups}
  alias PhoenixKit.Modules.Publishing.DBStorage

  @doc false
  def guard(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> true
  catch
    _kind, _value -> true
  end

  @doc "create_post: the text rule on `content` only (a new post has no live version)."
  def create_post(input, _ctx), do: guard(fn -> text_dangerous?(input) end)

  @doc """
  update_post: the text rule on `content`; OR the post is not trashed, has an active version and
  the target version is the active one or has status published / archived; OR `slug` is given,
  differs from the current slug and the post has an active version (the rename moves the live
  URL even when the written version is a draft). Unprovable means true.
  """
  def update_post(input, _ctx) do
    guard(fn ->
      text_dangerous?(input) or live?(input["post"], input["version"], input["slug"])
    end)
  end

  @doc """
  set_translation: the text rule on `content`; OR the post is not trashed, has an active version
  and the target version is the active one or has status published / archived (no slug clause).
  """
  def set_translation(input, _ctx) do
    guard(fn -> text_dangerous?(input) or live?(input["post"], input["version"], nil) end)
  end

  @doc "restore_posts: any resolved, currently trashed post has an active version (it would become visible); unprovable means true."
  def restore_posts(input, _ctx) do
    guard(fn -> input["posts"] |> List.wrap() |> Enum.any?(&restore_dangerous?/1) end)
  end

  @doc """
  upsert_categories: some row UPDATES an existing category and effectively changes it. A category
  created earlier in the same request does not count. Unprovable means true: an unresolvable
  group, a malformed request and a failing category read.
  """
  def upsert_categories(input, _ctx) do
    guard(fn ->
      case Refs.resolve_group(input["group"]) do
        {:ok, group} ->
          group.slug
          |> UpsertCategories.plan(input["categories"])
          |> UpsertCategories.dangerous?()

        _unresolvable ->
          true
      end
    end)
  end

  @doc """
  upsert_groups: some row UPDATES an existing group and effectively changes it. Creating a group is
  never dangerous. Unprovable means true: a malformed request and a failing group read.
  """
  def upsert_groups(input, _ctx) do
    guard(fn ->
      input["groups"]
      |> UpsertGroups.plan()
      |> UpsertGroups.dangerous?()
    end)
  end

  defp restore_dangerous?(ref) do
    case Refs.resolve_post(ref, include_trashed: true) do
      {:ok, %{db_post: db_post}} ->
        db_post.trashed_at != nil and db_post.active_version_uuid != nil

      _unresolvable ->
        true
    end
  end

  @doc false
  def live?(ref, version_number, requested_slug) do
    case Refs.resolve_post(ref, include_trashed: true) do
      {:ok, %{db_post: %{trashed_at: nil} = db_post}} ->
        case Refs.resolve_version(db_post, version_number, :write) do
          {:ok, version} -> live_condition(db_post, version, requested_slug)
          _unprovable -> true
        end

      {:ok, _trashed} ->
        false

      _unresolvable ->
        true
    end
  end

  @doc """
  The live-version condition on two FRESH rows (the post row returned by the lock and the
  re-read version): used by the handler's recheck and by the `:locked_check` closure.
  """
  def live_condition(locked_post, version, requested_slug) do
    locked_post.active_version_uuid != nil and
      (version.uuid == locked_post.active_version_uuid or
         version.status in ["published", "archived"] or
         (is_binary(requested_slug) and requested_slug != locked_post.slug))
  end

  @doc """
  The recheck just before the write, on fresh rows, for unconfirmed calls only. A condition that
  became true is `revision_mismatch` with the reason `went_live`. A row that vanished is left
  for the write to report as not found.
  """
  def recheck(db_post, version, requested_slug, ctx) do
    if Map.get(ctx, :confirmation_uuid) == nil do
      fresh_post = DBStorage.get_post_by_uuid(db_post.uuid)
      fresh_version = DBStorage.get_version_by_uuid(version.uuid)

      if fresh_post && fresh_version && live_condition(fresh_post, fresh_version, requested_slug),
        do:
          {:error, :revision_mismatch,
           "The version went live; repeat the call to get a confirmation.",
           %{reason: "went_live"}},
        else: :ok
    else
      :ok
    end
  end

  @doc false
  # `null` content means "clear": the empty text is not dangerous. Any other non-string fails closed.
  # Raises on a non-map `input`: call it only under `guard/1`.
  def text_dangerous?(input) do
    case Map.fetch(input, "content") do
      :error -> false
      {:ok, nil} -> false
      {:ok, text} -> TextScan.dangerous?(text)
    end
  end
end
