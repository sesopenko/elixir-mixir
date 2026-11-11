defmodule ElixirMixir.Runtime.ReplacementTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.TestSupport.CallbackBarrier
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup_all do
    {:ok, manager} = Manager.start_link(name: nil)

    artifacts =
      for version <- 1..3, into: %{} do
        {:ok, data} =
          Manager.define(
            %{
              "source" => Fixtures.replacement_source(version),
              "logical_name" => "replace-counter",
              "expected_behavior" => "elixir_mixir.behavior.v1",
              "request_id" => "replace-#{version}"
            },
            manager
          )

        {version, data}
      end

    GenServer.stop(manager)
    %{artifacts: artifacts}
  end

  setup ctx do
    start_supervised!(CallbackBarrier)
    manager = start_supervised!({Manager, name: nil, limits: Map.get(ctx, :limits, %{})})
    worker = unique()

    {:ok, first} =
      Manager.start_worker(
        %{
          "worker_id" => worker,
          "artifact_id" => ctx.artifacts[1]["artifact_id"],
          "config" => %{"migration" => Map.get(ctx, :migration, "ok")},
          "request_id" => unique()
        },
        manager
      )

    on_exit(fn ->
      for {_, pid, _, _} <-
            DynamicSupervisor.which_children(ElixirMixir.Runtime.WorkerSupervisor),
          do: DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, pid)
    end)

    %{manager: manager, worker: worker, first: first}
  end

  test "same-schema replacement retains PID/state and bypasses migrate while the next event changes behavior",
       ctx do
    assert {:ok, %{"reply" => 3}} = invoke(ctx, %{"amount" => 3})
    before = snapshot(ctx)
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    monitor = Process.monitor(pid)
    {:ok, old_artifact} = ArtifactRegistry.fetch(ctx.artifacts[1]["artifact_id"])
    assert {:ok, result} = replace(ctx, 2, before["worker_revision"])
    assert result["pid_before"] == before["pid"]
    assert result["pid_after"] == before["pid"]
    assert result["previous_revision"] == 1
    assert result["new_revision"] == 2
    assert result["worker_revision"] == before["worker_revision"] + 1
    assert result["state_revision"] == before["state_revision"]
    assert result["migration_result"] == "preserved"
    assert result["generation"] == before["generation"] + 1
    assert snapshot(ctx)["state"] == before["state"]
    assert snapshot(ctx)["artifact_id"] == ctx.artifacts[2]["artifact_id"]
    assert {:ok, %{"reply" => 5}} = invoke(ctx, %{})
    refute_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 20
    assert {:ok, ^old_artifact} = ArtifactRegistry.fetch(ctx.artifacts[1]["artifact_id"])
  end

  test "schema migration receives exact context and reverse migration is explicit", ctx do
    invoke(ctx, %{"amount" => 4})
    before = snapshot(ctx)
    args = replace_args(ctx, 3, before["worker_revision"])
    assert {:ok, result} = Manager.replace(args, ctx.manager)
    assert result["migration_result"] == "migrated"
    assert result["state_revision"] == before["state_revision"] + 1
    migrated = snapshot(ctx)
    assert migrated["state"]["value"] == 4

    assert migrated["state"]["metadata"] == %{
             "worker_id" => ctx.worker,
             "old_artifact_id" => ctx.artifacts[1]["artifact_id"],
             "new_artifact_id" => ctx.artifacts[3]["artifact_id"],
             "old_state_schema" => 1,
             "new_state_schema" => 2,
             "worker_revision" => before["worker_revision"],
             "state_revision" => before["state_revision"],
             "request_id" => args["request_id"]
           }

    assert {:ok, %{"reply" => 14}} = invoke(ctx, %{})
    assert {:ok, reverse} = replace(ctx, 1, result["worker_revision"])
    assert reverse["migration_result"] == "migrated"
    assert reverse["new_revision"] == 1
    assert reverse["worker_revision"] == 3
    assert reverse["pid_after"] == before["pid"]
    assert snapshot(ctx)["state"]["count"] == 14
    assert {:ok, %{"reply" => 15}} = invoke(ctx, %{})
  end

  test "replay is exact, payload reuse conflicts and two expected-revision competitors have one winner",
       ctx do
    args = replace_args(ctx, 2, 1)
    assert {:ok, first} = Manager.replace(args, ctx.manager)
    assert {:ok, ^first} = Manager.replace(args, ctx.manager)

    assert {:error, %{"code" => "REQUEST_ID_CONFLICT"}} =
             Manager.replace(
               %{args | "artifact_id" => ctx.artifacts[3]["artifact_id"]},
               ctx.manager
             )

    assert {:error, %{"code" => "REVISION_CONFLICT"}} = replace(ctx, 3, 1)
    tasks = for _ <- 1..2, do: Task.async(fn -> replace(ctx, 1, 2) end)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &(elem(&1, 0) == :ok)) == 1

    assert [{:error, %{"code" => "REVISION_CONFLICT"}}] =
             Enum.filter(results, &(elem(&1, 0) == :error))

    assert snapshot(ctx)["worker_revision"] == 3
  end

  test "all migration failure modes retain the complete old snapshot and old behavior", ctx do
    for mode <- ~w(error raise exit timeout late malformed invalid_root non_json oversized heap) do
      Manager.stop_worker(%{"worker_id" => ctx.worker, "request_id" => unique()}, ctx.manager)

      {:ok, _} =
        Manager.start_worker(
          %{
            "worker_id" => ctx.worker,
            "artifact_id" => ctx.artifacts[1]["artifact_id"],
            "config" => %{"migration" => mode},
            "request_id" => unique()
          },
          ctx.manager
        )

      before = snapshot(ctx)
      args = replace_args(ctx, 3, before["worker_revision"])

      assert {:error, %{"code" => "MIGRATION_FAILED"} = error} =
               Manager.replace(args, ctx.manager)

      assert {:error, ^error} = Manager.replace(args, ctx.manager)
      assert snapshot(ctx) == before
      assert {:ok, %{"reply" => 1}} = invoke(ctx, %{})

      if mode == "error" do
        assert String.valid?(error["details"]["reason"])
        assert byte_size(error["details"]["reason"]) <= 2_048
      end
    end
  end

  test "invalid definitions and missing/stopped references cannot change active implementation",
       ctx do
    before = snapshot(ctx)

    for source <- [
          "defmodule Generated do",
          "defmodule Generated do @behaviour ElixirMixir.Behavior end"
        ] do
      assert {:error, _} =
               Manager.define(
                 %{
                   "source" => source,
                   "logical_name" => "bad-replacement",
                   "expected_behavior" => "elixir_mixir.behavior.v1",
                   "request_id" => unique()
                 },
                 ctx.manager
               )

      assert snapshot(ctx) == before
    end

    args = replace_args(ctx, 2, 1)

    for invalid <- [
          Map.put(args, "unknown", true),
          Map.delete(args, "expected_revision"),
          %{args | "expected_revision" => 0},
          %{args | "expected_revision" => "1"}
        ] do
      assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
               Manager.replace(Map.put(invalid, "request_id", unique()), ctx.manager)
    end

    assert {:error, %{"code" => "ARTIFACT_NOT_FOUND"}} =
             Manager.replace(%{args | "artifact_id" => "missing"}, ctx.manager)

    assert {:error, %{"code" => "WORKER_NOT_FOUND"}} =
             Manager.replace(
               %{args | "worker_id" => "missing", "request_id" => unique()},
               ctx.manager
             )

    assert snapshot(ctx) == before
    Manager.stop_worker(%{"worker_id" => ctx.worker, "request_id" => unique()}, ctx.manager)
    assert {:error, %{"code" => "WORKER_NOT_RUNNING"}} = replace(ctx, 2, 2)
  end

  @tag migration: "controlled"
  test "queued events after a controlled replacement use only the new implementation", ctx do
    before = snapshot(ctx)
    pending = Task.async(fn -> replace(ctx, 3, 1) end)
    await(fn -> CallbackBarrier.status("replace")["waiting"] end)
    event = Task.async(fn -> invoke(ctx, %{}) end)
    await(fn -> queued?(ctx.manager, :invoke) end)
    CallbackBarrier.release("replace")
    assert {:ok, result} = Task.await(pending)
    assert result["pid_after"] == before["pid"]
    assert {:ok, %{"reply" => 10}} = Task.await(event)
    assert snapshot(ctx)["state"]["value"] == 10
  end

  test "an accepted event before replacement commits its old callback state before migration",
       ctx do
    event = Task.async(fn -> invoke(ctx, %{"controlled" => true}) end)
    await(fn -> CallbackBarrier.status("event")["waiting"] end)
    replacement = Task.async(fn -> replace(ctx, 3, 1) end)
    await(fn -> queued?(ctx.manager, :replace) end)
    CallbackBarrier.release("event")
    assert {:ok, %{"reply" => 1}} = Task.await(event)
    assert {:ok, %{"migration_result" => "migrated"}} = Task.await(replacement)
    assert snapshot(ctx)["state"]["value"] == 1
    assert {:ok, %{"reply" => 11}} = invoke(ctx, %{})
  end

  @tag migration: "controlled"
  test "host death during staging returns cached failure and recovery retains the old artifact",
       ctx do
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    args = replace_args(ctx, 3, 1)
    pending = Task.async(fn -> Manager.replace(args, ctx.manager) end)
    await(fn -> CallbackBarrier.status("replace")["waiting"] end)
    Process.exit(pid, :kill)
    assert {:error, %{"code" => "CALLBACK_FAILED"} = error} = Task.await(pending)

    await(fn ->
      data = snapshot(ctx)
      data["status"] == "running" and data["pid"] != ctx.first["pid"]
    end)

    assert snapshot(ctx)["artifact_id"] == ctx.artifacts[1]["artifact_id"]
    assert {:error, ^error} = Manager.replace(args, ctx.manager)
    assert {:ok, %{"reply" => 1}} = invoke(ctx, %{})
  end

  @tag limits: %{response_bytes: 1_024}
  test "complete response rejection leaves the old host artifact and data unchanged", ctx do
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    {:ok, before} = ProcessHost.snapshot(pid)
    args = Map.put(replace_args(ctx, 2, 1), "request_id", String.duplicate("r", 64))
    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} = Manager.replace(args, ctx.manager)
    assert {:ok, ^before} = ProcessHost.snapshot(pid)
  end

  defp replace(ctx, version, expected),
    do: Manager.replace(replace_args(ctx, version, expected), ctx.manager)

  defp replace_args(ctx, version, expected),
    do: %{
      "worker_id" => ctx.worker,
      "artifact_id" => ctx.artifacts[version]["artifact_id"],
      "expected_revision" => expected,
      "request_id" => unique()
    }

  defp invoke(ctx, event),
    do:
      Manager.invoke(
        %{"worker_id" => ctx.worker, "event" => event, "request_id" => unique()},
        ctx.manager
      )

  defp snapshot(ctx) do
    {:ok, data} =
      Manager.inspect_runtime(%{"worker_id" => ctx.worker, "detail" => "state"}, ctx.manager)

    data
  end

  defp queued?(manager, operation) do
    {:messages, messages} = Process.info(manager, :messages)
    Enum.any?(messages, &match?({:"$gen_call", _from, {:worker, ^operation, _args}}, &1))
  end

  defp unique, do: "replace_#{System.unique_integer([:positive])}"
  defp await(check, remaining \\ 500)
  defp await(_check, 0), do: flunk("replacement did not reach the expected phase")

  defp await(check, remaining) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(1)
          await(check, remaining - 1)
        )
  end
end
