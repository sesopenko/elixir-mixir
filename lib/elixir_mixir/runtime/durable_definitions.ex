defmodule ElixirMixir.Runtime.DurableDefinitions do
  @moduledoc "Prepares durable source definitions without publishing them ahead of their committed outcome."
  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.Definition
  alias ElixirMixir.Runtime.DurableArtifacts
  alias ElixirMixir.Runtime.DurableOperations
  alias ElixirMixir.Runtime.Error

  @doc "Defines or exactly replays an inactive durable artifact."
  @spec execute(map(), map()) :: {{:ok | :error, map()}, map()}
  def execute(args, state) do
    DurableOperations.execute("define", args, state, fn records, _entry ->
      count = Enum.count(records, fn {key, _} -> match?({:artifact, _}, key) end)

      if count < state.limits.artifact_slots do
        prepare(args, state)
      else
        {:error, Error.new("LIMIT_EXCEEDED")}
      end
    end)
  end

  defp prepare(args, state) do
    with {:ok, data, reservation, artifact} <-
           Definition.prepare(args, state.generation + 1, state.limits) do
      {:ok,
       %{
         data: data,
         puts: %{{:artifact, artifact.id} => DurableArtifacts.record(artifact)},
         deletes: [],
         changed: true,
         abort: fn -> :ok end,
         publish: fn state ->
           :ok = ArtifactRegistry.register(reservation, artifact)
           state
         end
       }}
    end
  end
end
