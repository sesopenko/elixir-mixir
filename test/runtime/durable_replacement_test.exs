defmodule ElixirMixir.Runtime.DurableReplacementTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup ctx do
    dir = Path.join(System.tmp_dir!(), "mixir-replace-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    store = start_supervised!({Store, data_dir: dir})

    manager =
      start_supervised!(
        {Manager,
         name: nil,
         store: store,
         limits: Map.get(ctx, :limits, %{}),
         storage: [mode: :durable, data_dir: dir]}
      )

    await(fn -> :sys.get_state(manager).recovery["status"] == "ready" end)

    logical_name = unique()

    artifacts =
      for version <- 1..3, into: %{} do
        {:ok, artifact} =
          Manager.define(
            %{
              "logical_name" => logical_name,
              "source" => Fixtures.replacement_source(version),
              "expected_behavior" => "elixir_mixir.behavior.v1",
              "request_id" => unique()
            },
            manager
          )

        {version, artifact["artifact_id"]}
      end

    worker = Map.get(ctx, :worker_id, unique())

    {:ok, first} =
      Manager.start_worker(
        %{
          "worker_id" => worker,
          "artifact_id" => artifacts[1],
          "config" => %{},
          "request_id" => "s"
        },
        manager
      )

    %{manager: manager, store: store, worker: worker, artifacts: artifacts, first: first}
  end

  test "compatible and migrated replacements select one artifact/checkpoint and preserve the live host",
       ctx do
    [{_, host}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    monitor = Process.monitor(host)

    {:ok, _} =
      Manager.invoke(
        %{"worker_id" => ctx.worker, "event" => %{"amount" => 3}, "request_id" => unique()},
        ctx.manager
      )

    args = args(ctx, 2, 1)
    assert {:ok, compatible} = Manager.replace(args, ctx.manager)
    assert compatible["migration_result"] == "preserved"
    assert compatible["state_revision"] == 2
    assert compatible["pid_after"] == ctx.first["pid"]
    assert {:ok, ^compatible} = Manager.replace(args, ctx.manager)
    assert snapshot(ctx)["state"]["count"] == 3
    assert {:ok, migrated} = Manager.replace(args(ctx, 3, 2), ctx.manager)
    assert migrated["migration_result"] == "migrated"
    assert migrated["state_revision"] == 3
    assert migrated["worker_revision"] == 3
    assert migrated["pid_before"] == migrated["pid_after"]
    refute_receive {:DOWN, ^monitor, :process, ^host, _}
    records = Store.snapshot(ctx.store)
    assert records[{:worker, ctx.worker}]["artifact_id"] == ctx.artifacts[3]
    assert records[{:state, ctx.worker}]["schema"] == 2
    assert records[{:state, ctx.worker}]["data"]["value"] == 3
    assert snapshot(ctx)["artifact_id"] == ctx.artifacts[3]
  end

  @tag :migration_events
  test "failed migrations retain every committed selection/state field and replay the exact failure",
       ctx do
    for mode <- ~w(error raise exit timeout late malformed invalid_root non_json oversized heap) do
      worker = unique()

      {:ok, _} =
        Manager.start_worker(
          %{
            "worker_id" => worker,
            "artifact_id" => ctx.artifacts[1],
            "config" => %{"migration" => mode},
            "request_id" => unique()
          },
          ctx.manager
        )

      current = %{ctx | worker: worker}
      before = Store.snapshot(ctx.store)
      args = args(current, 3, 1)

      assert {:error, %{"code" => "MIGRATION_FAILED"} = failure} =
               Manager.replace(args, ctx.manager)

      assert {:error, ^failure} = Manager.replace(args, ctx.manager)
      after_failure = Store.snapshot(ctx.store)
      assert after_failure[{:worker, worker}] == before[{:worker, worker}]
      assert after_failure[{:state, worker}] == before[{:state, worker}]
      assert after_failure[:meta]["generation"] == before[:meta]["generation"]
      {:ok, history} = Manager.events(%{"worker_id" => worker}, ctx.manager)
      assert Enum.any?(history["events"], &(&1["type"] == "migration_failed"))
    end
  end

  test "unknown/invalid candidates and stale revisions cannot change the active selection", ctx do
    before = snapshot(ctx)

    assert {:error, %{"code" => "ARTIFACT_NOT_FOUND"}} =
             Manager.replace(%{args(ctx, 2, 1) | "artifact_id" => "missing"}, ctx.manager)

    assert {:error, %{"code" => "REVISION_CONFLICT"}} =
             Manager.replace(args(ctx, 3, 99), ctx.manager)

    assert {:error, %{"code" => "CALLBACK_MISSING"}} =
             Manager.define(
               %{
                 "logical_name" => unique(),
                 "source" => "defmodule Generated do\nend",
                 "expected_behavior" => "elixir_mixir.behavior.v1",
                 "request_id" => unique()
               },
               ctx.manager
             )

    assert snapshot(ctx) == before
  end

  @tag limits: %{response_bytes: 1_024}, worker_id: String.duplicate("w", 40)
  test "wire preflight rejects replacement before committing selection or migrated state", ctx do
    [{_, host}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)
    {:ok, before} = ProcessHost.snapshot(host)
    args = %{args(ctx, 2, 1) | "request_id" => String.duplicate("r", 64)}
    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} = Manager.replace(args, ctx.manager)
    assert {:ok, ^before} = ProcessHost.snapshot(host)
    assert Store.snapshot(ctx.store)[{:worker, ctx.worker}]["artifact_id"] == ctx.artifacts[1]
  end

  defp args(ctx, version, revision),
    do: %{
      "worker_id" => ctx.worker,
      "artifact_id" => ctx.artifacts[version],
      "expected_revision" => revision,
      "request_id" => unique()
    }

  defp snapshot(ctx) do
    {:ok, data} =
      Manager.inspect_runtime(%{"worker_id" => ctx.worker, "detail" => "state"}, ctx.manager)

    data
  end

  defp unique, do: "replace-#{System.unique_integer([:positive])}"
  defp await(check, attempts \\ 200)
  defp await(_check, 0), do: flunk("replacement recovery did not settle")

  defp await(check, attempts) do
    unless check.() do
      Process.sleep(5)
      await(check, attempts - 1)
    end
  end
end
