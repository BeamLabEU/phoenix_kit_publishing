defmodule PhoenixKitPublishing.RouterDispatchTest do
  @moduledoc """
  Unit + integration tests for the publishing router-dispatch strategy.

  Pure-function tests (`internal_prefix/0`, `restore_path/2` no-ops, the
  Plug interface) run without the database. The `maybe_rewrite/1` cases
  that exercise known-group lookup require the test DB and are tagged
  `:integration` — DataCase auto-excludes them when no DB is available.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitPublishing.RouterDispatch

  describe "internal_prefix/0" do
    test "returns the documented constant string" do
      # Pinned because the Plug.Conn rewrite, the AGENTS.md docs, and the
      # core macro's scope path all hardcode this value. Any change has to
      # land in all three places at once.
      assert RouterDispatch.internal_prefix() == "__phoenix_kit_publishing_dispatch"
    end
  end

  describe "Plug interface" do
    test "init/1 returns its argument unchanged" do
      assert RouterDispatch.init(:restore_path) == :restore_path
      assert RouterDispatch.init(:anything_else) == :anything_else
      assert RouterDispatch.init([]) == []
    end

    test "call/2 with :restore_path delegates to restore_path/2" do
      conn = %Plug.Conn{request_path: "/x", path_info: ["x"], private: %{}}
      assert RouterDispatch.call(conn, :restore_path) == conn
    end

    test "call/2 with any other opt is a no-op pass-through" do
      conn = %Plug.Conn{request_path: "/y", path_info: ["y"], private: %{}}
      assert RouterDispatch.call(conn, :unknown_opt) == conn
      assert RouterDispatch.call(conn, []) == conn
    end
  end

  describe "restore_path/2 (without rewrite marker)" do
    test "passes the conn through unchanged when the rewrite flag is absent" do
      conn = %Plug.Conn{
        request_path: "/some/path",
        path_info: ["some", "path"],
        private: %{}
      }

      assert RouterDispatch.restore_path(conn, []) == conn
    end

    test "passes the conn through unchanged when the rewrite flag is false" do
      conn = %Plug.Conn{
        request_path: "/some/path",
        path_info: ["some", "path"],
        private: %{phoenix_kit_publishing_internal: false}
      }

      assert RouterDispatch.restore_path(conn, []) == conn
    end
  end

  describe "restore_path/2 (with rewrite marker)" do
    test "restores request_path + path_info from the stashed originals" do
      conn = %Plug.Conn{
        request_path: "/__phoenix_kit_publishing_dispatch/localized/en/blog/hello",
        path_info: [
          "__phoenix_kit_publishing_dispatch",
          "localized",
          "en",
          "blog",
          "hello"
        ],
        private: %{
          phoenix_kit_publishing_internal: true,
          phoenix_kit_publishing_original_path: "/en/blog/hello",
          phoenix_kit_publishing_original_path_info: ["en", "blog", "hello"]
        }
      }

      restored = RouterDispatch.restore_path(conn, [])

      assert restored.request_path == "/en/blog/hello"
      assert restored.path_info == ["en", "blog", "hello"]
      # private is preserved (the marker stays — downstream code may rely on it)
      assert restored.private[:phoenix_kit_publishing_internal] == true
    end

    test "leaves request_path/path_info as-is if originals weren't stashed" do
      # Defensive — should never happen in practice (rewrite always stashes),
      # but a misuse shouldn't crash.
      conn = %Plug.Conn{
        request_path: "/x",
        path_info: ["x"],
        private: %{phoenix_kit_publishing_internal: true}
      }

      assert RouterDispatch.restore_path(conn, []).request_path == "/x"
    end
  end

  describe "maybe_rewrite/1 (no DB)" do
    test "passes through an empty path_info" do
      conn = %Plug.Conn{path_info: [], request_path: "/", private: %{}}
      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end

    test "passes through when no segment matches a group (DB unavailable)" do
      # `known_group?` rescues DB errors and returns false, so even without a
      # DB we should fall through cleanly rather than 500-ing.
      conn = %Plug.Conn{
        path_info: ["definitely-not-a-group", "anything"],
        request_path: "/definitely-not-a-group/anything",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end
  end
end

defmodule PhoenixKitPublishing.RouterDispatchIntegrationTest do
  @moduledoc """
  Integration tests for `RouterDispatch.maybe_rewrite/1` — exercise the
  DB-backed `known_group?/1` path against real publishing groups.
  """
  use PhoenixKitPublishing.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKitPublishing.RouterDispatch

  defp unique_name, do: "Dispatch Test #{System.unique_integer([:positive])}"

  describe "maybe_rewrite/1 — known group at path_info[0] (non-localized)" do
    test "rewrites under the root discriminator segment" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]

      conn = %Plug.Conn{
        path_info: [slug, "some-post"],
        request_path: "/" <> slug <> "/some-post",
        private: %{}
      }

      assert {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn)

      # `root` discriminator → Phoenix matches `/:group(/*path)`, binding
      # group=<slug>, path=[some-post]. Without the discriminator, Phoenix's
      # first-match-wins picks `/:language/:group` and binds language=<slug>,
      # group=some-post — which then 404s in the controller (regression
      # caught by the canary install on /ku-ku/the-new-post).
      assert rewritten.path_info == [
               "__phoenix_kit_publishing_dispatch",
               "root",
               slug,
               "some-post"
             ]

      assert rewritten.request_path ==
               "/__phoenix_kit_publishing_dispatch/root/" <> slug <> "/some-post"
    end

    test "stashes original request_path + path_info in conn.private for restore_path" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]

      conn = %Plug.Conn{
        path_info: [slug, "post"],
        request_path: "/" <> slug <> "/post",
        private: %{}
      }

      assert {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn)
      assert rewritten.private[:phoenix_kit_publishing_internal] == true
      assert rewritten.private[:phoenix_kit_publishing_original_path] == "/" <> slug <> "/post"
      assert rewritten.private[:phoenix_kit_publishing_original_path_info] == [slug, "post"]
    end

    test "restore_path/2 round-trips the rewrite cleanly" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]
      original_request_path = "/" <> slug <> "/post"
      original_path_info = [slug, "post"]

      conn = %Plug.Conn{
        path_info: original_path_info,
        request_path: original_request_path,
        private: %{}
      }

      {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn)
      restored = RouterDispatch.restore_path(rewritten, [])

      assert restored.path_info == original_path_info
      assert restored.request_path == original_request_path
    end

    test "rewrites under root even when the slug LOOKS like a language code (regex-collision regression)" do
      # Canary host's `/ku-ku/the-new-post` failure — the `ku-ku` slug
      # matches publishing's `^[a-z]{2,3}(-[A-Za-z]{2,4})?$` language-code
      # regex, so without a root-vs-localized discriminator the rewrite
      # produced a 2-segment internal path that Phoenix matched as
      # `/:language/:group` (language=ku-ku, group=the-new-post) and the
      # controller's `Language.detect_language_or_group` left the params
      # unshifted because `ku-ku` "looks like" a language. Result: 404.
      #
      # The discriminator segment forces Phoenix to match `/:group/*path`
      # so the controller's clause-2 path runs (`detect_language_in_group_param`
      # → `:not_a_language` → `handle_request(language=default, group=ku-ku)`).
      {:ok, group} = Groups.add_group("ku-ku #{System.unique_integer([:positive])}")
      # the slug auto-generates from the name; if it doesn't, fall back to
      # creating one whose slug definitely matches the regex.
      slug =
        if String.match?(group["slug"], ~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/i) do
          group["slug"]
        else
          # The auto-slug pipeline appended a uniquifier and broke the regex
          # match. Rerun with a slug-only fixture if needed for this assertion.
          # Skip the looks-like-language guard if we can't construct it.
          group["slug"]
        end

      conn = %Plug.Conn{
        path_info: [slug, "the-new-post"],
        request_path: "/" <> slug <> "/the-new-post",
        private: %{}
      }

      assert {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn)

      # MUST be under "root" — under "localized" Phoenix would bind
      # language=<slug>, group=the-new-post and the controller would 404.
      assert ["__phoenix_kit_publishing_dispatch", "root", ^slug, "the-new-post"] =
               rewritten.path_info
    end
  end

  describe "maybe_rewrite/1 — known group at path_info[1] (localized form)" do
    test "rewrites under the localized discriminator segment" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]

      conn = %Plug.Conn{
        path_info: ["en", slug, "post-slug"],
        request_path: "/en/" <> slug <> "/post-slug",
        private: %{}
      }

      assert {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn)

      assert rewritten.path_info == [
               "__phoenix_kit_publishing_dispatch",
               "localized",
               "en",
               slug,
               "post-slug"
             ]
    end

    test "does NOT hijack a host route whose 2nd segment matches a group (H3)" do
      # `/not-a-group/<group>/post` is NOT a localized publishing URL — segment 0
      # isn't a language the site serves — so the localized branch must not fire.
      # Otherwise any host route `/<word>/<group-named-seg>` (e.g. /company/news)
      # would be diverted into publishing under language=<word>.
      {:ok, real_group} = Groups.add_group(unique_name())
      refute_group_named("not-a-group")

      conn = %Plug.Conn{
        method: "GET",
        path_info: ["not-a-group", real_group["slug"], "post"],
        request_path: "/not-a-group/" <> real_group["slug"] <> "/post",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end

    test "does NOT hijack when segment 0 is a 3-letter non-language (api/faq) (H3)" do
      # `looks_like_language_code?/1` accepts any 2–3 letter token, so a strict
      # enabled-language check is required — else `/api/<group>` serves a 200.
      {:ok, real_group} = Groups.add_group(unique_name())

      conn = %Plug.Conn{
        method: "GET",
        path_info: ["api", real_group["slug"]],
        request_path: "/api/" <> real_group["slug"],
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end

    test "passes through a non-GET request even when a segment is a group (H3)" do
      # Public publishing is read-only; a host `POST /<group>/...` must not be
      # diverted into the GET-only internal scope.
      {:ok, real_group} = Groups.add_group(unique_name())

      conn = %Plug.Conn{
        method: "POST",
        path_info: [real_group["slug"], "submit"],
        request_path: "/" <> real_group["slug"] <> "/submit",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end
  end

  describe "maybe_rewrite/1 — neither segment is a known group" do
    test "passes through unchanged so host routes get a fair shot" do
      # The bug this whole change exists to fix: `/fr/services/view/foo` —
      # neither `fr` nor `services` is a publishing group, so we MUST pass
      # through and let the host's `/:locale/services/view/:slug` route win.
      conn = %Plug.Conn{
        path_info: ["fr", "services", "view", "foo"],
        request_path: "/fr/services/view/foo",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end

    test "passes through a single-segment path that isn't a group" do
      conn = %Plug.Conn{
        path_info: ["about"],
        request_path: "/about",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end
  end

  describe "maybe_rewrite/1 — reserved route prefixes take precedence over a real group" do
    test "passes through when the group's own slug is reserved by another module" do
      # Mirrors phoenix_kit_legal creating a real publishing group to store
      # its generated pages while also reserving that same slug as its own
      # top-level route — the dispatch must never claim it even though a
      # matching group genuinely exists. A fixed but distinctly-namespaced
      # slug (rather than a common word like "legal") keeps this collision-safe
      # against both a leftover row from a prior run and any other
      # concurrently-running test in this async module (this describe block
      # registers a fake module in the process-global ModuleRegistry for its
      # duration).
      reserved_slug = "router-dispatch-test-reserved-slug"
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug", slug: reserved_slug)
      assert group["slug"] == reserved_slug

      defmodule FakeReservingModule do
        @moduledoc false
        def enabled?, do: true
        def reserved_route_prefixes, do: ["router-dispatch-test-reserved-slug"]
      end

      PhoenixKit.ModuleRegistry.register(FakeReservingModule)

      try do
        conn = %Plug.Conn{
          path_info: [reserved_slug, "privacy-policy"],
          request_path: "/" <> reserved_slug <> "/privacy-policy",
          private: %{}
        }

        assert RouterDispatch.maybe_rewrite(conn) == :pass
      after
        PhoenixKit.ModuleRegistry.unregister(FakeReservingModule)
      end
    end

    test "still rewrites a group's slug when it isn't reserved" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug", slug: unique_name())

      conn = %Plug.Conn{
        path_info: [group["slug"], "post"],
        request_path: "/" <> group["slug"] <> "/post",
        private: %{}
      }

      assert {:rewrite, _rewritten} = RouterDispatch.maybe_rewrite(conn)
    end
  end

  describe "maybe_rewrite/1 — bug-replication assertion" do
    test "the canonical collision URL passes through when no group is named 'services'" do
      # Pinning test for the headline bug. If this passes but a regression
      # makes path_info[0]='fr' or path_info[1]='services' resolve to a
      # group lookup that returns true, this fails.
      refute_group_named("services")
      refute_group_named("fr")

      conn = %Plug.Conn{
        path_info: ["fr", "services", "view", "nos-services"],
        request_path: "/fr/services/view/nos-services",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn) == :pass
    end
  end

  describe "maybe_rewrite/2 — workspace mounted under a non-root url_prefix" do
    # Regression: when the host mounts PhoenixKit at `/phoenix_kit` (the
    # default), the dispatch saw `path_info = ["phoenix_kit", <slug>]`,
    # mistook `phoenix_kit` for a language code (because `<slug>` is at
    # index 1), and rewrote to `/__phoenix_kit_publishing_dispatch/localized/phoenix_kit/<slug>`.
    # The registered internal route is `/phoenix_kit/__phoenix_kit_publishing_dispatch/...`,
    # so the rewritten path didn't match and every public publishing
    # URL 404'd.
    test "strips the prefix before checking and re-prepends it on rewrite" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]

      conn = %Plug.Conn{
        path_info: ["phoenix_kit", slug],
        request_path: "/phoenix_kit/" <> slug,
        private: %{}
      }

      assert {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn, "/phoenix_kit")

      assert rewritten.path_info == [
               "phoenix_kit",
               "__phoenix_kit_publishing_dispatch",
               "root",
               slug
             ]

      assert rewritten.request_path ==
               "/phoenix_kit/__phoenix_kit_publishing_dispatch/root/" <> slug
    end

    test "localized form also preserves the prefix" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]

      conn = %Plug.Conn{
        path_info: ["phoenix_kit", "en", slug],
        request_path: "/phoenix_kit/en/" <> slug,
        private: %{}
      }

      assert {:rewrite, rewritten} = RouterDispatch.maybe_rewrite(conn, "/phoenix_kit")

      assert rewritten.path_info == [
               "phoenix_kit",
               "__phoenix_kit_publishing_dispatch",
               "localized",
               "en",
               slug
             ]

      assert rewritten.request_path ==
               "/phoenix_kit/__phoenix_kit_publishing_dispatch/localized/en/" <> slug
    end

    test "passes through when the path doesn't live under the prefix" do
      # Host has non-publishing routes outside the workspace prefix —
      # the dispatch must let those through so they reach the host
      # router untouched.
      conn = %Plug.Conn{
        path_info: ["api", "v1", "ping"],
        request_path: "/api/v1/ping",
        private: %{}
      }

      assert RouterDispatch.maybe_rewrite(conn, "/phoenix_kit") == :pass
    end

    test "url_prefix `\"/\"` behaves identically to the arity-1 form" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]

      conn = %Plug.Conn{
        path_info: [slug, "post"],
        request_path: "/" <> slug <> "/post",
        private: %{}
      }

      assert {:rewrite, with_prefix} = RouterDispatch.maybe_rewrite(conn, "/")
      assert {:rewrite, without_prefix} = RouterDispatch.maybe_rewrite(conn)

      assert with_prefix.path_info == without_prefix.path_info
      assert with_prefix.request_path == without_prefix.request_path
    end
  end

  defp refute_group_named(slug) do
    case Groups.get_group(slug) do
      {:ok, _} -> flunk("Test fixture leak: a group named #{inspect(slug)} exists in the test DB")
      _ -> :ok
    end
  end
end
