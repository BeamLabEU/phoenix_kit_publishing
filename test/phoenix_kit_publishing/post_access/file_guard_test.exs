defmodule PhoenixKit.Modules.Publishing.PostAccess.FileGuardTest do
  @moduledoc """
  Publishing's file access guard (`Publishing.file_access_guard/2` →
  `PostAccess.FileGuard`): a file only protected posts use is served to the
  readers who may open one of them, `:private`, and to nobody else, `:deny`;
  every other file is `:allow`. The end-to-end run through core's
  `Storage.AccessGuard` needs an unreleased core and is tagged.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PageBuilder.Components.Image
  alias PhoenixKit.Modules.Publishing.PostAccess
  alias PhoenixKit.Modules.Publishing.PostAccess.FileGuard
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.LiveCase
  alias PhoenixKitPublishing.Test.MediaFixtures

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} = Groups.add_group("fg-#{System.unique_integer([:positive])}", mode: "slug")
    slug = group["slug"]
    image = MediaFixtures.file!()
    inline = MediaFixtures.file!()

    {:ok, post} =
      Posts.create_post(slug, %{
        title: "Board pack",
        slug: "board-pack",
        content: ~s(Figures: <Image file_uuid="#{inline.uuid}" />)
      })

    {:ok, read} = Publishing.read_post_by_uuid(post.uuid, "en", 1)
    {:ok, _} = Posts.update_post(slug, read, %{"featured_image_uuid" => image.uuid}, %{})
    :ok = Versions.publish_version(slug, post.uuid, 1)
    {:ok, pw} = PostAccess.set_password({:post, post.uuid}, "board pw")
    FileGuard.invalidate()

    %{slug: slug, post: post, image: image, inline: inline, pw: pw}
  end

  defp anon_conn,
    do: Phoenix.ConnTest.build_conn() |> Plug.Conn.assign(:phoenix_kit_current_scope, nil)

  defp scope_conn(scope),
    do: Phoenix.ConnTest.build_conn() |> Plug.Conn.assign(:phoenix_kit_current_scope, scope)

  test "a file no protected post uses is :allow" do
    other = MediaFixtures.file!()
    assert FileGuard.check(other, anon_conn()) == :allow
    assert Publishing.file_access_guard(other, anon_conn()) == :allow
  end

  test "the featured image and an inline image of a protected post are :deny to a stranger", %{
    image: image,
    inline: inline
  } do
    assert FileGuard.check(image, anon_conn()) == :deny
    assert FileGuard.check(inline, anon_conn()) == :deny
  end

  test "editors and media holders get :private (the admin screens use the same route)", %{
    image: image
  } do
    assert FileGuard.check(image, scope_conn(LiveCase.fake_scope())) == :private

    media =
      LiveCase.fake_scope(
        user_uuid: "019cce93-0000-7000-8000-0000000000ee",
        roles: ["User"],
        permissions: ["media"]
      )

    assert FileGuard.check(image, scope_conn(media)) == :private

    reader =
      LiveCase.fake_scope(
        user_uuid: "019cce93-0000-7000-8000-0000000000ef",
        roles: ["User"],
        permissions: []
      )

    assert FileGuard.check(image, scope_conn(reader)) == :deny
  end

  test "a reader who typed the password gets :private, from their cookie", %{
    conn: conn,
    slug: slug,
    post: post,
    image: image
  } do
    unlocked =
      post(conn, "/#{slug}/board-pack", %{
        "pk_access" => "unlock",
        "post_uuid" => post.uuid,
        "password" => "board pw"
      })

    # A request through the endpoint: the conn carries the cookie and the
    # secret it is encrypted with, as the file route's would.
    reader = unlocked |> recycle() |> get("/#{slug}")
    assert FileGuard.check(image, reader) == :private

    {:ok, _} = PostAccess.set_password({:post, post.uuid}, "rotated pw")
    assert FileGuard.check(image, reader) == :deny
  end

  test "a file a public post also shows stays :allow", %{slug: slug, image: image} do
    {:ok, open} =
      Posts.create_post(slug, %{
        title: "Open note",
        slug: "open-note",
        content: ~s(<Image file_uuid="#{image.uuid}" />)
      })

    :ok = Versions.publish_version(slug, open.uuid, 1)
    FileGuard.invalidate()

    assert FileGuard.check(image, anon_conn()) == :allow
  end

  test "making the post public again lifts the guard at the next listing rebuild", %{
    slug: slug,
    post: post,
    image: image
  } do
    assert FileGuard.check(image, anon_conn()) == :deny
    :ok = PostAccess.clear({:post, post.uuid})
    ListingCache.regenerate(slug)
    assert FileGuard.check(image, anon_conn()) == :allow
  end

  test "an index built before an invalidation is not stored over it", %{image: image} do
    # A build starts (reads the marker), a rule changes meanwhile...
    FileGuard.invalidate()
    marker = FileGuard.current_marker()
    FileGuard.invalidate()

    # ...so its result (here: "nothing guarded") must not be kept.
    refute FileGuard.store_if_unchanged(marker, %{}, System.monotonic_time(:millisecond) + 60_000)
    assert FileGuard.check(image, anon_conn()) == :deny
  end

  test "a signing failure renders the placeholder, never core's public-URL lookup" do
    # Not a uuid core can sign: the rescue must drop the file reference.
    attrs = %{"file_uuid" => MediaFixtures.file!().uuid}

    signed =
      Renderer.with_signed_files(true, fn ->
        Image.signed_src(Map.put(attrs, "file_variant", :not_a_string))
      end)

    refute Map.has_key?(signed, "file_uuid")
    refute Map.has_key?(signed, "src")
  end

  test "a protected post's body renders its files as signed kit URLs", %{inline: inline} do
    attrs = %{"file_uuid" => inline.uuid}
    assert Image.signed_src(attrs) == attrs

    signed = Renderer.with_signed_files(true, fn -> Image.signed_src(attrs) end)
    assert signed["src"] =~ "/file/#{inline.uuid}/original/"
    assert Map.has_key?(signed, "alt")
  end

  test "the protected post page renders the inline image through the kit route", %{
    conn: conn,
    slug: slug,
    post: post,
    inline: inline
  } do
    unlocked =
      post(conn, "/#{slug}/board-pack", %{
        "pk_access" => "unlock",
        "post_uuid" => post.uuid,
        "password" => "board pw"
      })

    body = unlocked |> recycle() |> get("/#{slug}/board-pack") |> html_response(200)
    assert body =~ "/file/#{inline.uuid}/"
  end

  @tag :needs_unreleased_core
  test "core's AccessGuard asks Publishing and combines the answer", %{image: image} do
    guard = Module.concat([PhoenixKit, Modules, Storage, AccessGuard])
    assert guard.check(image, anon_conn()) == :deny
    assert guard.check(MediaFixtures.file!(), anon_conn()) == :allow
  end
end
