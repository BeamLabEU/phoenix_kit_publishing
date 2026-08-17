defmodule PhoenixKit.Modules.Publishing.Web.Controller.CanonicalHostResolverStub do
  @moduledoc false
  # Multi-domain resolver stubs used by the tests below.
  def host("en"), do: "decor.example.com"
  def host(_), do: nil

  def none(_), do: nil

  # One home host per dialect — the shape a real multi-domain host app uses.
  def host_per_dialect("en-US"), do: "us.example.com"
  def host_per_dialect("en-GB"), do: "uk.example.com"
  def host_per_dialect(_), do: nil
end

defmodule PhoenixKit.Modules.Publishing.Web.Controller.CanonicalHostResolverTest do
  @moduledoc """
  The `:canonical_host_resolver` MFA (`config :phoenix_kit,
  :canonical_host_resolver, {mod, fun}`) lets multi-domain host apps put a
  page's og:url/canonical on the language's home host, with that language's
  own locale prefix stripped (it is the default there). Resolver absent or
  returning nil keeps the legacy request-host behavior.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.TranslationManager
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Web.Controller.CanonicalHostResolverStub
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} =
      Groups.add_group("canon-#{System.unique_integer([:positive])}", mode: "slug")

    {:ok, post} =
      Posts.create_post(group["slug"], %{
        title: "Canonical Post",
        slug: "canonical-post",
        content: "Body."
      })

    :ok = Versions.publish_version(group["slug"], post.uuid, 1)

    on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)

    %{group_slug: group["slug"]}
  end

  test "without a resolver og:url stays on the request host", %{
    conn: conn,
    group_slug: group_slug
  } do
    html = get(conn, "/#{group_slug}/canonical-post") |> html_response(200)

    assert html =~
             ~s(property="og:url" content="http://www.example.com/#{group_slug}/canonical-post")
  end

  test "resolver returning nil for the page language keeps the request host", %{
    conn: conn,
    group_slug: group_slug
  } do
    Application.put_env(
      :phoenix_kit,
      :canonical_host_resolver,
      {CanonicalHostResolverStub, :none}
    )

    html = get(conn, "/#{group_slug}/canonical-post") |> html_response(200)

    assert html =~
             ~s(property="og:url" content="http://www.example.com/#{group_slug}/canonical-post")
  end

  test "resolver host puts og:url on the language's home domain over https", %{
    conn: conn,
    group_slug: group_slug
  } do
    Application.put_env(
      :phoenix_kit,
      :canonical_host_resolver,
      {CanonicalHostResolverStub, :host}
    )

    html = get(conn, "/#{group_slug}/canonical-post") |> html_response(200)

    assert html =~
             ~s(property="og:url" content="https://decor.example.com/#{group_slug}/canonical-post")
  end

  test "translations assign keeps the enabled flag", %{conn: conn, group_slug: group_slug} do
    conn = get(conn, "/#{group_slug}/canonical-post")

    for t <- conn.assigns[:phoenix_kit_publishing_translations] || [] do
      assert Map.has_key?(t, :enabled)
    end
  end

  describe "sibling dialect: the actual URL segment must be stripped" do
    setup do
      {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)
      {:ok, _} = Settings.update_setting("content_language", "en-US")

      {:ok, _} =
        Settings.update_json_setting("languages_config", %{
          "languages" => [
            %{
              "code" => "en-US",
              "name" => "English (US)",
              "is_default" => true,
              "is_enabled" => true,
              "position" => 0
            },
            %{
              "code" => "en-GB",
              "name" => "English (UK)",
              "is_default" => false,
              "is_enabled" => true,
              "position" => 1
            }
          ]
        })

      {:ok, group} =
        Groups.add_group("dialect-#{System.unique_integer([:positive])}", mode: "slug")

      slug = group["slug"]

      {:ok, post} =
        Posts.create_post(slug, %{
          title: "Colour Story",
          slug: "colour-story",
          content: "The US body about color.\n\nMore."
        })

      {:ok, _} = TranslationManager.add_language_to_post(slug, post.uuid, "en-GB", nil)
      {:ok, gb_read} = Posts.read_post_by_uuid(post.uuid, "en-GB", 1)

      {:ok, _} =
        Posts.update_post(
          slug,
          gb_read,
          %{
            "title" => "Colour Story",
            "content" => "The UK body about colour.\n\nMore.",
            "url_slug" => "colour-story"
          },
          %{}
        )

      :ok = Versions.publish_version(slug, post.uuid, 1)

      Application.put_env(
        :phoenix_kit,
        :canonical_host_resolver,
        {CanonicalHostResolverStub, :host_per_dialect}
      )

      %{group_slug: slug}
    end

    test "non-owner sibling (en-GB, URL prefix /en-gb/) has its prefix stripped on its home host",
         %{conn: conn, group_slug: slug} do
      html = get(conn, "/en-gb/#{slug}/colour-story") |> html_response(200)

      # The en-GB page is on its own home host (uk.example.com) — its own
      # locale prefix is that domain's default and must be stripped, the
      # same way the primary/owner dialect already is.
      assert html =~ ~s(property="og:url" content="https://uk.example.com/#{slug}/colour-story")
      refute html =~ ~s(og:url" content="https://uk.example.com/en-gb/)
    end
  end
end
