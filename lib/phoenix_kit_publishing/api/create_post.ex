defmodule PhoenixKit.Modules.Publishing.API.CreatePost do
  @moduledoc false
  # Tool `publishing.create_post` (spec §9.6).

  alias PhoenixKit.Modules.Publishing.API.{Common, Danger, Presenter, Refs, TextScan}
  alias PhoenixKit.Modules.Publishing.{Constants, DBStorage, Posts}

  @tool "publishing.create_post"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, group} <- group(input["group"]),
         :ok <- check(input),
         {:ok, slug} <- slug(group, input["slug"]) do
      if Map.get(ctx, :dry_run?, false),
        do: preview(input, group, slug, ctx),
        else: execute(input, group, slug, ctx)
    end
  end

  defp group(slug) do
    with {:ok, group} <- slug |> Refs.resolve_group() |> Refs.group_missing(),
         :ok <- group |> Refs.ensure_group_active() |> Refs.group_error() do
      {:ok, group}
    end
  end

  defp check(input) do
    with :ok <- Common.check_text("title", input["title"], max: Constants.max_title_length()),
         :ok <- title_present(input["title"]) do
      Common.check_text("content", input["content"],
        max: TextScan.max_body_bytes(),
        reason: "content_too_large"
      )
    end
  end

  defp title_present(title) when is_binary(title) do
    if String.trim(title) == "",
      do: Common.invalid("title", "must not be blank", "title_required"),
      else: :ok
  end

  defp title_present(_other), do: Common.invalid("title", "is required", "title_required")

  # nil: the module generates a unique slug from the title (slug mode) or there is none (timestamp mode).
  defp slug(_group, nil), do: {:ok, nil}

  defp slug(%{mode: "slug"} = group, slug) do
    with {:ok, slug} <- Common.validate_slug(slug) do
      case Common.slug_taken?(group.slug, slug) do
        false ->
          {:ok, slug}

        {true, :live} ->
          Common.invalid("slug", "the slug is already in use", "slug_taken")

        {true, :trashed} ->
          {:error, :validation_failed,
           "The slug belongs to a trashed post; restore it or pick another slug.",
           %{
             errors: [
               %{
                 path: "slug",
                 message: "the slug belongs to a trashed post",
                 reason: "slug_taken",
                 trashed: true
               }
             ],
             trashed: true
           }}
      end
    end
  end

  defp slug(_group, _slug),
    do: Common.invalid("slug", "a timestamp-mode group has no post slugs", "slug_not_allowed")

  # --- dry run -----------------------------------------------------------------------------

  defp preview(input, group, slug, ctx) do
    content = input["content"] || ""

    row = %{
      "action" => "create",
      "group" => group.slug,
      "mode" => group.mode,
      "title" => input["title"],
      "slug" => slug,
      "content" => Common.content_change("", content)
    }

    term = {:create_post, group.slug, group.status, input["title"], slug, Common.sha256(content)}
    Common.preview([row], %{"requires_confirmation" => Danger.create_post(input, ctx)}, term)
  end

  # --- write ----------------------------------------------------------------------------------

  defp execute(input, group, slug, ctx) do
    attrs =
      [title: input["title"], content: input["content"], slug: slug]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Posts.create_post(group.slug, attrs ++ Common.write_opts(ctx, @tool)) do
      {:ok, post} ->
        db = DBStorage.get_post_by_uuid(post[:uuid], [:group])
        versions = DBStorage.list_versions(db.uuid)
        contents = DBStorage.list_contents(hd(versions).uuid)
        changed = ["title"] ++ if(input["content"] in [nil, ""], do: [], else: ["content"])

        {:ok,
         %{
           "action" => "created",
           "post" => Presenter.write_summary(db, db.group, versions, contents),
           "changed" => changed
         }}

      {:error, reason} ->
        Common.error(reason)
    end
  end
end
