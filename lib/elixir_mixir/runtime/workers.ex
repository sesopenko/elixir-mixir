defmodule ElixirMixir.Runtime.Workers do
  @moduledoc "Manager-owned worker definitions, bounded startup, explicit stop and lifecycle snapshots."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Values
  alias ElixirMixir.Runtime.WorkerRecovery

  @type definitions :: %{String.t() => map()}
  @type mutation :: {:commit, map(), definitions()} | {:noop, map()} | {:error, Error.t()}

  @doc "Starts/reinitializes one definition only after bounded config/init and wire preflight."
  @spec start(map(), definitions(), Limits.t(), non_neg_integer(), GenServer.server()) ::
          mutation()
  def start(args, workers, limits, generation, dispatcher \\ EffectDispatcher) do
    with :ok <- keys(args, ~w(worker_id artifact_id config request_id)),
         true <- Values.valid_id?(args["worker_id"]) and is_binary(args["artifact_id"]),
         :ok <- Values.validate(args["config"], :config, limits),
         :ok <- available(args["worker_id"], workers, limits),
         :ok <- retained_definition(args, Map.get(workers, args["worker_id"])),
         {:ok, artifact} <- ArtifactRegistry.fetch(args["artifact_id"]) do
      start_host(args, workers, artifact, limits, generation, dispatcher)
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
  @spec invoke(map(), definitions(), Limits.t(), non_neg_integer(), map()) :: mutation()
  def invoke(args, workers, limits, generation, inherited \\ %{}) do
    with :ok <- keys(args, ~w(worker_id event request_id)),
         true <- Values.valid_id?(args["worker_id"]),
         :ok <- Values.validate(args["event"], :event, limits),
         {:ok, worker} <- find(workers, args["worker_id"]),
         :ok <- running(worker) do
      invoke_host(args, worker, workers, limits, generation, inherited)
    else
      false -> {:error, Error.new("INVALID_ARGUMENT")}
      error -> error
    end
  end

  @doc "Replaces a running implementation only after the same live host confirms the committed candidate."
  @spec replace(map(), definitions(), Limits.t(), non_neg_integer(), map()) :: mutation()
  def replace(args, workers, limits, generation, hooks \\ %{}) do
    with :ok <- keys(args, ~w(worker_id artifact_id expected_revision request_id)),
         true <- Values.valid_id?(args["worker_id"]) and is_binary(args["artifact_id"]),
         true <- is_integer(args["expected_revision"]) and args["expected_revision"] > 0,
         {:ok, worker} <- find(workers, args["worker_id"]),
         :ok <- running(worker),
         {:ok, artifact} <- ArtifactRegistry.fetch(args["artifact_id"]) do
      replace_host(args, worker, workers, artifact, limits, generation, hooks)
    else
      false -> {:error, Error.new("INVALID_ARGUMENT")}
      error -> error
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

  defp start_host(args, workers, artifact, limits, generation, dispatcher) do
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
      dispatcher: dispatcher,
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
      Map.merge(opts, %{
        pid: pid,
        monitor: nil,
        status: "running",
        request_id: args["request_id"],
        restarts: [],
        restart_token: nil,
        restart_timer: nil
      })

    data = public(worker)

    with true <- preflight(data, args["request_id"], generation, opts.limits),
         {:ok, _} <- Registry.register(ElixirMixir.Runtime.ProcessRegistry, worker.worker_id, pid) do
      worker = %{worker | monitor: Process.monitor(pid)}

      if not Map.has_key?(workers, worker.worker_id),
        do: record("worker_created", worker, args["request_id"], %{})

      record("worker_started", worker, args["request_id"], %{})
      {:commit, data, Map.put(workers, worker.worker_id, worker)}
    else
      failure ->
        ProcessHost.stop(pid)
        DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, pid)
        code = if failure == false, do: "LIMIT_EXCEEDED", else: "WORKER_EXISTS"
        {:error, Error.new(code)}
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
      Registry.unregister(ElixirMixir.Runtime.ProcessRegistry, worker.worker_id)
      next = WorkerRecovery.cancel(next)
      EffectDispatcher.cancel_source(worker.dispatcher, worker.worker_id)
      if worker.monitor, do: Process.demonitor(worker.monitor, [:flush])

      if worker.pid do
        ProcessHost.stop(worker.pid)
        DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, worker.pid)
      end

      record("worker_stopped", next, args["request_id"], %{})
      {:commit, data, Map.put(workers, next.worker_id, next)}
    else
      {:error, Error.new("LIMIT_EXCEEDED")}
    end
  end

  defp invoke_host(args, worker, workers, limits, generation, inherited) do
    correlation = Map.get(inherited, :correlation_id, args["request_id"])
    record("event_accepted", worker, correlation, %{"operation_id" => args["request_id"]})

    context =
      Map.merge(
        %{
          generation: generation,
          request_id: args["request_id"],
          correlation_id: args["request_id"],
          source: worker.worker_id,
          artifact_revision: worker.artifact.revision,
          manager: self(),
          path: [],
          remaining_hops: limits.effect_hops
        },
        inherited
      )

    outcome =
      with {:ok, data, ticket} <-
             ProcessHost.prepare_invoke(
               worker.pid,
               args["event"],
               context,
               limits.operation_timeout_ms
             ),
           :ok <- before_publish(inherited),
           {:ok, ^data, token} <- ProcessHost.publish(worker.pid, ticket),
           :ok <- confirm_batch(worker, data, token) do
        {:ok, data}
      end

    case outcome do
      {:ok, data} ->
        worker = %{
          worker
          | worker_revision: data["worker_revision"],
            state_revision: data["state_revision"],
            request_id: correlation
        }

        record("event_delivered", worker, correlation, %{
          "state_revision" => worker.state_revision
        })

        {:commit, data, Map.put(workers, worker.worker_id, worker)}

      {:error, error} ->
        record("event_failed", worker, correlation, %{"code" => error["code"]})
        {:error, error}
    end
  end

  defp replace_host(args, worker, workers, artifact, limits, generation, hooks) do
    candidate = Map.take(artifact, [:id, :module, :revision, :state_schema])
    context = %{generation: generation, request_id: args["request_id"]}

    outcome =
      with {:ok, data, ticket} <-
             ProcessHost.prepare_replace(
               worker.pid,
               candidate,
               args["expected_revision"],
               context,
               limits.operation_timeout_ms
             ),
           :ok <- publish_replacement(worker, ticket, hooks),
           :ok <- confirm_replacement(worker, candidate, data) do
        {:ok, data}
      end

    case outcome do
      {:ok, data} ->
        next = %{
          worker
          | artifact: candidate,
            worker_revision: data["worker_revision"],
            state_revision: data["state_revision"],
            request_id: args["request_id"]
        }

        record("implementation_replaced", next, args["request_id"], %{
          "migration_result" => data["migration_result"],
          "previous_revision" => data["previous_revision"]
        })

        {:commit, data, Map.put(workers, worker.worker_id, next)}

      {:error, error} ->
        type =
          if error["code"] == "MIGRATION_FAILED",
            do: "migration_failed",
            else: "replacement_failed"

        record(type, worker, args["request_id"], %{
          "code" => error["code"],
          "details" => error["details"]
        })

        {:error, error}
    end
  end

  defp before_publish(hooks), do: Map.get(hooks, :before_publish, fn -> :ok end).()

  defp publish_replacement(worker, ticket, hooks) do
    before_publish(hooks)

    case ProcessHost.publish(worker.pid, ticket) do
      {:ok, _data, :none} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp confirm_replacement(worker, candidate, data) do
    with {:ok, snapshot} <- ProcessHost.snapshot(worker.pid),
         true <-
           snapshot.artifact.id == candidate.id and
             snapshot.worker_revision == data["worker_revision"],
         true <- snapshot.state_revision == data["state_revision"] and Process.alive?(worker.pid),
         true <-
           data["pid_before"] == inspect(worker.pid) and data["pid_after"] == inspect(worker.pid) do
      :ok
    else
      _unavailable -> {:error, Error.new("CALLBACK_FAILED")}
    end
  end

  defp confirm_batch(worker, data, token) do
    case ProcessHost.snapshot(worker.pid) do
      {:ok, %{state_revision: revision}}
      when revision == :erlang.map_get("state_revision", data) ->
        EffectDispatcher.commit_batch(worker.dispatcher, token)

      _unavailable ->
        EffectDispatcher.release(worker.dispatcher, token)
        {:error, Error.new("CALLBACK_FAILED")}
    end
  end

  defp running(%{status: "running"}), do: :ok
  defp running(_worker), do: {:error, Error.new("WORKER_NOT_RUNNING")}

  defp available(id, workers, limits) do
    case Map.get(workers, id) do
      %{status: status} when status in ["running", "restarting"] ->
        {:error, Error.new("WORKER_EXISTS")}

      nil when map_size(workers) >= limits.workers ->
        {:error, Error.new("LIMIT_EXCEEDED")}

      _other ->
        :ok
    end
  end

  defp retained_definition(args, %{status: "failed"} = worker) do
    if args["artifact_id"] == worker.artifact.id and args["config"] === worker.config do
      :ok
    else
      error =
        Map.put(Error.new("INVALID_ARGUMENT"), "details", %{
          "hint" => "Stop the worker before changing its artifact or config."
        })

      {:error, error}
    end
  end

  defp retained_definition(_args, _worker), do: :ok

  defp public(worker) do
    %{
      "worker_id" => worker.worker_id,
      "artifact_id" => worker.artifact.id,
      "implementation_version" => worker.artifact.revision,
      "pid" => if(worker.pid, do: inspect(worker.pid), else: nil),
      "worker_revision" => worker.worker_revision,
      "state_revision" => worker.state_revision,
      "status" => worker.status,
      "restart_count" => length(worker.restarts),
      "restart_limit" => 3,
      "restart_window_ms" => 10_000
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
end
