defmodule ElixirMixir.Runtime.DurableReplacement do
  @moduledoc "Commits implementation selection and compatible or migrated state in one prepared durable transition."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.DurableOperations
  alias ElixirMixir.Runtime.DurableTransitions
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.Values
  alias ElixirMixir.Runtime.Workers

  @doc "Validates replacement shape and a positive expected worker revision before admission."
  @spec validate(map()) :: :ok | {:error, Error.t()}
  def validate(args) do
    valid =
      Enum.sort(Map.keys(args)) == ~w(artifact_id expected_revision request_id worker_id) and
        Values.valid_id?(args["worker_id"]) and is_binary(args["artifact_id"]) and
        is_integer(args["expected_revision"]) and args["expected_revision"] > 0

    if valid, do: :ok, else: {:error, Error.new("INVALID_ARGUMENT")}
  end

  @doc "Prepares bounded migration, commits its selection/state/outcome, then publishes in the original host."
  @spec execute(map(), map()) :: {{:ok | :error, map()}, map()}
  def execute(args, state) do
    DurableOperations.execute("replace", args, state, fn records, entry ->
      with {:ok, worker} <- Workers.find(state.workers, args["worker_id"]),
           :ok <- running(worker),
           :ok <- retained(records, args["artifact_id"]),
           {:ok, artifact} <- ArtifactRegistry.fetch(args["artifact_id"]) do
        prepare(args, worker, artifact, entry, state)
      end
    end)
  end

  defp prepare(args, worker, artifact, entry, state) do
    candidate = Map.take(artifact, [:id, :module, :revision, :state_schema])

    context = %{
      request_id: args["request_id"],
      operation_id: entry["operation_id"],
      generation: state.generation + 1
    }

    with {:ok, data, ticket} <-
           ProcessHost.prepare_replace(
             worker.pid,
             candidate,
             args["expected_revision"],
             context,
             state.limits.operation_timeout_ms
           ) do
      DurableTransitions.prepared_change(args, worker, entry, data, ticket, state)
    end
  end

  defp retained(records, id) do
    if Map.has_key?(records, {:artifact, id}),
      do: :ok,
      else: {:error, Error.new("ARTIFACT_NOT_FOUND")}
  end

  defp running(%{status: "running"}), do: :ok
  defp running(_worker), do: {:error, Error.new("WORKER_NOT_RUNNING")}
end
