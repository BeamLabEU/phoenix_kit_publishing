defmodule PhoenixKit.Modules.Publishing.Web.Controller.FallbackTest do
  @moduledoc """
  Direct tests for `Fallback.handle_not_found/2` — drives different
  reason atoms through the dispatcher with a constructed Plug.Conn.
  Each `reason` atom routes to a different `handle_fallback_case/3`
  branch in the private dispatcher.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.Versions
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

      assert {:redirect_with_flash, path, _msg} =
               Fallback.handle_not_found(conn, :not_found)

      assert path =~ "/" <> slug
    end

    test "renders 404 when group doesn't exist (never redirects to an unrelated group)" do
      conn = fake_conn(%{"group" => "definitely-does-not-exist-#{System.unique_integer()}"})

      # Even if other groups exist in the DB, an unknown group must render
      # 404 — redirecting to "the first group" would hijack non-publishing
      # paths when url_prefix is "/".
      assert {:render_404} = Fallback.handle_not_found(conn, :group_not_found)
    end

    test "renders 404 when group doesn't exist for :not_found reason" do
      conn = fake_conn(%{"group" => "missing-group-#{System.unique_integer()}"})
      assert {:render_404} = Fallback.handle_not_found(conn, :not_found)
    end

    test "renders 404 when group doesn't exist for catch-all reason" do
      conn = fake_conn(%{"group" => "missing-group-#{System.unique_integer()}"})
      assert {:render_404} = Fallback.handle_not_found(conn, :totally_random_reason)
    end

    test "redirects to group listing for :post_not_found with slug-mode path",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => ["missing-slug"]})

      assert {:redirect_with_flash, path, _msg} =
               Fallback.handle_not_found(conn, :post_not_found)

      assert path =~ "/" <> slug
    end

    test "redirects to group listing for :unpublished reason",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => ["my-post"]})

      assert {:redirect_with_flash, path, _msg} =
               Fallback.handle_not_found(conn, :unpublished)

      assert path =~ "/" <> slug
    end

    test "handles timestamp-mode 3-segment paths",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => ["2026-04-27", "10:00"]})

      assert {:redirect_with_flash, path, _msg} =
               Fallback.handle_not_found(conn, :post_not_found)

      assert path =~ "/" <> slug
    end

    test "handles :version_access_disabled reason",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => ["my-post"]})

      assert {:redirect_with_flash, path, _msg} =
               Fallback.handle_not_found(conn, :version_access_disabled)

      assert path =~ "/" <> slug
    end

    test "catch-all reason with a path falls back to group listing",
         %{group_slug: slug} do
      conn = fake_conn(%{"group" => slug, "path" => ["something"]})

      assert {:redirect_with_flash, path, _msg} =
               Fallback.handle_not_found(conn, :totally_random_reason)

      assert path =~ "/" <> slug
    end

    test "renders 404 (no redirect loop) for :module_disabled even when the group exists",
         %{group_slug: slug} do
      # Regression (H4): disabling the module routes requests here with reason
      # :module_disabled. The group still exists in the DB, so the generic
      # group-listing fallback would 302 to the same disabled URL forever.
      conn = fake_conn(%{"group" => slug, "path" => []})

      assert {:render_404} = Fallback.handle_not_found(conn, :module_disabled)
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

    test "skips a future-dated published post so two languages don't 302-loop (H5)" do
      # Regression: a future-dated post is 404'd as :unpublished by the renderer,
      # but the language fallback only checked status == "published" — so two
      # languages of the same future post would 302-ping-pong forever. The future
      # gate must apply here too.
      {:ok, group} =
        Groups.add_group("FutureTS #{System.unique_integer([:positive])}", mode: "timestamp")

      {:ok, post} = Posts.create_post(group["slug"], %{title: "Future Post"})

      # Move the post into the future, then publish it.
      future = Date.add(Date.utc_today(), 30)
      repo = PhoenixKit.RepoHelper.repo()

      repo.get_by(PublishingPost, uuid: post[:uuid])
      |> Ecto.Changeset.change(post_date: future)
      |> repo.update!()

      [version] = DBStorage.list_versions(post[:uuid])
      :ok = Versions.publish_version(group["slug"], post[:uuid], version.version_number)

      time = post[:time] |> Time.to_string() |> String.slice(0, 5)

      assert Fallback.find_first_published_timestamp_version(
               group["slug"],
               Date.to_iso8601(future),
               time,
               ["en"]
             ) == :not_found
    end
  end

  # A date-only URL with several posts redirects to the first one's time; for
  # embargoed posts that revealed the time before the release.
  describe "a date of embargoed posts" do
    test "its date-only URL does not reveal a post's time", %{conn: conn} do
      {:ok, group} =
        Groups.add_group("Embargo #{System.unique_integer([:positive])}", mode: "timestamp")

      slug = group["slug"]
      future = Date.add(Date.utc_today(), 30)
      repo = PhoenixKit.RepoHelper.repo()

      for {title, minute} <- [{"First", 10}, {"Second", 20}] do
        {:ok, post} = Posts.create_post(slug, %{title: title, content: "Body"})

        repo.get_by(PublishingPost, uuid: post[:uuid])
        |> Ecto.Changeset.change(post_date: future, post_time: Time.new!(9, minute, 0))
        |> repo.update!()

        :ok = Versions.publish_version(slug, post[:uuid], 1)
      end

      conn = get(conn, "/#{slug}/#{Date.to_iso8601(future)}")

      refute conn.status == 200
      if conn.status in [301, 302], do: refute(redirected_to(conn) =~ "09:")
    end
  end

  # A withdrawn post's URL used to walk every version, two queries apiece, once
  # per fallback language. The live read the fallback already made answers it,
  # so the cost no longer grows with the post's history.
  describe "a withdrawn post's fallback" do
    test "costs the same however many versions the post has", %{conn: conn} do
      {:ok, group} =
        Groups.add_group("Withdrawn #{System.unique_integer([:positive])}", mode: "slug")

      slug = group["slug"]
      withdrawn(slug, "short", 1)
      withdrawn(slug, "long", 13)

      short = queries_for(conn, "/#{slug}/short")
      long = queries_for(build_conn(), "/#{slug}/long")

      assert long == short, "#{long} queries for 13 versions, #{short} for one"
    end
  end

  defp withdrawn(group_slug, post_slug, versions) do
    {:ok, post} =
      Posts.create_post(group_slug, %{title: post_slug, slug: post_slug, content: "Body"})

    for n <- 1..(versions - 1)//1,
        do: {:ok, _} = Versions.create_version_from(group_slug, post.uuid, n)

    :ok = Versions.publish_version(group_slug, post.uuid, versions)
    :ok = Versions.unpublish_post(group_slug, post.uuid)
  end

  defp queries_for(conn, path) do
    ref = make_ref()
    parent = self()
    handler = "count-queries-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:phoenix_kit_publishing, :test, :repo, :query],
      fn _event, _measure, _meta, _ -> send(parent, {ref, :query}) end,
      nil
    )

    conn = get(conn, path)
    :telemetry.detach(handler)
    assert conn.status == 302
    count_messages(ref)
  end

  defp count_messages(ref, n \\ 0) do
    receive do
      {^ref, :query} -> count_messages(ref, n + 1)
    after
      0 -> n
    end
  end
end
