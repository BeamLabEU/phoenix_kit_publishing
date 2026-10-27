defmodule PhoenixKit.Modules.Publishing.PermissionBackfill do
  @moduledoc """
  One-time grant of a new sub-permission to every role that already holds
  the module's base key, so splitting a right out of `publishing` takes nothing
  away from an existing role.

  Each sub-key has its own settings flag. The flag is written only after
  every grant succeeded; when listing the roles or any grant fails, nothing
  is flagged and the next boot tries again. Once flagged, the pass never runs
  again, so an Owner's later revoke sticks and a role granted the base key
  afterwards gets the narrow meaning.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, RolePermission}

  @doc """
  Grants `sub_key` once to every role holding `base` (the module key, which
  also tags the flag setting), guarded by `flag`. `grant` defaults to `Permissions.grant_permission/3` and is
  replaceable so a test can make a grant fail.
  """
  @spec run(String.t(), String.t(), String.t(), (String.t(), String.t(), nil -> term())) ::
          :ok | {:error, term()}
  def run(base, sub_key, flag, grant \\ &Permissions.grant_permission/3) do
    if Settings.get_setting(flag) == "true" do
      :ok
    else
      with {:ok, role_uuids} <- roles_missing(base, sub_key),
           :ok <- grant_all(role_uuids, sub_key, grant),
           {:ok, _} <- Settings.update_setting_with_module(flag, "true", base) do
        :ok
      else
        error ->
          Logger.warning(
            "[#{base}] backfill of #{sub_key} did not finish, will retry on next boot: " <>
              inspect(error)
          )

          {:error, error}
      end
    end
  end

  # Roles holding the base key but not yet the sub-key. Queried directly
  # rather than through `Permissions.roles_with_permission/1`, which turns a
  # failed query into `[]` — that would look like "nobody to grant" and set
  # the flag over a failure.
  defp roles_missing(base, sub_key) do
    repo = PhoenixKit.RepoHelper.repo()

    holders =
      from(rp in RolePermission, where: rp.module_key == ^base, select: rp.role_uuid)
      |> repo.all()

    already =
      from(rp in RolePermission, where: rp.module_key == ^sub_key, select: rp.role_uuid)
      |> repo.all()

    {:ok, Enum.uniq(holders) -- already}
  rescue
    error -> {:error, error}
  end

  defp grant_all(role_uuids, sub_key, grant) do
    Enum.reduce(role_uuids, :ok, fn role_uuid, acc ->
      case grant.(role_uuid, sub_key, nil) do
        {:ok, _} -> acc
        error -> {:error, {role_uuid, error}}
      end
    end)
  end
end
