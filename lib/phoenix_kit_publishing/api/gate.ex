defmodule PhoenixKit.Modules.Publishing.API.Gate do
  @moduledoc false
  # Whether the loaded `phoenix_kit` core can enforce the confirmation flow (previews,
  # confirmation codes, approvals). `PhoenixKit.API.Keys.active?/1` proves the codes exist and
  # `PhoenixKit.API.Flow.gate/1` is the enforcement; both must be exported, so a core between
  # the two still fails closed. Change @markers (the one place) if core moves them.

  @markers [{PhoenixKit.API.Keys, :active?, 1}, {PhoenixKit.API.Flow, :gate, 1}]

  @doc """
  The functions the loaded core must export. `config :phoenix_kit_publishing, :gate_extra_markers`
  can only ADD markers (a test seam that never loosens the gate).
  """
  @spec markers() :: [{module(), atom(), non_neg_integer()}]
  def markers,
    do: @markers ++ Application.get_env(:phoenix_kit_publishing, :gate_extra_markers, [])

  @doc "True when the marker functions of the confirmation flow are exported by the loaded core."
  @spec available?() :: boolean()
  def available?, do: Enum.all?(markers(), &available?/1)

  @doc false
  @spec available?({module(), atom(), non_neg_integer()}) :: boolean()
  def available?({module, function, arity}),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)
end
