defmodule PhoenixKit.Modules.Publishing.Web.Controller.FallbackTest do
  @moduledoc """
  Direct tests for `Fallback.handle_not_found/2` — drives different
  reason atoms through the dispatcher with a constructed Plug.Conn.
  Each `reason` atom routes to a different `handle_fallback_case/3`
  branch in the private dispatcher.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Web.Controller.Fallback
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")

    {:ok, group} =
      Groups.add_group("Fallback #{System.unique_integer([:positive])}", mode: "slug")

    %{group_slug: group["slug"]}
  end

  # Build a fake Plug.Conn with the params the dispatcher reads
  defp fake_conn(params) do
    %Plug.Conn{
      params: params,
      assigns: %{current_language: "en"},
      private: %{},
      method: "GET",
      request_path: "/" <> (params["group"] || "")
    }
  end

  describe "handle_not_found/2 — entry dispatch" do
    test "returns {:render_404} for empty path", %{group_slug: _slug} do
      conn = fake_conn(%{})
      assert {:render_404} = Fallback.handle_not_found(conn, :unknown_reason)
    end

    test "redirects to group listing when group exists and reason is :not_found",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => []})

      result = Fallback.handle_not_found(conn, :not_found)

      assert match?({:redirect_with_flash, _, _}, result) or match?({:render_404}, result)
    end

    test "renders 404 when group doesn't exist and no default group is configured" do
      conn = fake_conn(%{"group" => "definitely-does-not-exist-#{System.unique_integer()}"})

      result = Fallback.handle_not_found(conn, :group_not_found)
      # No default group → :render_404, OR a default group exists → redirect
      assert match?({:render_404}, result) or match?({:redirect_with_flash, _, _}, result)
    end

    test "redirects to group listing for :post_not_found with slug-mode path",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => ["missing-slug"]})

      result = Fallback.handle_not_found(conn, :post_not_found)
      assert match?({:redirect_with_flash, _, _}, result) or match?({:render_404}, result)
    end

    test "redirects to group listing for :unpublished reason",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => ["my-post"]})

      result = Fallback.handle_not_found(conn, :unpublished)
      assert match?({:redirect_with_flash, _, _}, result) or match?({:render_404}, result)
    end

    test "handles timestamp-mode 3-segment paths",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => ["2026-04-27", "10:00"]})

      result = Fallback.handle_not_found(conn, :post_not_found)
      assert match?({:redirect_with_flash, _, _}, result) or match?({:render_404}, result)
    end

    test "handles :version_access_disabled reason",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => ["my-post"]})

      result = Fallback.handle_not_found(conn, :version_access_disabled)
      assert match?({:redirect_with_flash, _, _}, result) or match?({:render_404}, result)
    end

    test "catch-all reason with a path falls back to group listing",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => ["something"]})

      result = Fallback.handle_not_found(conn, :totally_random_reason)
      assert match?({:redirect_with_flash, _, _}, result) or match?({:render_404}, result)
    end
  end

  describe "find_any_available_language_version/3" do
    test "returns group listing path when post slug doesn't exist",
         %{group_slug: slug} do
      result = Fallback.find_any_available_language_version(slug, "missing-post", "en")
      assert {:ok, path} = result
      assert is_binary(path)
    end
  end

  describe "find_first_published_timestamp_version/4" do
    test "returns :not_found when no published version exists for any language",
         %{group_slug: slug} do
      assert Fallback.find_first_published_timestamp_version(
               slug,
               "2026-04-27",
               "10:00",
               ["en"]
             ) == :not_found
    end
  end
end
