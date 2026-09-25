defmodule PhoenixKitPublishing.CorePinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit` requirement against being re-narrowed to a single
  core MINOR, and against a local path override reaching a commit.

  The trap is the three-segment form: `~> 2.4.x` expands to
  `>= 2.4.x and < 2.5.0`, so no 2.5 or later core satisfies it. The breakage
  lands on CONSUMERS, never here — a host depending on both this module and a
  newer core minor gets an unsolvable dependency set and `mix deps.get` fails
  outright, with no degraded mode. Nothing else in this repo's own test run
  would notice, which is why the check is a test rather than a convention.

  What this does NOT forbid is raising the FLOOR. `>= 2.38.0 and < 3.0.0`
  still admits every later 2.x, and the floor has to track the oldest core
  that has every function this module calls, BEHAVING as this module needs it
  to. The earlier floors' reasons, all subsumed now:

    * `PublishingGroup.changeset/2` calls `PhoenixKit.Utils.Slug.put_slug/3`,
      added in core 2.4.0 — the original floor, and the loud kind of gap: a
      floor left at 2.0 lets `mix deps.get` resolve a core without the
      function and moves the failure to an `UndefinedFunctionError` on the
      host's first group create.
    * `Constants.to_site_wall/2` and `from_site_wall/3` reach
      `Utils.Date.shift_to_offset/2` and `parse_datetime_local/2`, which only
      became IANA-aware in core 2.13.9 — the SILENT kind. Both functions exist
      on an older core and both compile; they just read `Europe/Tallinn` as
      offset `0`, so every timestamp post is stamped, released and syndicated
      on UTC with no error anywhere. A present-but-wrong function is why this
      floor is about behaviour, not just arity.

  The floor is 2.38.0 now: the category parent pickers are core's
  `TreePicker`, the actor and activity log come from `PhoenixKitWeb.Actor` and
  `Activity.log/3`, and the edit forms use `mount_multilang(open_on:)` — an
  older core does not compile the package. Raise this alongside `mix.exs`
  whenever a newly-adopted core API — or a newly-relied-on core BEHAVIOUR —
  sets a higher one, keeping the compound form: patch-precise at the bottom,
  open through every later 2.x minor at the top.

  Core 1.7 is deliberately excluded: core 2.0.0 squashed the migration chain to
  a V135 floor and this module is verified only against that baseline.
  """

  # Floor: core 2.38.0 (`TreePicker`, `PhoenixKitWeb.Actor`, `Activity.log/3`,
  # `mount_multilang(open_on:)`; the earlier 2.14 floor for the IANA-aware
  # `Utils.Date` is subsumed). Everything above it, forever, must stay
  # admitted — the open-ceiling invariant this test exists for; the compound
  # form keeps the floor patch-precise. Move both lists together.
  @must_admit ["2.38.0", "2.38.1", "2.39.0", "2.99.4"]
  @must_reject ["1.7.236", "2.0.0", "2.13.9", "2.14.0", "2.37.5", "3.0.0"]

  test "the :phoenix_kit requirement admits every core >= 2.38.0 minor and nothing else" do
    requirement = core_requirement()

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit` requirement #{inspect(requirement)} is not a valid requirement"

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} rejects core #{version}. " <>
               "A pin that excludes a core minor at or above the floor breaks `mix deps.get` " <>
               "for every host running this module alongside that core. Keep the floor " <>
               "patch-precise and the ceiling open (`>= 2.38.0 and < 3.0.0`)."
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
