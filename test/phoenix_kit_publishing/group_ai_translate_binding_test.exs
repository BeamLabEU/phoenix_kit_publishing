defmodule PhoenixKitPublishing.GroupAITranslateBindingTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKitPublishing.GroupAITranslateBinding, as: Binding

  defp assigns(source), do: %{form: Phoenix.Component.to_form(source, as: :group)}

  describe "existing_translation_langs/2" do
    test "lists only the languages with a non-blank override" do
      source = %{"name_i18n" => %{"fr" => "Blogue", "de" => "  ", "et" => ""}}
      assert Binding.existing_translation_langs("publishing_group", assigns(source)) == ["fr"]
    end

    test "is empty when the form carries no name_i18n map" do
      assert Binding.existing_translation_langs("publishing_group", assigns(%{})) == []

      assert Binding.existing_translation_langs(
               "publishing_group",
               assigns(%{"name_i18n" => nil})
             ) == []
    end
  end

  describe "apply_translation/4" do
    test "puts the translated name under the language, keeping the others" do
      params = %{"name_i18n" => %{"de" => "Blog"}}
      result = Binding.apply_translation("publishing_group", params, "fr", %{"name" => "Blogue"})
      assert result["name_i18n"] == %{"de" => "Blog", "fr" => "Blogue"}
    end

    test "seeds name_i18n when the form had none, or a non-map" do
      for params <- [%{}, %{"name_i18n" => "junk"}] do
        result =
          Binding.apply_translation("publishing_group", params, "fr", %{"name" => "Blogue"})

        assert result["name_i18n"] == %{"fr" => "Blogue"}
      end
    end

    test "trims the name and caps it at the column's length" do
      long = String.duplicate("x", Constants.max_group_name_length() + 20)
      result = Binding.apply_translation("publishing_group", %{}, "fr", %{"name" => "  " <> long})
      assert String.length(result["name_i18n"]["fr"]) == Constants.max_group_name_length()
      refute String.starts_with?(result["name_i18n"]["fr"], " ")
    end

    test "a blank or whitespace-only name leaves the form untouched" do
      params = %{"name_i18n" => %{"fr" => "Existant"}}

      for name <- ["", "   ", "\n"] do
        assert Binding.apply_translation("publishing_group", params, "fr", %{"name" => name}) ==
                 params
      end
    end

    test "fields without a name leave the form untouched" do
      params = %{"name_i18n" => %{}}
      assert Binding.apply_translation("publishing_group", params, "fr", %{}) == params
    end
  end
end
