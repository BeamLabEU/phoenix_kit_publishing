defmodule PhoenixKitPublishing.Test.ApiCase do
  @moduledoc """
  Runs a publishing tool the way core's executor does, minus authentication:
  the input goes through JSON (string keys, as over HTTP), is validated by the
  executor's own `Executor.validate_input/2` (the `max_items` check and the
  closed schema) and only then reaches the handler with a context map built by
  the executor's own `Executor.context_from/1`.

      {:ok, body} = ApiCase.call("publishing.list_posts", %{"group" => uuid})
      {:preview, preview, fingerprint} = ApiCase.call("publishing.trash_posts", input, %{dry_run?: true})

  Context overrides (a map): `:scopes`, `:dry_run?`, `:approved_by_uuid`, anything
  else of the context.

  This is NOT core's `Executor.call/4`: it never authenticates, rate-limits,
  confirms or claims an idempotency key. What only the real executor can show
  (the batch threshold, the dry-run re-run and fingerprint, the scope check, the
  idempotency replay) is covered by `test/phoenix_kit_publishing/api/executor_test.exs`.
  """

  alias PhoenixKit.API.{Actor, Executor}
  alias PhoenixKit.API.MCP.Names
  alias PhoenixKit.Modules.Publishing.API.Tools
  alias PhoenixKit.Modules.Publishing.Posts

  @compile {:no_warn_undefined, [Executor, Names]}

  @user "00000000-0000-7000-8000-000000000009"

  @doc "The user uuid the test actor writes as."
  def user_uuid, do: @user

  @doc "Every scope a publishing tool declares."
  def all_scopes, do: Tools.all() |> Enum.map(& &1.scope) |> Enum.uniq()

  # `name` is the dotted name or, like `tools/call` accepts it, the MCP name
  # (`publishing_list_posts`); core's `MCP.Names.to_mcp/1` is the one definition of the mapping.
  def tool!(name) do
    Enum.find(Tools.all(), &(&1.name == name or mcp_name(&1.name) == name)) ||
      raise ArgumentError, "no publishing tool named #{inspect(name)}"
  end

  @doc "The MCP name of a dotted tool name (core's `MCP.Names.to_mcp/1` when core has it)."
  def mcp_name(dotted) do
    if Code.ensure_loaded?(Names),
      do: Names.to_mcp(dotted),
      else: dotted
  end

  def ctx(overrides \\ %{}) do
    {scopes, overrides} = Map.pop(overrides, :scopes, all_scopes())

    actor = %Actor{
      kind: :key,
      key_uuid: Ecto.UUID.generate(),
      key_prefix: "abcd1234",
      user_uuid: @user,
      scopes: scopes
    }

    Executor.context_from(
      Map.merge(
        %{
          actor: actor,
          scopes: scopes,
          audience: :admin,
          language: "en-US",
          currency: nil,
          hosts: [],
          base_url: "https://shop.test",
          request_id: "req-test",
          dry_run?: false
        },
        overrides
      )
    )
  end

  @doc """
  Traces `Posts.update_post/4` in every process until the test ends. The first call is sent to the
  test process as `{:traced, [group, post, params, opts]}`.
  """
  def trace_update_post! do
    test_pid = self()

    tracer =
      spawn_link(fn ->
        receive do
          {:trace, _pid, :call, {Posts, :update_post, args}} -> send(test_pid, {:traced, args})
        end
      end)

    :erlang.trace_pattern({Posts, :update_post, 4}, true, [:local])
    :erlang.trace(:processes, true, [:call, {:tracer, tracer}])

    ExUnit.Callbacks.on_exit(fn ->
      :erlang.trace(:processes, false, [:call])
      :erlang.trace_pattern({Posts, :update_post, 4}, false, [:local])
    end)

    :ok
  end

  @doc """
  Like `call/3`, with a context that has no `:dry_run?` key at all (a core without the
  confirmation flow never sets it): the handler must treat the call as a real run.
  """
  def call_without_dry_run_key(name, input) do
    tool = tool!(name)
    input = input |> Jason.encode!() |> Jason.decode!()
    {:ok, valid} = Executor.validate_input(tool, input)
    {module, function} = tool.handler
    apply(module, function, [valid, Map.delete(ctx(), :dry_run?)])
  end

  def call(name, input, overrides \\ %{}) do
    tool = tool!(name)
    input = input |> Jason.encode!() |> Jason.decode!()

    case Executor.validate_input(tool, input) do
      {:ok, valid} ->
        {module, function} = tool.handler
        apply(module, function, [valid, ctx(overrides)])

      {:error, errors} ->
        {:error, :validation_failed, "The input does not match the schema of #{tool.name}.",
         %{errors: errors}}
    end
  end
end
