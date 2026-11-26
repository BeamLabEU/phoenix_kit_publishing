defmodule PhoenixKit.Modules.Publishing.Web.Controller.AccessUrlShapesTest do
  @moduledoc """
  URL shapes that must not count a protected post: the timestamp form
  (date-only vs date+time) and the language-segment detection.

  A timestamp post's URL is date-only when it is the only post of its date.
  Counted with a protected sibling, the public post's URL gained a time
  segment (and the date-only URL redirected to the first time, possibly the
  protected post's), telling every reader a hidden post shares the date.
  Public posts are counted alone now; a protected post's own URL always
  carries its time.
  """

  use PhoenixKitPublishing.ConnCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.PostAccess
  alias PhoenixKit.Modules.Publishing.PostAccess.Viewer
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.Versions
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_boolean_setting("publishing_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_public_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("publishing_feeds_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("languages_enabled", false)
    {:ok, _} = Settings.update_setting("content_language", "en")
    {:ok, _} = Settings.update_setting("publishing_access_forbidden_status", "404")

    {:ok, group} =
      Groups.add_group("shapes-#{System.unique_integer([:positive])}", mode: "timestamp")

    slug = group["slug"]
    {:ok, _} = Groups.update_group(slug, %{"search_enabled" => "true"})
    date = Date.add(Date.utc_today(), -3)

    %{slug: slug, group: group, date: date, day: Date.to_iso8601(date)}
  end

  defp post_at(slug, date, title, hour, minute) do
    {:ok, post} = Posts.create_post(slug, %{title: title, content: "Body of #{title}."})
    repo = PhoenixKit.RepoHelper.repo()

    repo.get_by(PublishingPost, uuid: post[:uuid])
    |> Ecto.Changeset.change(post_date: date, post_time: Time.new!(hour, minute, 0))
    |> repo.update!()

    :ok = Versions.publish_version(slug, post[:uuid], 1)
    post
  end

  describe "a public post sharing its date with a protected one" do
    setup %{slug: slug, date: date} do
      # The protected post is the FIRST time of the date.
      hidden = post_at(slug, date, "Hidden memo", 9, 5)
      public = post_at(slug, date, "Open notes", 9, 20)
      {:ok, _} = PostAccess.add_rule({:post, hidden[:uuid]}, %{"kind" => "signed_in"})
      %{hidden: hidden, public: public}
    end

    test "its links are date-only, as if it were alone", %{conn: conn, slug: slug, day: day} do
      for path <- ["/#{slug}", "/#{slug}?q=notes", "/#{slug}/feed.xml"] do
        body = conn |> get(path) |> response(200)
        assert body =~ "/#{slug}/#{day}\"" or body =~ "/#{slug}/#{day}<", "#{path}: #{body}"
        refute body =~ "#{day}/09:", "#{path} gave the public post a time segment"
      end
    end

    test "its date-only URL opens it, never the protected post", %{
      conn: conn,
      slug: slug,
      day: day
    } do
      conn = get(conn, "/#{slug}/#{day}")
      body = html_response(conn, 200)
      assert body =~ "Open notes"
      refute body =~ "Hidden memo"
    end

    test "Posts.count_posts_on_date/2 counts the public post only", %{slug: slug, date: date} do
      assert Publishing.count_posts_on_date(slug, date) == 1
      assert Publishing.list_public_times_on_date(slug, date) == ["09:20"]
    end

    test "the protected post's own URL keeps its time", %{
      slug: slug,
      hidden: hidden,
      day: day
    } do
      {:ok, read} = Publishing.read_post_by_uuid(hidden[:uuid], "en", 1)
      url = Publishing.Web.HTML.build_post_url(slug, read, "en")
      assert url =~ "/#{slug}/#{day}/09:05"

      cached = %{read | uuid: hidden[:uuid]} |> Map.put(:access_protected, true)
      assert Publishing.Web.HTML.build_post_url(slug, cached, "en", %{day => 1}) =~ "/09:05"
    end
  end

  describe "a date whose only post is protected" do
    test "behind a password, the date-only URL still reaches the password form", %{
      conn: conn,
      slug: slug,
      date: date,
      day: day
    } do
      post = post_at(slug, date, "Board minutes", 11, 0)
      {:ok, _} = PostAccess.set_password({:post, post[:uuid]}, "minutes pw")

      conn = get(conn, "/#{slug}/#{day}")
      assert response(conn, 401) =~ "pk-access-password"
    end

    test "behind a secret link, the date answers exactly as an empty date", %{
      conn: conn,
      slug: slug,
      date: date,
      day: day
    } do
      empty = get(conn, "/#{slug}/#{Date.to_iso8601(Date.add(date, -1))}")
      post = post_at(slug, date, "Board minutes", 11, 0)
      {:ok, _, _} = PostAccess.create_link({:post, post[:uuid]})

      hidden = get(conn, "/#{slug}/#{day}")
      assert hidden.status == empty.status
      assert redirected_to(hidden) == redirected_to(empty)
      assert get_resp_header(hidden, "x-robots-tag") == []
    end
  end

  describe "the language segment" do
    test "a language only a protected post has is no language to a stranger", %{
      slug: slug,
      date: date
    } do
      post = post_at(slug, date, "Only post", 8, 0)
      assert Language.has_content_for_language?(slug, "en", nil)

      {:ok, _} = PostAccess.add_rule({:post, post[:uuid]}, %{"kind" => "signed_in"})

      refute Language.has_content_for_language?(slug, "en", nil)
      refute Language.has_content_for_language?(slug, "en", Viewer.anonymous())

      reader = %Viewer{user_uuid: "019cce93-0000-7000-8000-0000000000dd", anonymous?: false}
      assert Language.has_content_for_language?(slug, "en", reader)
    end
  end
end
