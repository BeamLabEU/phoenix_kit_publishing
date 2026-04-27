defmodule PhoenixKit.Modules.Publishing.PostsPathParserTest do
  @moduledoc """
  Pure-function tests for `Posts.extract_slug_version_and_language/2`,
  which parses URL path identifiers into {slug, version, language}.
  No DB needed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Posts

  describe "extract_slug_version_and_language/2" do
    test "returns {\"\", nil, nil} for nil identifier" do
      assert {"", nil, nil} = Posts.extract_slug_version_and_language("blog", nil)
    end

    test "returns {\"\", nil, nil} for empty identifier" do
      assert {"", nil, nil} = Posts.extract_slug_version_and_language("blog", "")
    end

    test "extracts a single slug" do
      assert {"my-post", nil, nil} =
               Posts.extract_slug_version_and_language("blog", "my-post")
    end

    test "extracts slug + language" do
      assert {"my-post", nil, "en"} =
               Posts.extract_slug_version_and_language("blog", "my-post/en")
    end

    test "extracts slug + version + language" do
      assert {"my-post", 1, "en"} =
               Posts.extract_slug_version_and_language("blog", "my-post/v1/en")
    end

    test "drops the group prefix when present" do
      assert {"my-post", 2, "am"} =
               Posts.extract_slug_version_and_language("blog", "blog/my-post/v2/am")
    end

    test "trims leading slash" do
      assert {"my-post", nil, nil} =
               Posts.extract_slug_version_and_language("blog", "/my-post")
    end

    test "extracts version without language" do
      result = Posts.extract_slug_version_and_language("blog", "my-post/v3")
      assert match?({"my-post", 3, _}, result)
    end
  end
end
