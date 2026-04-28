defmodule PhoenixKit.Modules.Publishing.ErrorsTest do
  @moduledoc """
  Per-atom tests for `PhoenixKit.Modules.Publishing.Errors.message/1`.

  Each clause of `message/1` returns a translated string via gettext. The
  test pattern asserts the exact English fallback so a typo in any
  message regresses immediately, AND the gettext wrapping itself is
  exercised — without these tests a `gettext("Foo")` typo would only
  surface when the locale is changed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Errors

  describe "message/1 — plain atoms" do
    test "all known atoms render to the documented strings" do
      assert Errors.message(:already_exists) == "Already exists"
      assert Errors.message(:cache_miss) == "Cache miss"
      assert Errors.message(:cannot_delete_live) == "Cannot delete the live version"
      assert Errors.message(:conflicts_with_post_slug) == "URL slug conflicts with another post"
      assert Errors.message(:db_update_failed) == "Database update failed"
      assert Errors.message(:destination_exists) == "Destination already exists"
      assert Errors.message(:group_not_found) == "Group not found"
      assert Errors.message(:invalid_content) == "Invalid content"
      assert Errors.message(:invalid_format) == "Invalid format"
      assert Errors.message(:invalid_mode) == "Invalid mode"
      assert Errors.message(:invalid_name) == "Invalid name"
      assert Errors.message(:invalid_path) == "Invalid path"
      assert Errors.message(:invalid_slug) == "Invalid slug"
      assert Errors.message(:invalid_status) == "Invalid status"
      assert Errors.message(:invalid_type) == "Invalid type"
      assert Errors.message(:invalid_version) == "Invalid version"
      assert Errors.message(:last_language) == "Cannot delete the last language"
      assert Errors.message(:last_version) == "Cannot delete the last version"
      assert Errors.message(:no_post) == "No post"
      assert Errors.message(:no_published_version) == "No published version"
      assert Errors.message(:no_uuid) == "No UUID"
      assert Errors.message(:not_found) == "Not found"
      assert Errors.message(:not_published) == "Not published"
      assert Errors.message(:post_not_found) == "Post not found"
      assert Errors.message(:post_trashed) == "Post is trashed"

      assert Errors.message(:reserved_language_code) ==
               "Slug conflicts with a reserved language code"

      assert Errors.message(:reserved_route_word) == "Slug conflicts with a reserved route word"
      assert Errors.message(:slug_already_exists) == "Slug already exists"
      assert Errors.message(:slug_taken) == "Slug taken"
      assert Errors.message(:title_required) == "Title is required to publish"
      assert Errors.message(:unpublished) == "Unpublished"
      assert Errors.message(:version_access_disabled) == "Version access is disabled"

      assert Errors.message(:ai_disabled) == "AI module is not enabled"
      assert Errors.message(:ai_no_prompt) == "No AI prompt selected"
      assert Errors.message(:ai_endpoint_not_found) == "AI endpoint not found"
      assert Errors.message(:ai_endpoint_disabled) == "AI endpoint is disabled"
    end
  end

  describe "message/1 — tagged tuples" do
    test "{:ai_translation_failed, reason} interpolates the reason" do
      assert Errors.message({:ai_translation_failed, :timeout}) ==
               "AI translation failed: :timeout"
    end

    test "{:ai_extract_failed, reason} interpolates the reason" do
      assert Errors.message({:ai_extract_failed, "no content"}) ==
               "Failed to extract AI response: no content"
    end

    test "{:ai_request_failed, reason} interpolates the reason" do
      assert Errors.message({:ai_request_failed, %{status: 503}}) ==
               "AI request failed: %{status: 503}"
    end

    test "{:source_post_read_failed, reason} interpolates the reason" do
      assert Errors.message({:source_post_read_failed, :not_found}) ==
               "Failed to read source post: :not_found"
    end

    test "tagged tuple with very long reason gets truncated" do
      long = String.duplicate("x", 1000)
      msg = Errors.message({:ai_translation_failed, long})

      assert String.starts_with?(msg, "AI translation failed: ")
      # truncate_for_log clips at 500 chars and appends "(truncated, …)"
      assert msg =~ "(truncated,"
      assert byte_size(msg) < 700
    end
  end

  describe "message/1 — fallbacks" do
    test "binary string passes through unchanged" do
      assert Errors.message("Custom legacy message") == "Custom legacy message"
    end

    test "unknown reason renders via the catch-all" do
      assert Errors.message({:unknown, :shape}) == "Unexpected error: {:unknown, :shape}"
    end

    test "nil renders via the catch-all" do
      assert Errors.message(nil) == "Unexpected error: nil"
    end
  end

  describe "truncate_for_log/2" do
    test "leaves a short string unchanged" do
      assert Errors.truncate_for_log("short") == "short"
      assert Errors.truncate_for_log(:short) == ":short"
      assert Errors.truncate_for_log({:tagged, "value"}) == "{:tagged, \"value\"}"
    end

    test "clips a long string at the default 500-char budget" do
      long = String.duplicate("a", 700)
      result = Errors.truncate_for_log(long)

      assert String.starts_with?(result, String.duplicate("a", 500))
      assert result =~ "(truncated, 700 bytes)"
      assert String.contains?(result, "…")
    end

    test "respects a custom max" do
      result = Errors.truncate_for_log("hello world", 5)
      assert result =~ ~r/^hello/
      assert result =~ "(truncated, 11 bytes)"
    end

    test "inspects non-binary terms before clipping" do
      huge_map = Map.new(1..100, fn n -> {"key_#{n}", String.duplicate("v", 20)} end)
      result = Errors.truncate_for_log(huge_map)

      assert String.contains?(result, "(truncated,")
      assert byte_size(result) < 700
    end
  end
end
