defmodule PhoenixKitPublishing.CorePinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit` requirement against being re-narrowed to a single
  core MINOR, and against a local path override reaching a commit.

  The trap is the three-segment form: `~> 3.5.x` expands to
  `>= 3.5.x and < 3.6.0`, so no 3.6 or later core satisfies it. The breakage
  lands on CONSUMERS, never here — a host depending on both this module and a
  newer core minor gets an unsolvable dependency set and `mix deps.get` fails
  outright, with no degraded mode. Nothing else in this repo's own test run
  would notice, which is why the check is a test rather than a convention.

  The requirement is `>= 3.5.0 and < 4.0.0`. The floor is the ecosystem-wide
  minimum core, and it carries every core API this module is compiled against
  or relies on the behaviour of: the machine API (`PhoenixKit.API`), the group
  media folders' `Storage.ResourceFolders` and `ResourceSource`, `TreePicker`,
  `PhoenixKitWeb.Actor`, `Activity.log/3`, `mount_multilang(open_on:)`, the
  IANA-aware `Utils.Date`, `Utils.Slug.put_slug/3` and the `file_references/0`
  and `expected_schema/0` callbacks. Raise it alongside `mix.exs` whenever a
  newly-adopted core API — or a newly-relied-on core BEHAVIOUR — sets a higher
  one, keeping the compound form: patch-precise at the bottom, open through
  every later 3.x minor at the top.
  """

  # Everything from the floor up to the next major must stay admitted — the
  # open-ceiling invariant this test exists for. Move both lists together.
  @must_admit ["3.5.0", "3.5.1", "3.6.0", "3.9.9"]
  @must_reject ["1.7.236", "2.0.0", "2.65.0", "2.99.4", "3.0.0", "3.4.0", "3.4.9", "4.0.0"]

  test "the :phoenix_kit requirement admits every core >= 3.5.0 minor and nothing else" do
    requirement = core_requirement()

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit` requirement #{inspect(requirement)} is not a valid requirement"

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} rejects core #{version}. " <>
               "A pin that excludes a core minor at or above the floor breaks `mix deps.get` " <>
               "for every host running this module alongside that core. Keep the floor " <>
               "patch-precise and the ceiling open (`>= 3.5.0 and < 4.0.0`)."
    end

    for version <- @must_reject do
      refute Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} admits core #{version}, " <>
               "which is outside the range this module is verified against."
    end
  end

  # Resolution order matters. `Mix.Project.config()` is exact, but it reports the
  # dep as it resolved THIS run — and `pk_dep/3` rewrites it to a `path:` tuple
  # whenever PHOENIX_KIT_PATH is exported, which is the workspace's sanctioned way
  # to run this suite against unreleased core. Reading the committed literal from
  # mix.exs as a fallback keeps the check meaningful under that override instead
  # of failing the documented workflow — and it still fails when a path dep is
  # COMMITTED, because then there is no literal left to find.
  defp core_requirement do
    resolved_requirement() || committed_requirement() ||
      flunk("""
      No version requirement found for `:phoenix_kit`.

      Neither the resolved dep nor mix.exs carries one, which means a `path:`
      dep has been committed. That ships a broken package and breaks every
      other consumer's build — restore the published requirement.
      """)
  end

  defp resolved_requirement do
    Mix.Project.config()
    |> Keyword.get(:deps, [])
    |> Enum.find_value(fn
      {:phoenix_kit, requirement} when is_binary(requirement) -> requirement
      {:phoenix_kit, requirement, _opts} when is_binary(requirement) -> requirement
      _ -> nil
    end)
  end

  # First match wins, matching how every other tool in the workspace reads this
  # pin. Covers both the bare `{:phoenix_kit, "..."}` and the `pk_dep(:phoenix_kit,
  # "...")` forms, since the captured text is identical in each.
  defp committed_requirement do
    case Regex.run(~r/:phoenix_kit,\s*"([^"]+)"/, File.read!("mix.exs")) do
      [_full, requirement] -> requirement
      _ -> nil
    end
  end
end
