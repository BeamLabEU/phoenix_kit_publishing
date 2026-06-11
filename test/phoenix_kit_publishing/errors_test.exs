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
      assert Errors.message(:resource_not_found) == "Resource not found"

      assert Errors.message(:reserved_language_code) ==
               "Slug conflicts with a reserved language code"

      assert Errors.message(:reserved_route_word) == "Slug conflicts with a reserved route word"
      assert Errors.message(:slug_already_exists) == "Slug already exists"
      assert Errors.message(:slug_taken) == "Slug taken"

      assert Errors.message(:timestamp_collision_unresolvable) ==
               "Every time slot on this post's date is taken. Change the date or time, then try again."

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

  describe "message/1 — %Ecto.Changeset{}" do
    defp changeset_with(errors) do
      Enum.reduce(errors, Ecto.Changeset.change({%{}, %{title: :string}}), fn
        {field, msg, opts}, acc -> Ecto.Changeset.add_error(acc, field, msg, opts)
        {field, msg}, acc -> Ecto.Changeset.add_error(acc, field, msg)
      end)
    end

    test "humanizes a single field error" do
      assert Errors.message(changeset_with([{:title, "can't be blank"}])) ==
               "Title can't be blank"
    end

    test "strips the internal *_uuid suffix from field names" do
      msg = Errors.message(changeset_with([{:active_version_uuid, "is invalid"}]))
      assert msg == "Active version is invalid"
      refute msg =~ "uuid"
    end

    test "keeps acronyms uppercased instead of lowercasing them" do
      # String.capitalize/1 would render these as "Url slug" / "Seo title".
      assert Errors.message(changeset_with([{:url_slug, "is invalid"}])) ==
               "URL slug is invalid"

      assert Errors.message(changeset_with([{:seo_title, "is invalid"}])) ==
               "SEO title is invalid"
    end

    test "interpolates %{...} placeholders from error opts" do
      msg =
        Errors.message(
          changeset_with([{:title, "should be at most %{count} character(s)", [count: 5]}])
        )

      assert msg == "Title should be at most 5 character(s)"
    end

    test "caps the summary at two field errors" do
      msg =
        Errors.message(
          changeset_with([
            {:title, "can't be blank"},
            {:slug, "is invalid"},
            {:mode, "is invalid"}
          ])
        )

      # Two errors joined by "; ", the third dropped so a flash can't be flooded.
      assert length(String.split(msg, "; ")) == 2
    end

    test "never renders the inspected struct" do
      refute Errors.message(changeset_with([{:title, "can't be blank"}])) =~ "Ecto.Changeset"
    end

    test "does not crash on error opts whose value has no String.Chars impl" do
      # to_string({:array, :string}) would raise Protocol.UndefinedError;
      # the formatter must fall back to inspect rather than crash the flash.
      msg = Errors.message(changeset_with([{:title, "is invalid", [type: {:array, :string}]}]))

      assert is_binary(msg)
      assert msg =~ "Title is invalid"
    end

    test "does not crash on list-valued error opts" do
      # to_string([:draft, :published]) raises ArgumentError (not
      # Protocol.UndefinedError) — common for inclusion/subset validations.
      # The formatter must fall back to inspect rather than crash the flash.
      msg =
        Errors.message(
          changeset_with([
            {:status, "must be one of %{allowed}", [allowed: [:draft, :published]]}
          ])
        )

      assert is_binary(msg)
      assert msg =~ "Status must be one of"
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

    test "clips multibyte UTF-8 input on a codepoint boundary" do
      # "日" is 3 bytes in UTF-8. With max=4 we'd land mid-sequence on a
      # naive byte slice; the clip must walk back to the previous
      # boundary so the prefix is always valid UTF-8.
      input = String.duplicate("日", 10)
      result = Errors.truncate_for_log(input, 4)

      [head | _] = String.split(result, "…")
      assert String.valid?(head)
      assert head == "日"
      assert result =~ "(truncated, #{byte_size(input)} bytes)"
    end
  end
end
