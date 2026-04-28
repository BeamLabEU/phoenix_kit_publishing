defmodule PhoenixKit.Modules.Publishing.Web.PostShowTest do
  @moduledoc """
  Unit tests for the per-status `status_label/1` helper added in the
  re-validation sweep. Pins each atom→translated-string clause so a typo
  in the helper or a missing extractor entry would fail.

  Status values are programmatic (DB-backed strings — `"published"`,
  `"draft"`, etc.) so callers used to render them raw. The helper
  routes them through gettext via literal-arg clauses.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.PostShow

  describe "status_label/1" do
    test "returns translated label for 'published'" do
      assert PostShow.status_label("published") == "Published"
    end

    test "returns translated label for 'draft'" do
      assert PostShow.status_label("draft") == "Draft"
    end

    test "returns translated label for 'archived'" do
      assert PostShow.status_label("archived") == "Archived"
    end

    test "returns translated label for 'trashed'" do
      assert PostShow.status_label("trashed") == "Trashed"
    end

    test "passes through unknown binary statuses verbatim" do
      assert PostShow.status_label("custom_status") == "custom_status"
    end

    test "returns empty string for nil" do
      assert PostShow.status_label(nil) == ""
    end

    test "returns empty string for non-binary input" do
      assert PostShow.status_label(123) == ""
      assert PostShow.status_label(:atom) == ""
    end
  end

  describe "version_status_badge_class/1" do
    test "maps published → badge-success" do
      assert PostShow.version_status_badge_class("published") == "badge-success"
    end

    test "maps draft → badge-warning" do
      assert PostShow.version_status_badge_class("draft") == "badge-warning"
    end

    test "maps archived → badge-ghost" do
      assert PostShow.version_status_badge_class("archived") == "badge-ghost"
    end

    test "maps unknown → badge-ghost (catch-all)" do
      assert PostShow.version_status_badge_class("trashed") == "badge-ghost"
    end
  end

  describe "language_status_color/1" do
    test "maps published → bg-success" do
      assert PostShow.language_status_color("published") == "bg-success"
    end

    test "maps draft → bg-warning" do
      assert PostShow.language_status_color("draft") == "bg-warning"
    end

    test "maps archived → bg-base-content/20" do
      assert PostShow.language_status_color("archived") == "bg-base-content/20"
    end

    test "maps unknown → bg-base-content/20 (catch-all)" do
      assert PostShow.language_status_color(nil) == "bg-base-content/20"
    end
  end
end
