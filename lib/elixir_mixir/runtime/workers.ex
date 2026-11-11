defmodule ElixirMixir.Runtime.Workers do
  @moduledoc "Manager-owned worker definitions, bounded startup, explicit stop and lifecycle snapshots."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Values

  @type definitions :: %{String.t() => map()}
  @type mutation :: {:commit, map(), definitions()} | {:noop, map()} | {:error, Error.t()}

  @doc "Starts/reinitializes one definition only after bounded config/init and wire preflight."
  @spec start(map(), definitions(), Limits.t(), non_neg_integer()) :: mutation()
  def start(args, workers, limits, generation) do
    with :ok <- keys(args, ~w(worker_id artifact_id config request_id)),
         true <- Values.valid_id?(args["worker_id"]) and is_binary(args["artifact_id"]),
         :ok <- Values.validate(args["config"], :config, limits),
         :ok <- available(args["worker_id"], workers, limits),
         {:ok, artifact} <- ArtifactRegistry.fetch(args["artifact_id"]) do
      start_host(args, workers, artifact, limits, generation)
    else
      false -> {:error, Error.new("INVALID_ARGUMENT")}
      error -> error
    end
  end

  @doc "Stops a running/failed definition, retaining identity/configuration and monotonic revisions."
  @spec stop(map(), definitions(), Limits.t(), non_neg_integer()) :: mutation()
  def stop(args, workers, limits, generation) do
    with :ok <- keys(args, ~w(worker_id request_id)),
         true <- Values.valid_id?(args["worker_id"]),
         {:ok, worker} <- find(workers, args["worker_id"]) do
      if worker.status == "stopped" do
        {:noop, stopped(worker)}
      else
        stop_host(args, worker, workers, limits, generation)
      end
    else
      false -> {:error, Error.new("INVALID_ARGUMENT")}
      error -> error
    end
  end

  @doc "Invokes one running logical worker and retains its revisions only on an accepted transition."
  @spec invoke(map(), definitions(), Limits.t(), non_neg_integer()) :: mutation()
  def invoke(args, workers, limits, generation) do
    with :ok <- keys(args, ~w(worker_id event request_id)),
         true <- Values.valid_id?(args["worker_id"]),
         :ok <- Values.validate(args["event"], :event, limits),
         {:ok, worker} <- find(workers, args["worker_id"]),
         :ok <- running(worker) do
      invoke_host(args, worker, workers, limits, generation)
    else
      false -> {:error, Error.new("INVALID_ARGUMENT")}
      error -> error
    end
  end

  @doc "Marks a monitored running host failed once; automatic recovery is added in worker-recovery."
  @spec down(definitions(), reference(), term()) :: {definitions(), boolean()}
  def down(workers, ref, reason) do
    case Enum.find(workers, fn {_id, worker} ->
           worker.monitor == ref and worker.status == "running"
         end) do
      nil ->
        {workers, false}

      {id, worker} ->
        worker = %{
          worker
          | status: "failed",
            pid: nil,
            monitor: nil,
            worker_revision: worker.worker_revision + 1
        }

        record("worker_crashed", worker, worker.request_id, %{"reason" => down_reason(reason)})
        {Map.put(workers, id, worker), true}
    end
  end

  @doc "Reads a worker's actual committed state, omitting unavailable state honestly."
  @spec snapshot(map(), String.t(), Limits.t()) :: map()
  def snapshot(%{status: "running"} = worker, detail, limits) do
    base = public(worker)

    case ProcessHost.snapshot(worker.pid, limits.callback_timeout_ms) do
      {:ok, snapshot} -> with_state(base, snapshot, detail)
      {:error, _error} -> Map.merge(base, %{"available" => false, "state_omitted" => true})
    end
  end

  def snapshot(worker, _detail, _limits), do: Map.put(public(worker), "state_omitted", true)

  defp with_state(base, snapshot, "state"), do: Map.put(base, "state", snapshot.data)
  defp with_state(base, _snapshot, _summary), do: base

  @doc "Finds a retained definition by logical ID."
  @spec find(definitions(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def find(workers, id) do
    case Map.fetch(workers, id) do
      {:ok, worker} -> {:ok, worker}
      :error -> {:error, Error.new("WORKER_NOT_FOUND")}
    end
  end

  defp start_host(args, workers, artifact, limits, generation) do
    previous = Map.get(workers, args["worker_id"])
    revision = if previous, do: previous.worker_revision + 1, else: 1
    state_revision = if previous, do: previous.state_revision + 1, else: 1
    artifact = Map.take(artifact, [:id, :module, :revision, :state_schema])

    opts = %{
      worker_id: args["worker_id"],
      artifact: artifact,
      config: args["config"],
      worker_revision: revision,
      state_revision: state_revision,
      limits: limits,
      manager: self()
    }

    case DynamicSupervisor.start_child(ElixirMixir.Runtime.WorkerSupervisor, {ProcessHost, opts}) do
      {:ok, pid} ->
        publish(args, workers, opts, generation, pid)

      {:error, {:runtime_error, error}} ->
        {:error, error}

      {:error, _reason} ->
        {:error, Error.new("CALLBACK_FAILED")}
    end
  end

  defp publish(args, workers, opts, generation, pid) do
    worker =
      Map.merge(opts, %{pid: pid, monitor: nil, status: "running", request_id: args["request_id"]})

    data = public(worker)

    if preflight(data, args["request_id"], generation, opts.limits) do
      worker = %{worker | monitor: Process.monitor(pid)}

      if not Map.has_key?(workers, worker.worker_id),
        do: record("worker_created", worker, args["request_id"], %{})

      record("worker_started", worker, args["request_id"], %{})
      {:commit, data, Map.put(workers, worker.worker_id, worker)}
    else
      DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, pid)
      {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  defp stop_host(args, worker, workers, limits, generation) do
    next = %{
      worker
      | status: "stopped",
        pid: nil,
        monitor: nil,
        worker_revision: worker.worker_revision + 1,
        request_id: args["request_id"]
    }

    data = stopped(next)

    if preflight(data, args["request_id"], generation, limits) do
      if worker.monitor, do: Process.demonitor(worker.monitor, [:flush])

      if worker.pid,
        do: DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, worker.pid)

      record("worker_stopped", next, args["request_id"], %{})
      {:commit, data, Map.put(workers, next.worker_id, next)}
    else
      {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  defp invoke_host(args, worker, workers, limits, generation) do
    record("event_accepted", worker, args["request_id"], %{})
    context = %{generation: generation, request_id: args["request_id"]}

    case ProcessHost.invoke(worker.pid, args["event"], context, limits.operation_timeout_ms) do
      {:ok, data} ->
        worker = %{
          worker
          | worker_revision: data["worker_revision"],
            state_revision: data["state_revision"],
            request_id: args["request_id"]
        }

        record("event_delivered", worker, args["request_id"], %{
          "state_revision" => worker.state_revision
        })

        {:commit, data, Map.put(workers, worker.worker_id, worker)}

      {:error, error} ->
        record("event_failed", worker, args["request_id"], %{"code" => error["code"]})
        {:error, error}
    end
  end

  defp running(%{status: "running"}), do: :ok
  defp running(_worker), do: {:error, Error.new("WORKER_NOT_RUNNING")}

  defp available(id, workers, limits) do
    case Map.get(workers, id) do
      %{status: "running"} -> {:error, Error.new("WORKER_EXISTS")}
      nil when map_size(workers) >= limits.workers -> {:error, Error.new("LIMIT_EXCEEDED")}
      _other -> :ok
    end
  end

  defp public(worker) do
    %{
      "worker_id" => worker.worker_id,
      "artifact_id" => worker.artifact.id,
      "implementation_version" => worker.artifact.revision,
      "pid" => if(worker.pid, do: inspect(worker.pid), else: nil),
      "worker_revision" => worker.worker_revision,
      "state_revision" => worker.state_revision,
      "status" => worker.status
    }
  end

  defp stopped(worker),
    do:
      Map.merge(Map.take(public(worker), ["worker_id", "worker_revision"]), %{
        "status" => "stopped",
        "definition_retained" => true
      })

  defp keys(args, expected) do
    if Enum.sort(Map.keys(args)) == Enum.sort(expected),
      do: :ok,
      else: {:error, Error.new("INVALID_ARGUMENT")}
  end

  defp preflight(data, id, generation, limits),
    do:
      ResponseBudget.fits?(
        Map.merge(data, %{"api_version" => "1", "generation" => generation, "request_id" => id}),
        limits
      )

  defp record(type, worker, request_id, metadata) do
    EventLog.append(%{
      "type" => type,
      "worker_id" => worker.worker_id,
      "logical_id" => worker.worker_id,
      "artifact_revision" => worker.artifact.revision,
      "request_id" => request_id,
      "outcome" => worker.status,
      "metadata" => metadata
    })
  end

  defp down_reason(:killed), do: "killed"
  defp down_reason(:normal), do: "normal"
  defp down_reason(:shutdown), do: "shutdown"
  defp down_reason(_other), do: "abnormal"
end
