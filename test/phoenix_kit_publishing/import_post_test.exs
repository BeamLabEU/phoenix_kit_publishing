defmodule PhoenixKit.Modules.Publishing.ImportPostTest do
  @moduledoc """
  `Publishing.import_post/3` (a post with everything it carries, backdated
  and published, in one call) and the timestamp-slot search it shares with
  `create_post/2`: a taken minute gives way to an earlier one, never to a
  future one where the post would be hidden.
  """

  use PhoenixKitPublishing.DataCase, async: false

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.{Categories, DBStorage, Groups, Posts}
  alias PhoenixKit.Settings

  setup do
    {:ok, _} = Settings.update_setting("time_zone", "0")

    {:ok, group} =
      Groups.add_group("imp-#{System.unique_integer([:positive])}", mode: "timestamp")

    {:ok, cat} = Categories.create_category(group["slug"], %{"name" => "Projects"})
    %{slug: group["slug"], cat: cat}
  end

  test "one call: content, descriptions, og, categories by slug, custom fields, backdated and live",
       %{slug: slug, cat: cat} do
    assert {:ok, post} =
             Publishing.import_post(slug, %{
               title: "PhoenixKit Projects 0.33.0",
               content: "What changed.",
               description: "Projects 0.33.0 notes.",
               og: %{title: "Projects 0.33.0", description: "Short."},
               category_slugs: ["projects"],
               custom_fields: %{"package" => "phoenix_kit_projects", "version" => "0.33.0"},
               published_at: "2026-11-06T01:13:42Z"
             })

    db_post = DBStorage.get_post_by_uuid(post[:uuid])
    assert db_post.post_date == ~D[2026-11-06]
    assert db_post.post_time == ~T[01:13:00]
    assert db_post.active_version_uuid != nil

    version = DBStorage.get_version(post[:uuid], 1)
    assert version.status == "published"
    assert DateTime.compare(version.published_at, ~U[2026-11-06 01:13:42Z]) == :eq
    assert version.data["category_uuids"] == [cat.uuid]
    assert version.data["description"] == "Projects 0.33.0 notes."

    assert version.data["custom_fields"] == %{
             "package" => "phoenix_kit_projects",
             "version" => "0.33.0"
           }

    assert post.metadata.title == "PhoenixKit Projects 0.33.0"
    assert [%{uuid: uuid}] = Publishing.list_posts(slug) |> Enum.filter(&(&1.uuid == post[:uuid]))
    assert uuid == post[:uuid]
  end

  test "posts imported into the same minute get the nearest earlier free minutes", %{slug: slug} do
    at = "2026-11-06T10:05:30Z"

    times =
      for i <- 1..3 do
        {:ok, post} = Publishing.import_post(slug, %{title: "Same minute #{i}", published_at: at})
        DBStorage.get_post_by_uuid(post[:uuid]).post_time
      end

    assert times == [~T[10:05:00], ~T[10:04:00], ~T[10:03:00]]
  end

  test "two posts created now never push each other into the future", %{slug: slug} do
    {:ok, a} = Posts.create_post(slug, %{title: "First"})
    {:ok, b} = Posts.create_post(slug, %{title: "Second"})

    now = NaiveDateTime.utc_now()

    for post <- [a, b] do
      db = DBStorage.get_post_by_uuid(post[:uuid])
      slot = NaiveDateTime.new!(db.post_date, db.post_time)
      assert NaiveDateTime.compare(slot, now) != :gt, "#{db.post_time} is in the future"
    end
  end

  test "refuses before writing: an unknown category, a bad date", %{slug: slug} do
    count = length(Posts.list_raw_posts(slug))

    assert {:error, :category_not_found} =
             Publishing.import_post(slug, %{title: "X", category_slugs: ["nope"]})

    assert {:error, :invalid_published_at} =
             Publishing.import_post(slug, %{title: "X", published_at: "yesterday"})

    for bad <- [
          %{og: 42},
          %{og: %{title: 123}},
          %{category_slugs: "projects"},
          %{custom_fields: "x"},
          %{content: 1}
        ] do
      assert {:error, :invalid_format} = Publishing.import_post(slug, Map.put(bad, :title, "X"))
    end

    assert length(Posts.list_raw_posts(slug)) == count
  end

  test "publish: false leaves a draft", %{slug: slug} do
    {:ok, post} = Publishing.import_post(slug, %{title: "Draft"}, publish: false)
    assert DBStorage.get_post_by_uuid(post[:uuid]).active_version_uuid == nil
  end

  test "input that cannot be stored or published is refused before a post exists", %{slug: slug} do
    count = fn -> length(Posts.list_raw_posts(slug)) end
    before = count.()

    # publishing needs a title
    assert {:error, :title_required} = Publishing.import_post(slug, %{content: "Body."})
    assert {:error, :title_required} = Publishing.import_post(slug, %{title: "  ", content: "B"})

    # Postgres refuses a NUL byte, JSON invalid UTF-8
    for bad <- [
          %{title: "T\0"},
          %{title: "T", description: "a\0b"},
          %{title: "T", seo_title: <<0xFF, 0xFE>>},
          %{title: "T", og: %{title: "a\0b"}}
        ] do
      assert {:error, :invalid_format} = Publishing.import_post(slug, Map.put(bad, :content, "B"))
    end

    assert count.() == before

    # a draft needs no title
    assert {:ok, _} = Publishing.import_post(slug, %{content: "Body."}, publish: false)
  end

  test "a taken minute just after midnight does not move the post to the day before", %{
    slug: slug
  } do
    dates =
      for at <- ["2026-03-02T00:00:10Z", "2026-03-02T00:00:20Z"] do
        {:ok, post} = Publishing.import_post(slug, %{title: "Midnight", published_at: at})
        db_post = DBStorage.get_post_by_uuid(post[:uuid])
        {db_post.post_date, db_post.post_time}
      end

    assert dates == [{~D[2026-03-02], ~T[00:00:00]}, {~D[2026-03-02], ~T[00:01:00]}]
  end
end
