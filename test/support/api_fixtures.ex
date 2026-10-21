defmodule PhoenixKitPublishing.Test.ApiFixtures do
  @moduledoc false
  # Fixtures for the API tests. Every function writes through the module's own contexts.

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Publishing

  alias PhoenixKit.Modules.Publishing.{
    Categories,
    DBStorage,
    Groups,
    Posts,
    TranslationManager,
    Versions
  }

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitPublishing.Test.Repo

  @doc "Enables the given language codes (the first is the default/primary)."
  def languages!(codes \\ ["en-US", "de-DE"]) do
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    languages =
      codes
      |> Enum.with_index()
      |> Enum.map(fn {code, i} ->
        %{
          "code" => code,
          "name" => code,
          "is_default" => i == 0,
          "is_enabled" => true,
          "position" => i
        }
      end)

    {:ok, _} = Settings.update_json_setting("languages_config", %{"languages" => languages})
    codes
  end

  @doc "A slug-mode group (or `mode: \"timestamp\"`). Returns the group map (string keys)."
  def group!(opts \\ []) do
    mode = Keyword.get(opts, :mode, "slug")
    name = Keyword.get(opts, :name, "Api Group #{System.unique_integer([:positive])}")
    {:ok, group} = Groups.add_group(name, mode: mode)
    group
  end

  @doc "A draft post with a primary-language title. Returns the post map."
  def post!(group_slug, attrs \\ %{}) do
    attrs =
      Map.merge(%{title: "Fixture Post #{System.unique_integer([:positive])}"}, Map.new(attrs))

    {:ok, post} = Posts.create_post(group_slug, attrs)
    post
  end

  @doc "Publishes version `n` (default 1) of the post."
  def publish!(group_slug, post_uuid, version \\ 1) do
    :ok = Versions.publish_version(group_slug, post_uuid, version)
  end

  @doc "Adds a language row to the post's version and fills its title and body."
  def translation!(group_slug, post_uuid, language, title, content, version \\ 1) do
    {:ok, _} = TranslationManager.add_language_to_post(group_slug, post_uuid, language, version)
    {:ok, post} = Posts.read_post_by_uuid(post_uuid, language, version)

    {:ok, _} =
      Posts.update_post(group_slug, post, %{"title" => title, "content" => content},
        publish: false
      )

    :ok
  end

  @doc "Sets the body of the primary-language row of version `version`."
  def body!(group_slug, post_uuid, content, version \\ 1) do
    {:ok, post} = Posts.read_post_by_uuid(post_uuid, nil, version)
    {:ok, _} = Posts.update_post(group_slug, post, %{"content" => content}, publish: false)
    :ok
  end

  def category!(group_slug, name, attrs \\ %{}) do
    slug = Map.get(attrs, :slug, name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"))

    {:ok, category} =
      Categories.create_category(group_slug, Map.merge(%{name: name, slug: slug}, attrs))

    category
  end

  @doc "Counts rows of the four content tables and the activity log, for 'a dry run writes nothing'."
  def table_state do
    for table <-
          ~w(phoenix_kit_publishing_groups phoenix_kit_publishing_posts phoenix_kit_publishing_versions
                    phoenix_kit_publishing_contents phoenix_kit_publishing_categories phoenix_kit_activities),
        into: %{} do
      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT count(*) FROM #{table}")

      %{rows: [[digest]]} =
        SQL.query!(
          Repo,
          "SELECT coalesce(md5(string_agg(t::text, '' ORDER BY t::text)), '') FROM #{table} t"
        )

      {table, {count, digest}}
    end
  end

  def ref(post), do: %{"id" => post[:uuid]}
  def db_post(uuid), do: DBStorage.get_post_by_uuid(uuid)
  def db_group_slug(uuid), do: DBStorage.get_post_by_uuid(uuid, [:group]).group.slug
  def version(uuid, number \\ 1), do: DBStorage.get_version(uuid, number)

  def contents(uuid, number \\ 1),
    do: uuid |> version(number) |> Map.fetch!(:uuid) |> DBStorage.list_contents()

  def content(uuid, language \\ "en-US", number \\ 1),
    do: uuid |> contents(number) |> Enum.find(&(&1.language == language))

  @doc "A user row (for tests that assert created_by). Inserted directly: register_user/1 rides the rate limiter, which the test env does not start."
  def user! do
    Repo.insert!(%User{
      email: "pub-api-#{System.unique_integer([:positive])}@example.com",
      hashed_password: "x",
      first_name: "Pub",
      last_name: "Api"
    })
  end

  def enable_module!, do: {:ok, _} = Publishing.enable_system()
end
