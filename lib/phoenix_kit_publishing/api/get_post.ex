defmodule PhoenixKit.Modules.Publishing.API.GetPost do
  @moduledoc false
  # Tool `publishing.get_post`. The ONE handler allowed to use Posts.read_post_by_uuid/3:
  # it is a read path, not a gate, and a wrong not_found is only a read error. It may self-heal a
  # stale post exactly as the admin UI's reads do.

  alias PhoenixKit.Modules.Publishing.API.{Common, Presenter, Refs}
  alias PhoenixKit.Modules.Publishing.{DBStorage, Posts, PublishingContent, PublishingVersion}

  @spec call(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def call(input, _ctx) do
    with {:ok, hit} <- resolve(input["post"]),
         {:ok, version} <-
           Refs.resolve_version(hit.db_post, input["version"], :read) |> Refs.version_error(),
         contents = DBStorage.list_contents(version.uuid),
         {:ok, language} <- language(input["language"], contents),
         {:ok, post} <- read(hit.db_post.uuid, language, version.version_number) do
      {:ok, build(hit, version, contents, post, language, input)}
    end
  end

  # A trashed post is not_found here, with context.trashed (list_posts status trashed shows it).
  defp resolve(ref) do
    case Refs.resolve_post(ref, []) do
      {:error, {:post_trashed, _db_post}} ->
        {:error, :not_found, "The post is in the trash; list_posts with status trashed shows it.",
         %{trashed: true}}

      other ->
        Refs.post_error(other)
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
    case Posts.read_post_by_uuid(uuid, language, number) do
      {:ok, post} -> {:ok, post}
      {:error, _reason} -> {:error, :not_found, "The post could not be read.", %{}}
    end
  end

  defp build(hit, version, contents, post, requested, input) do
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

    # The module falls back silently to another language: never present that text as the requested one.
    warnings =
      if shown == requested,
        do: [],
        else: [
          %{
            "code" => "language_missing",
            "message" => "#{requested} has no text on this version; showing #{shown}"
          }
        ]

    hit.db_post
    |> Presenter.post_summary(hit.group, versions, contents)
    |> Map.merge(detail)
    |> Common.with_warnings(warnings)
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
