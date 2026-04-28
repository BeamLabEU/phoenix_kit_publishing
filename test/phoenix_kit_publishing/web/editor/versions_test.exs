defmodule PhoenixKit.Modules.Publishing.Web.Editor.VersionsTest do
  @moduledoc """
  Direct unit tests for the Versions submodule's pure helpers.
  Functions that touch the DB or Presence are exercised through the
  Editor LV smoke tests (`editor_live_test.exs`); this file pins the
  branchless / no-dependency entries.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Editor.Versions

  describe "viewing_older_version?/3" do
    test "always returns false (variant-versioning model)" do
      refute Versions.viewing_older_version?(1, [1, 2, 3], "en")
      refute Versions.viewing_older_version?(2, [1, 2, 3], "fr")
      refute Versions.viewing_older_version?(99, [], "en")
    end
  end
end
