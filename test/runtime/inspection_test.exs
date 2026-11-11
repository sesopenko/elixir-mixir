defmodule ElixirMixir.Runtime.InspectionTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.MCP.Result
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup_all do
    {:ok, manager} = Manager.start_link(name: nil)

    artifacts =
      for {name, source} <- [
            {"inspection", Fixtures.effects_source()},
            {"inspection-state", Fixtures.worker_source()},
            {"inspection-probe",
             Fixtures.source(
               body:
                 "defp observe do if pid = Process.whereis(ElixirMixir.Runtime.InspectionTest), do: send(pid, :generated_callback) end",
               init: "observe(); {:ok, config}",
               event: "observe(); {:ok, event, state, []}",
               schema: "(observe(); 1)"
             )}
          ],
          into: %{} do
        {:ok, artifact} =
          Manager.define(
            %{
              "source" => source,
              "logical_name" => name,
              "expected_behavior" => "elixir_mixir.behavior.v1",
              "request_id" => name
            },
            manager
          )

        {name, artifact}
      end

    GenServer.stop(manager)
    %{artifacts: artifacts}
  end

  setup ctx do
    parent = self()
    limits = Map.get(ctx, :limits, %{})
    history = start_supervised!({EventLog, name: nil, limits: limits})

    dispatcher =
      start_supervised!(
        {EffectDispatcher,
         name: nil,
         timer: fn message, delay ->
           send(parent, {:timer, message, delay})
           nil
         end}
      )

    manager =
      start_supervised!(
        {Manager,
         name: nil,
         limits: limits,
         dispatcher: dispatcher,
         event_log: history,
         restart_timer: fn message ->
           send(parent, {:restart, message})
           nil
         end}
      )

    on_exit(fn ->
      for {_, pid, _, _} <-
            DynamicSupervisor.which_children(ElixirMixir.Runtime.WorkerSupervisor),
          do: DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, pid)
    end)

    %{manager: manager, history: history, dispatcher: dispatcher, prefix: unique()}
  end

  test "worker detail matches the actual host and immutable artifact without callbacks or mutations",
       ctx do
    id = ctx.prefix
    first = start(ctx, id)
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, id)
    {:ok, actual} = ProcessHost.snapshot(pid)
    data = inspect_worker(ctx, id)
    assert data["state"] == actual.data
    assert data["pid"] == inspect(pid)
    assert data["state_revision"] == actual.state_revision
    assert data["generation"] == first["generation"]
    assert data["artifact"]["source_hash"] == ctx.artifacts["inspection"]["source_hash"]
    assert data["artifact"]["contract_version"] == "elixir_mixir.behavior.v1"
    assert data["artifact"]["state_schema"] == 1
    refute Map.has_key?(data["artifact"], "source")
    refute Map.has_key?(data["artifact"], "beam")
    assert inspect_worker(ctx, id) == data
    {:ok, ^actual} = ProcessHost.snapshot(pid)
  end

  test "inspect and events never execute generated callbacks", ctx do
    Process.register(self(), __MODULE__)
    started = start(ctx, ctx.prefix, %{}, "inspection-probe")
    assert_receive :generated_callback
    assert inspect_worker(ctx, ctx.prefix)["generation"] == started["generation"]
    assert {:ok, %{"generation" => generation}} = Manager.events(%{}, ctx.manager)
    assert generation == started["generation"]
    refute_receive :generated_callback, 30
  end

  test "stopped, unavailable and exhausted workers report honest state and revisions", ctx do
    id = ctx.prefix
    start(ctx, id)
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, id)
    :sys.suspend(pid)

    try do
      data = inspect_worker(ctx, id)
      assert data["state_omitted"]
      assert data["available"] == false
      refute Map.has_key?(data, "state")
    after
      :sys.resume(pid)
    end

    for _ <- 1..3 do
      kill(id)
      assert_receive {:restart, message}
      send(ctx.manager, message)
      assert inspect_worker(ctx, id)["status"] == "running"
    end

    kill(id)
    data = inspect_worker(ctx, id)
    assert data["status"] == "failed"
    assert data["restart_count"] == 3
    assert data["state_omitted"]
    assert data["pid"] == nil

    {:ok, stopped} =
      Manager.stop_worker(%{"worker_id" => id, "request_id" => unique()}, ctx.manager)

    data = inspect_worker(ctx, id)
    assert data["status"] == "stopped"
    assert data["state_omitted"]
    assert data["generation"] == stopped["generation"]
  end

  test "topology distinguishes pending timers from successful observed delivery", ctx do
    source = ctx.prefix <> "_source"
    target = ctx.prefix <> "_target"
    start(ctx, source)
    start(ctx, target)

    effect = %{
      "type" => "schedule",
      "to" => target,
      "delay_ms" => 60_000,
      "event" => %{"amount" => 8}
    }

    invoke(ctx, source, %{"effects" => [effect]})
    assert_receive {:timer, message, 60_000}
    {:ok, data} = Manager.inspect_runtime(%{}, ctx.manager)
    assert data["effects"] == %{"pending" => 1, "timers" => 1, "reserved" => 0}
    assert data["topology"] == [%{"from" => source, "to" => target, "count" => 0, "pending" => 1}]
    send(ctx.dispatcher, message)
    await(fn -> inspect_worker(ctx, target)["state"]["total"] == 8 end)
    await(fn -> EffectDispatcher.snapshot(ctx.dispatcher, ctx.manager)["pending"] == 0 end)
    {:ok, data} = Manager.inspect_runtime(%{}, ctx.manager)
    assert data["topology"] == [%{"from" => source, "to" => target, "count" => 1, "pending" => 0}]
  end

  test "worker and edge cursors paginate without duplication and reject stale generations", ctx do
    ids = for index <- 1..4, do: ctx.prefix <> "_#{index}"
    for id <- ids, do: start(ctx, id)

    for source <- ids do
      invoke(ctx, source, %{
        "effects" => Enum.map(ids, &%{"type" => "emit", "to" => &1, "event" => %{}})
      })
    end

    for _ <- 1..16 do
      assert_receive {:timer, fire, 0}
      send(ctx.dispatcher, fire)
    end

    await(fn -> EffectDispatcher.snapshot(ctx.dispatcher, ctx.manager)["pending"] == 0 end)
    pages = pages(ctx, %{"limit" => 1})
    assert Enum.flat_map(pages, & &1["workers"]) |> Enum.map(& &1["worker_id"]) == ids
    edges = Enum.flat_map(pages, & &1["topology"])
    assert length(edges) == 16
    assert length(Enum.uniq_by(edges, &{&1["from"], &1["to"]})) == 16
    assert length(Enum.uniq_by(pages, & &1["generation"])) == 1
    {:ok, first} = Manager.inspect_runtime(%{"limit" => 1}, ctx.manager)
    invoke(ctx, hd(ids), %{})

    assert {:error, error} =
             Manager.inspect_runtime(%{"cursor" => first["next_cursor"]}, ctx.manager)

    assert error["code"] == "INVALID_ARGUMENT"
    assert error["details"]["hint"] =~ "Restart pagination"
  end

  test "maximum worker/state load shrinks read payloads visibly within the duplicated wire budget",
       ctx do
    payload = String.duplicate("\"\\\n😺", 1_630)

    for index <- 1..32 do
      id = ctx.prefix <> "_" <> String.pad_leading(to_string(index), 2, "0")
      start(ctx, id, %{"payload" => payload}, "inspection-state")
    end

    pages = pages(ctx, %{"limit" => 100, "detail" => "state"})
    workers = Enum.flat_map(pages, & &1["workers"])
    assert length(workers) == 32
    assert Enum.any?(workers, & &1["state_omitted"])

    for page <- pages,
        do: assert(byte_size(Result.encode(Result.tool({:ok, page}, 1), 1)) <= 65_536)

    assert Enum.any?(workers, & &1["truncated"])
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, hd(workers)["worker_id"])
    assert {:ok, %{data: %{"payload" => ^payload}}} = ProcessHost.snapshot(pid)
  end

  @tag limits: %{history_records: 3, metadata_bytes: 16}
  test "history eviction gaps, bounded metadata and filtered empty cursors are explicit", ctx do
    start(ctx, ctx.prefix)

    for index <- 1..7 do
      EventLog.append(
        %{
          "type" => "event_delivered",
          "worker_id" => ctx.prefix,
          "request_id" => "request-#{index}",
          "outcome" => "ok",
          "metadata" => %{"large" => String.duplicate("x", 20)}
        },
        ctx.history
      )
    end

    {:ok, data} = Manager.events(%{}, ctx.manager)
    assert data["gap"]
    assert data["oldest_sequence"] == 5
    assert data["dropped"] == 4
    assert data["truncated"] == 7
    assert Enum.map(data["events"], & &1["sequence"]) == [5, 6, 7]
    assert Enum.all?(data["events"], &(&1["truncated"] and not Map.has_key?(&1, "metadata")))

    for record <- data["events"],
        do: assert({:ok, _, 0} = DateTime.from_iso8601(record["timestamp"]))

    other = ctx.prefix <> "_other"
    start(ctx, other)
    {:ok, empty} = Manager.events(%{"worker_id" => other}, ctx.manager)
    assert empty["events"] == []
    assert empty["next_cursor"] == 7
    assert {:ok, again} = Manager.events(%{"worker_id" => other, "after" => 7}, ctx.manager)
    assert again["next_cursor"] == 7
    assert again["generation"] == empty["generation"]
  end

  test "large escaped history pages fit the full wire encoding without losing cursors", ctx do
    for index <- 1..100 do
      EventLog.append(
        %{
          "type" => "effect_log",
          "worker_id" => nil,
          "request_id" => "request-#{index}",
          "outcome" => "ok",
          "metadata" => %{"text" => String.duplicate("\"\\😺", 180)}
        },
        ctx.history
      )
    end

    records = event_pages(ctx, 0)
    assert Enum.map(records, & &1["sequence"]) == Enum.to_list(1..100)
    {:ok, first} = Manager.events(%{"limit" => 100}, ctx.manager)
    assert first["page_truncated"]
    assert length(first["events"]) < 100
  end

  test "every Phase 1 lifecycle event shape supports monotonic correlated history", ctx do
    names =
      ~w(compile_succeeded compile_failed worker_created worker_started worker_stopped worker_crashed worker_restarted worker_restart_exhausted event_accepted event_delivered event_failed implementation_replaced migration_failed effect_accepted effect_scheduled effect_delivered effect_failed effect_log)

    for name <- names,
        do:
          EventLog.append(
            %{
              "type" => name,
              "worker_id" => nil,
              "artifact_revision" => 1,
              "request_id" => "correlation",
              "outcome" => "ok",
              "metadata" => %{}
            },
            ctx.history
          )

    {:ok, data} = Manager.events(%{"limit" => 100}, ctx.manager)
    assert Enum.map(data["events"], & &1["type"]) == names
    assert Enum.map(data["events"], & &1["sequence"]) == Enum.to_list(1..length(names))
    assert Enum.all?(data["events"], &(&1["request_id"] == "correlation"))
    assert data["generation"] == 0
  end

  test "invalid reads and unknown workers are bounded errors and never mutate generation", ctx do
    for args <- [
          %{"unexpected" => true},
          %{"worker_id" => "bad id"},
          %{"detail" => "source"},
          %{"limit" => 0},
          %{"limit" => 101},
          %{"cursor" => "bad"},
          %{"cursor" => 1}
        ] do
      assert {:error, %{"code" => "INVALID_ARGUMENT", "generation" => 0}} =
               Manager.inspect_runtime(args, ctx.manager)
    end

    for args <- [
          %{"unexpected" => true},
          %{"after" => -1},
          %{"after" => "0"},
          %{"limit" => 101},
          %{"worker_id" => "bad id"}
        ] do
      assert {:error, %{"code" => "INVALID_ARGUMENT", "generation" => 0}} =
               Manager.events(args, ctx.manager)
    end

    for read <- [&Manager.inspect_runtime/2, &Manager.events/2] do
      assert {:error, %{"code" => "WORKER_NOT_FOUND", "generation" => 0}} =
               read.(%{"worker_id" => "missing"}, ctx.manager)
    end
  end

  @tag limits: %{response_bytes: 1_024}
  test "minimum response ceilings yield explicit omission or a bounded error", ctx do
    start(ctx, ctx.prefix)

    for result <- [
          Manager.inspect_runtime(%{}, ctx.manager),
          Manager.inspect_runtime(%{"worker_id" => ctx.prefix, "detail" => "state"}, ctx.manager),
          Manager.events(%{}, ctx.manager)
        ] do
      response =
        Result.tool(result, String.duplicate("r", 126), Limits.new(%{response_bytes: 1_024}))

      assert byte_size(Result.encode(response, String.duplicate("r", 126))) <= 1_024
    end
  end

  defp start(ctx, id, config \\ %{}, name \\ "inspection") do
    {:ok, result} =
      Manager.start_worker(
        %{
          "worker_id" => id,
          "artifact_id" => ctx.artifacts[name]["artifact_id"],
          "config" => config,
          "request_id" => unique()
        },
        ctx.manager
      )

    result
  end

  defp inspect_worker(ctx, id) do
    {:ok, data} = Manager.inspect_runtime(%{"worker_id" => id, "detail" => "state"}, ctx.manager)
    data
  end

  defp invoke(ctx, id, event) do
    {:ok, data} =
      Manager.invoke(
        %{"worker_id" => id, "event" => event, "request_id" => unique()},
        ctx.manager
      )

    data
  end

  defp kill(id) do
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp pages(ctx, args) do
    {:ok, page} = Manager.inspect_runtime(args, ctx.manager)
    assert byte_size(Result.encode(Result.tool({:ok, page}, 1), 1)) <= 65_536

    if page["next_cursor"],
      do: [page | pages(ctx, Map.put(args, "cursor", page["next_cursor"]))],
      else: [page]
  end

  defp event_pages(ctx, cursor) do
    {:ok, page} = Manager.events(%{"after" => cursor, "limit" => 100}, ctx.manager)
    assert byte_size(Result.encode(Result.tool({:ok, page}, 1), 1)) <= 65_536
    if page["events"] == [], do: [], else: page["events"] ++ event_pages(ctx, page["next_cursor"])
  end

  defp unique, do: "inspect_#{System.unique_integer([:positive])}"
  defp await(check, remaining \\ 500)
  defp await(_check, 0), do: flunk("inspection state did not settle")

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
