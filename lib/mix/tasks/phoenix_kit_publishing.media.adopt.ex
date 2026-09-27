defmodule Mix.Tasks.PhoenixKitPublishing.Media.Adopt do
  @moduledoc """
  Files the media that posts already use into their group's media folder
  (`PhoenixKit.Modules.Publishing.MediaAdoption`) — the one-time step after
  the host configures `PhoenixKit.Modules.Publishing.MediaFolders`; safe to
  repeat.

  Dry-run by default — prints the plan and writes nothing. `--apply` finds
  or creates each group's folder and attaches its files: a file with no
  home is adopted, one homed elsewhere is linked and keeps its home.
  Nothing is moved between buckets and no file URL changes.

  ## Usage

      $ mix phoenix_kit_publishing.media.adopt
      $ mix phoenix_kit_publishing.media.adopt --apply

  Folders are created as the first user with the "Owner" role, like
  `mix phoenix_kit.media.reorganize`. Exits `1` when the host has not
  configured the hook, when a configured hook is not callable, or when
  `--apply` could not file something.

  In a release, without Mix: `PhoenixKit.Modules.Publishing.MediaAdoption.run(actor_uuid, apply?: true)`.
  """

  use Mix.Task

  alias PhoenixKit.Modules.Publishing.MediaAdoption
  alias PhoenixKit.Users.Roles

  @shortdoc "File the media posts already use into their group's media folder"

  @switches [apply: :boolean]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} ->
        Mix.Task.run("app.start")
        adopt(Keyword.get(opts, :apply, false))

      {_opts, rest, invalid} ->
        halt_with_error(
          "Invalid arguments: " <>
            Enum.map_join(Enum.map(invalid, &elem(&1, 0)) ++ rest, ", ", &inspect/1)
        )
    end
  end

  defp adopt(apply?) do
    case MediaAdoption.run(first_owner_uuid(), apply?: apply?) do
      {:ok, report} ->
        Mix.shell().info(MediaAdoption.format_report(report))
        if apply? and failures?(report), do: exit({:shutdown, 1}), else: :ok

      {:error, {:bad_hooks, problems}} ->
        halt_with_error(
          "The configured media hooks cannot be called, nothing was planned:\n  " <>
            Enum.join(problems, "\n  ")
        )

      {:error, :not_configured} ->
        halt_with_error("""
        Group media folders are not configured. Add to the host's config:

            config :phoenix_kit_publishing,
              attachments_parent_folder: {PhoenixKit.Modules.Publishing.MediaFolders, :module_folder},
              attachments_folder_name: {PhoenixKit.Modules.Publishing.MediaFolders, :folder_name}
        """)
    end
  end

  defp failures?(%{entries: entries}),
    do: Enum.any?(entries, &match?(%{result: %{failed: [_ | _]}}, &1))

  defp first_owner_uuid do
    case Roles.users_with_role("Owner") do
      [%{uuid: uuid} | _] -> uuid
      _ -> nil
    end
  end

  defp halt_with_error(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
