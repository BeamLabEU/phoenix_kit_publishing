defmodule PhoenixKit.Modules.Publishing.Web.Controller.DispatchE2eTest do
  @moduledoc """
  End-to-end pins for the publishing↔core routing seam, through a router
  built by core's REAL `phoenix_kit_routes()` macro (`Test.DispatchRouter`):
  the `call/2` rewrite, the internal dispatch scope, and `restore_path`.

  Exists because both live bugs of the 2026-07 wave sat exactly here,
  invisible to the unit suites on either side:

  1. the locale plug leaked `/__phoenix_kit_publishing_dispatch/...` into
     redirect Locations (restore_path ran too late in the pipeline), and
  2. comment POSTs raised NoRouteError (the rewrite passed non-GET/HEAD).

  The macro's compile-time url_prefix resolves to the `"/phoenix_kit"`
  fallback in the test build, so requests go under that prefix. Runtime
  URL *building* uses the test-pinned `"/"` prefix, so redirect chains
  aren't followed to completion — every assertion is per-response:
  it routed (no NoRouteError → no 404/500), and no Location ever carries
  the internal dispatch prefix.
  """

  # async: false — global settings rows.
  use ExUnit.Case, async: false

  # This one doesn't go through ConnCase/LiveCase (it needs core's real
  # router macro, not the test router), so it has to carry the tag those
  # case templates add. Without it `mix test` fails on a checkout with no
  # Postgres, which the suite is documented to survive — the sandbox
  # checkout below is the first thing to raise.
  @moduletag :integration

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Settings
  alias PhoenixKitPublishing.Test.Repo, as: TestRepo

  @endpoint PhoenixKitPublishing.Test.DispatchEndpoint
  @prefix "/phoenix_kit"
  @internal "__phoenix_kit_publishing_dispatch"

  defp unique_name, do: "dsp-#{System.unique_integer([:positive])}"

  setup do
    pid = Sandbox.start_owner!(TestRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", true)

    {:ok, _} =
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{
            "code" => "en-US",
            "name" => "English",
            "is_default" => true,
            "is_enabled" => true,
            "position" => 0
          }
        ]
      })

    {:ok, _} = Settings.update_setting("content_language", "en")
    # The comments MODULE switch — the POST pin needs the seam available.
    {:ok, _} = Settings.update_boolean_setting("comments_enabled", true)

    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    slug = group["slug"]

    {:ok, _} = Groups.update_group(slug, %{"comments_enabled" => "true"})

    {:ok, post} = Posts.create_post(slug, %{title: "Routed", slug: "routed", content: "Body."})
    :ok = Versions.publish_version(slug, post.uuid, 1)

    %{slug: slug, post: post}
  end

  defp location(conn), do: get_resp_header(conn, "location") |> List.first()

  defp assert_no_internal_leak(conn) do
    loc = location(conn)
    refute loc && loc =~ @internal, "internal dispatch prefix leaked into Location: #{loc}"
    refute conn.status in [404, 500]
    conn
  end

  test "GET listing and post route through the dispatch", %{slug: slug} do
    for path <- ["#{@prefix}/#{slug}", "#{@prefix}/#{slug}/routed"] do
      build_conn() |> get(path) |> assert_no_internal_leak()
    end
  end

  test "language-prefixed GETs never leak the internal prefix (restore_path pin)", %{slug: slug} do
    # The 2026-07 C0 bug: these redirected to /__phoenix_kit_publishing_dispatch/…
    # because the locale plug ran before restore_path.
    # Only enabled-language segments enter the localized branch (H3's strict
    # check) — a disabled language passes through to host routes by design.
    for lang <- ["en", "en-US"] do
      build_conn() |> get("#{@prefix}/#{lang}/#{slug}") |> assert_no_internal_leak()
    end
  end

  test "comment POSTs route through the dispatch instead of NoRouteError", %{
    slug: slug,
    post: post
  } do
    # The live bug: maybe_rewrite passed non-GET/HEAD, so this raised
    # Phoenix.Router.NoRouteError. Logged-out + guarded, it must now resolve
    # to the controller and redirect with a flash.
    conn =
      build_conn()
      |> post("#{@prefix}/#{slug}/routed", %{
        "post_uuid" => post.uuid,
        "content" => "hi",
        "ft" => "x",
        "website" => ""
      })

    assert conn.status == 302
    assert_no_internal_leak(conn)
  end

  # (Non-group pass-through is pinned at the maybe_rewrite unit level in
  # router_dispatch_test.exs — in this harness core's full route surface
  # catches such paths itself, so the host-wins semantics can't be observed
  # here without declaring host routes inside the macro's scope.)

  # Sibling-dialect URLs traverse core's locale plug inside the dispatch
  # pipeline, and the RELEASED core still 301s every hyphenated segment to
  # its base — the acceptance branch ships in the paired core change. Until
  # that release:  PHOENIX_KIT_PATH=../phoenix_kit mix test --include needs_unreleased_core
  @tag :needs_unreleased_core
  test "a sibling-dialect URL survives the full dispatch + locale pipeline", %{slug: slug} do
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

    {:ok, gb_group} = Groups.add_group(unique_name(), mode: "slug")
    gb_slug = gb_group["slug"]

    {:ok, post} =
      Posts.create_post(gb_slug, %{title: "Color", slug: "color", content: "US body."})

    {:ok, _} = Publishing.add_language_to_post(gb_slug, post.uuid, "en-GB", 1)
    {:ok, gb_read} = Publishing.read_post_by_uuid(post.uuid, "en-GB", 1)

    {:ok, _} =
      Posts.update_post(gb_slug, gb_read, %{"title" => "Colour", "content" => "UK body."}, %{})

    :ok = Versions.publish_version(gb_slug, post.uuid, 1)

    conn = build_conn() |> get("#{@prefix}/en-gb/#{gb_slug}")

    # The old core plug 301'd /en-gb/... to /en/... before publishing ran;
    # with the paired core change the sibling listing renders directly.
    assert conn.status == 200
    body = html_response(conn, 200)
    assert body =~ "Colour"
    refute body =~ "US body."
    assert_no_internal_leak(conn)

    # The primary's base URL still routes through the same pipeline. (This
    # harness pins runtime URL building to "/" while routes live under
    # @prefix, so canonical redirects can fire — per-response assertions
    # only, like the rest of this file.)
    en_conn = build_conn() |> get("#{@prefix}/en/#{gb_slug}")
    assert_no_internal_leak(en_conn)

    _ = slug
  end
end
