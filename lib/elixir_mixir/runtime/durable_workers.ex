defmodule ElixirMixir.Runtime.DurableWorkers do
  @moduledoc "Converts logical worker definitions and committed JSON checkpoints to fresh, unrouted hosts."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.Values

  @doc "Serializes desired status and lifecycle budget without transient runtime handles."
  @spec record(map()) :: map()
  def record(worker) do
    %{
      "artifact_id" => worker.artifact.id,
      "desired_status" => worker.desired_status,
      "observed_status" => worker.status,
      "config" => worker.config,
      "worker_revision" => worker.worker_revision,
      "restarts" => worker.restarts,
      "request_id" => worker.request_id
    }
  end

  @doc "Builds a versioned committed state checkpoint for an originating operation."
  @spec checkpoint(map(), String.t(), integer()) :: map()
  def checkpoint(worker, operation_id, now) do
    %{
      "schema" => worker.artifact.state_schema,
      "data" => worker.committed_data,
      "state_revision" => worker.state_revision,
      "last_operation_id" => operation_id,
      "checkpoint_at" => now
    }
  end

  @doc "Constructs runtime metadata for a newly initialized logical definition."
  @spec candidate(map(), map(), map()) :: map()
  def candidate(args, artifact, state) do
    previous = state.workers[args["worker_id"]]

    %{
      worker_id: args["worker_id"],
      artifact: Map.take(artifact, [:id, :module, :revision, :state_schema]),
      config: args["config"],
      worker_revision: if(previous, do: previous.worker_revision + 1, else: 1),
      state_revision: if(previous, do: previous.state_revision + 1, else: 1),
      desired_status: "running",
      status: "running",
      restarts: [],
      restart_token: nil,
      restart_timer: nil,
      pid: nil,
      monitor: nil,
      manager: self(),
      limits: state.limits,
      dispatcher: state.dispatcher,
      request_id: args["request_id"],
      committed_data: nil
    }
  end

  @doc "Starts a supervised candidate, optionally injecting validated committed state without callbacks."
  @spec start_candidate(map(), boolean(), map()) :: {:ok, map()} | {:error, Error.t()}
  def start_candidate(worker, restore, state) do
    opts = if restore, do: Map.put(worker, :restore_data, worker.committed_data), else: worker

    starter =
      if restore,
        do: state.restore_host,
        else: fn opts ->
          DynamicSupervisor.start_child(ElixirMixir.Runtime.WorkerSupervisor, {ProcessHost, opts})
        end

    case starter.(opts) do
      {:ok, pid} ->
        case ProcessHost.snapshot(pid) do
          {:ok, snapshot} ->
            {:ok, %{worker | pid: pid, committed_data: snapshot.data}}

          {:error, error} ->
            close(%{worker | pid: pid})
            {:error, error}
        end

      {:error, {:runtime_error, error}} ->
        {:error, error}

      {:error, _reason} ->
        {:error, Error.new("CALLBACK_FAILED")}
    end
  end

  @doc "Publishes a known committed candidate as a logical route; failed publication closes authority."
  @spec activate(map()) :: map()
  def activate(worker) do
    true = Process.alive?(worker.pid)

    {:ok, _} =
      Registry.register(ElixirMixir.Runtime.ProcessRegistry, worker.worker_id, worker.pid)

    %{worker | monitor: Process.monitor(worker.pid)}
  end

  @doc "Terminates an unrouted candidate or previously committed host through its owner."
  @spec close(map()) :: :ok
  def close(%{pid: nil}), do: :ok

  def close(worker) do
    ProcessHost.stop(worker.pid)
    DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, worker.pid)
    :ok
  end

  @doc "Decodes a retained definition, quarantining unavailable references or incompatible checkpoints."
  @spec decode(String.t(), map(), term(), map()) :: map()
  def decode(id, original, checkpoint, state) do
    record = if is_map(original), do: original, else: %{}

    artifact =
      case ArtifactRegistry.fetch(record["artifact_id"]) do
        {:ok, artifact} -> Map.take(artifact, [:id, :module, :revision, :state_schema])
        {:error, _} -> %{id: safe_id(record["artifact_id"]), revision: 0, state_schema: 0}
      end

    data = if is_map(checkpoint), do: checkpoint["data"]
    valid_data = if Values.validate(data, :state, state.limits) == :ok, do: data

    worker = %{
      worker_id: safe_id(id),
      quarantine_reason: nil,
      artifact: artifact,
      config:
        if(Values.validate(record["config"], :config, state.limits) == :ok,
          do: record["config"],
          else: %{}
        ),
      desired_status:
        if(record["desired_status"] in ["running", "stopped"],
          do: record["desired_status"],
          else: nil
        ),
      status: record["observed_status"],
      worker_revision: positive_revision(record["worker_revision"]),
      state_revision:
        if(is_map(checkpoint), do: positive_revision(checkpoint["state_revision"]), else: 0),
      committed_data: valid_data,
      restarts: valid_restarts(record["restarts"]),
      request_id: safe_id(record["request_id"]),
      restart_token: nil,
      restart_timer: nil,
      pid: nil,
      monitor: nil,
      manager: self(),
      limits: state.limits,
      dispatcher: state.dispatcher
    }

    classify(worker, id, record, checkpoint, state.limits)
  end

  defp classify(worker, id, record, checkpoint, limits) do
    cond do
      not valid_record?(id, record, limits) ->
        quarantine(worker, "INVALID_WORKER_RECORD")

      record["desired_status"] == "stopped" ->
        %{worker | status: "stopped"}

      not Map.has_key?(worker.artifact, :module) ->
        quarantine(worker, "ARTIFACT_UNAVAILABLE")

      worker.committed_data == nil ->
        quarantine(worker, "INVALID_STATE")

      not matching_schema?(checkpoint, worker.artifact) ->
        quarantine(worker, "STATE_SCHEMA_MISMATCH")

      not valid_checkpoint?(checkpoint, worker.artifact, limits) ->
        quarantine(worker, "INVALID_CHECKPOINT")

      true ->
        observed(worker)
    end
  end

  defp quarantine(worker, reason),
    do: %{worker | status: "quarantined", quarantine_reason: reason}

  defp safe_id(id), do: if(Values.valid_id?(id), do: id)

  defp observed(%{status: status} = worker) when status in ["failed", "quarantined"], do: worker

  defp observed(%{status: "restarting", restarts: restarts} = worker) when length(restarts) >= 3,
    do: %{worker | status: "failed"}

  defp observed(worker), do: %{worker | status: "running"}

  defp positive_revision(value) when is_integer(value) and value > 0, do: value
  defp positive_revision(_value), do: 0

  defp valid_restarts(values) when is_list(values),
    do: values |> Enum.filter(&is_integer/1) |> Enum.take(3)

  defp valid_restarts(_values), do: []

  defp matching_schema?(checkpoint, artifact),
    do: is_map(checkpoint) and checkpoint["schema"] == artifact.state_schema

  defp valid_checkpoint?(checkpoint, artifact, limits) do
    is_map(checkpoint) and record_value?(checkpoint, limits.state_bytes, limits) and
      checkpoint["schema"] == artifact.state_schema and
      is_integer(checkpoint["state_revision"]) and checkpoint["state_revision"] > 0 and
      Values.valid_id?(checkpoint["last_operation_id"]) and
      is_integer(checkpoint["checkpoint_at"]) and checkpoint["checkpoint_at"] >= 0
  end

  defp record_value?(value, bytes, limits),
    do:
      Values.validate(value, :reply, %{
        limits
        | reply_bytes: bytes + limits.metadata_bytes,
          depth: limits.depth + 4
      }) == :ok

  defp valid_record?(id, record, limits) do
    record_value?(record, limits.config_bytes, limits) and valid_identifiers?(id, record) and
      Values.validate(record["config"], :config, limits) == :ok and
      record["desired_status"] in ["running", "stopped"] and
      record["observed_status"] in ["running", "stopped", "restarting", "failed", "quarantined"] and
      is_integer(record["worker_revision"]) and record["worker_revision"] > 0 and
      valid_budget?(record["restarts"])
  end

  defp valid_identifiers?(id, record),
    do:
      Values.valid_id?(id) and
        Values.valid_id?(record["artifact_id"]) and Values.valid_id?(record["request_id"])

  defp valid_budget?(values) when is_list(values),
    do: length(values) <= 3 and Enum.all?(values, &(is_integer(&1) and &1 >= 0))

  defp valid_budget?(_values), do: false
end
