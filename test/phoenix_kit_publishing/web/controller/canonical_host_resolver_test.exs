defmodule PhoenixKit.Modules.Publishing.Web.Controller.CanonicalHostResolverStub do
  @moduledoc false
  # Multi-domain resolver stubs used by the tests below.
  def host("en"), do: "decor.example.com"
  def host(_), do: nil

  def none(_), do: nil
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
end
