defmodule PhoenixKit.Modules.Publishing.API.GetPost do
  @moduledoc false
  # Tool `publishing.get_post`. A read never writes: the post is read WITHOUT the stale fixer
  # (`Posts.read_post_by_uuid/3` would trash an empty post or move a stale active pointer, a visitor-
  # visible change under a key that holds only the read scope). A stale post is shown as stored.

  alias PhoenixKit.Modules.Publishing.API.{Common, Presenter, Refs}
  alias PhoenixKit.Modules.Publishing.{DBStorage, PublishingContent, PublishingVersion}

  @spec call(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def call(input, _ctx) do
    with {:ok, hit} <- resolve(input["post"]),
         {:ok, version} <- version(hit.db_post, input["version"]),
         {:ok, language} <-
           language(input["language"], DBStorage.list_contents(version.uuid)),
         {:ok, post} <- read(hit.db_post.uuid, language, version.version_number),
         {:ok, state} <- snapshot(hit, version, language, post) do
      {:ok, build(state, input)}
    end
  end

  defp snapshot(hit, version, language, post) do
    {:ok,
     %{
       hit: hit,
       version: version,
       contents: DBStorage.list_contents(version.uuid),
       post: post,
       requested: language
     }}
  end

  # A post without any version has nothing to read; "version_not_found" would blame a version
  # the caller never named.
  defp version(db_post, number) do
    case Refs.resolve_version(db_post, number, :read) do
      {:error, :version_not_found} when is_nil(number) ->
        {:error, :not_found, "The post has no versions.", %{}}

      other ->
        Refs.version_error(other)
    end
  end

  # A trashed post is not_found here, with context.trashed (list_posts status trashed shows it).
  defp resolve(ref) do
    case Refs.resolve_post(ref, []) do
      {:error, {:post_trashed, _db_post}} ->
        {:error, :not_found, "The post is in the trash; list_posts with status trashed shows it.",
         %{trashed: true}}

      other ->
        Refs.post_error(other, ref)
    end
  end

  # A language the post HAS stays readable after it was disabled.
  defp language(input, contents) do
    case Refs.resolve_language(input, Enum.map(contents, & &1.language)) do
      {:ok, language} ->
        {:ok, language}

      {:error, {:language_not_enabled, allowed}} ->
        Common.invalid("language", "is not an enabled language", "language_not_enabled", %{
          allowed: allowed
        })
    end
  end

  defp read(uuid, language, number) do
    case Refs.read_post_for_preview(uuid, language, number) do
      {:ok, post} -> {:ok, post}
      {:error, _reason} -> {:error, :not_found, "The post could not be read.", %{}}
    end
  end

  defp build(state, input) do
    %{hit: hit, version: version, contents: contents, post: post, requested: requested} = state
    shown = post[:language]
    content = Enum.find(contents, &(&1.language == shown))
    versions = DBStorage.list_versions(hit.db_post.uuid)

    detail = %{
      "title" => content && content.title,
      "version" => version.version_number,
      "language" => shown,
      "fields" => fields(version, content),
      "content_updated_at" => content && Presenter.iso(content.updated_at),
      "revision" => Common.post_revision(hit.db_post, version, content)
    }

    detail =
      if input["include_content"] == false,
        do: detail,
        else: Map.put(detail, "markdown", post[:content] || "")

    hit.db_post
    |> Presenter.post_summary(
      hit.group,
      versions,
      summary_contents(hit.db_post, versions, version, contents)
    )
    |> Map.merge(detail)
    |> Common.with_warnings(warnings(shown, requested, input["language"]))
  end

  # The summary describes the post as list_posts does: the rows of the live version, else the latest.
  # An explicitly requested version only supplies the body, the fields, the revision and the title.
  defp summary_contents(db_post, versions, version, contents) do
    shown =
      Enum.find(versions, &(&1.uuid == db_post.active_version_uuid)) ||
        Enum.max_by(versions, & &1.version_number, fn -> nil end)

    cond do
      is_nil(shown) -> contents
      shown.uuid == version.uuid -> contents
      true -> DBStorage.list_contents(shown.uuid)
    end
  end

  # The module falls back silently to another language: never present that text as the requested one.
  defp warnings(shown, shown, _asked), do: []

  defp warnings(shown, requested, asked) do
    subject = if is_nil(asked), do: "the primary language #{requested}", else: requested

    [
      %{
        "code" => "language_missing",
        "message" => "#{subject} has no text on this version; showing #{shown}"
      }
    ]
  end

  # seo_title and excerpt live in version.data (version-level), not in the post map's metadata.
  defp fields(version, content) do
    data = version.data || %{}
    og = (content && PublishingContent.get_og(content)) || %{}

    %{
      "description" => data["description"],
      "seo_title" => data["seo_title"],
      "excerpt" => data["excerpt"],
      "featured_image_id" => PublishingVersion.get_featured_image_uuid(version),
      "featured" => PublishingVersion.get_featured(version),
      "sitemap_exclude" => PublishingVersion.get_sitemap_exclude(version),
      "og" => %{
        "title" => og["title"],
        "description" => og["description"],
        "image_id" => og["image_uuid"]
      },
      "tags" => PublishingVersion.get_tags(version),
      "category_ids" => PublishingVersion.get_category_uuids(version),
      "url_slug" => content && content.url_slug
    }
  end
end
