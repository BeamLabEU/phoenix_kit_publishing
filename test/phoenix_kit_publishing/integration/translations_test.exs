defmodule PhoenixKit.Integration.Publishing.TranslationsTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.TranslationManager
  alias PhoenixKit.Modules.Publishing.Versions

  defp unique_name, do: "i18n Group #{System.unique_integer([:positive])}"

  defp create_group_and_post(opts \\ []) do
    title = Keyword.get(opts, :title, "Translatable")
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    {:ok, post} = Posts.create_post(group["slug"], %{title: title})
    {group, post}
  end

  # ============================================================================
  # add_language_to_post/4
  # ============================================================================

  describe "add_language_to_post/4" do
    test "adds a new language to post" do
      {group, post} = create_group_and_post()

      assert {:ok, updated} =
               TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de", nil)

      assert is_map(updated)
    end

    test "added language appears in available_languages" do
      {group, post} = create_group_and_post()
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "fr", nil)

      {:ok, post_map} = Posts.read_post(group["slug"], post[:uuid], nil, nil)
      assert "fr" in post_map[:available_languages]
    end

    test "adding primary language is idempotent" do
      {group, post} = create_group_and_post()
      result = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "en", nil)
      assert match?({:ok, _}, result)
    end

    test "adds multiple languages" do
      {group, post} = create_group_and_post()
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de", nil)
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "fr", nil)
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "es", nil)

      {:ok, post_map} = Posts.read_post(group["slug"], post[:uuid], nil, nil)
      langs = post_map[:available_languages]

      assert "de" in langs
      assert "fr" in langs
      assert "es" in langs
    end

    test "new language content starts as draft" do
      {group, post} = create_group_and_post()
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de", nil)

      {:ok, post_map} = Posts.read_post(group["slug"], post[:uuid], nil, nil)
      assert post_map[:language_statuses]["de"] == "draft"
    end
  end

  # ============================================================================
  # delete_language/4
  # ============================================================================

  describe "delete_language/4" do
    test "removes a non-primary language" do
      {group, post} = create_group_and_post()
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "fr", nil)

      result = TranslationManager.delete_language(group["slug"], post[:uuid], "fr", nil)
      assert result == :ok or match?({:ok, _}, result)
    end

    test "cannot delete last active language" do
      {group, post} = create_group_and_post()

      result = TranslationManager.delete_language(group["slug"], post[:uuid], "en", nil)
      assert result == {:error, :last_language} or match?({:error, _}, result)
    end

    test "can delete primary if other languages exist" do
      {group, post} = create_group_and_post()
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de", nil)

      # With 2 languages, deleting one should work
      result = TranslationManager.delete_language(group["slug"], post[:uuid], "en", nil)
      assert result == :ok or match?({:ok, _}, result)
    end
  end

  # ============================================================================
  # LanguageHelpers.get_primary_language/0
  # ============================================================================

  describe "get_primary_language/0" do
    test "returns primary language" do
      alias PhoenixKit.Modules.Publishing.LanguageHelpers
      lang = LanguageHelpers.get_primary_language()
      assert is_binary(lang)
      assert lang =~ ~r/^[a-z]{2}/
    end
  end

  # ============================================================================
  # set_translation_status/5
  # ============================================================================

  describe "set_translation_status/5" do
    test "is a no-op — status is now version-level" do
      {group, post} = create_group_and_post()

      # set_translation_status is a no-op since status is version-level.
      # Use Versions.publish_version/3 instead.
      assert :ok =
               TranslationManager.set_translation_status(
                 group["slug"],
                 post[:uuid],
                 1,
                 "en",
                 "published"
               )

      # Even invalid status returns :ok (no-op)
      assert :ok =
               TranslationManager.set_translation_status(
                 group["slug"],
                 post[:uuid],
                 1,
                 "en",
                 "invalid"
               )
    end
  end

  # ============================================================================
  # Full translation workflow
  # ============================================================================

  describe "full multilingual workflow" do
    test "create → add languages → publish version → verify all published" do
      {group, post} = create_group_and_post(title: "Multilingual Post")

      # Add languages
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de", nil)
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "fr", nil)

      # Publish the version — status is version-level, applies to all languages
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      # Verify all languages show as published via language_statuses
      {:ok, post_map} = Posts.read_post(group["slug"], post[:uuid], nil, nil)
      statuses = post_map[:language_statuses]

      assert statuses["en"] == "published"
      assert statuses["de"] == "published"
      assert statuses["fr"] == "published"
    end

    test "version cloning preserves all languages" do
      {group, post} = create_group_and_post(title: "V1 Multilang")
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de", nil)
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "fr", nil)

      # Clone to v2
      {:ok, v2} = Versions.create_new_version(group["slug"], post, %{}, %{})
      assert v2[:version] == 2

      # V2 should have all 3 languages
      {:ok, v2_post} = Posts.read_post(group["slug"], post[:uuid], nil, 2)
      v2_langs = v2_post[:available_languages]

      assert "en" in v2_langs
      assert "de" in v2_langs
      assert "fr" in v2_langs
    end
  end
end
