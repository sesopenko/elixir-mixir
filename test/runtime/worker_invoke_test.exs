defmodule ElixirMixir.Runtime.WorkerInvokeTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.ProcessHost
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup_all do
    {:ok, manager} = Manager.start_link(name: nil)

    {:ok, artifact} =
      Manager.define(
        %{
          "source" => Fixtures.counter_source(),
          "logical_name" => "counter-fixture",
          "expected_behavior" => "elixir_mixir.behavior.v1",
          "request_id" => "counter-fixture"
        },
        manager
      )

    GenServer.stop(manager)
    %{artifact: artifact["artifact_id"]}
  end

  setup context do
    limits = Map.get(context, :limits, %{})
    manager = start_supervised!({Manager, name: nil, limits: limits})
    worker = unique()

    {:ok, started} =
      Manager.start_worker(
        %{
          "worker_id" => worker,
          "artifact_id" => context.artifact,
          "config" => %{"initial" => 0},
          "request_id" => unique()
        },
        manager
      )

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(ElixirMixir.Runtime.WorkerSupervisor) do
        DynamicSupervisor.terminate_child(ElixirMixir.Runtime.WorkerSupervisor, pid)
      end
    end)

    %{manager: manager, worker: worker, started: started}
  end

  test "events commit reply/state atomically without changing the host PID", ctx do
    assert {:ok, result} = invoke(ctx, %{"amount" => 3})
    assert result["reply"] == 3
    assert result["effects"] == []
    assert result["worker_revision"] == 1
    assert result["state_revision"] == 2
    assert result["generation"] == 2
    assert {:ok, snapshot} = snapshot(ctx)
    assert snapshot["state"] == %{"count" => 3}
    assert snapshot["pid"] == ctx.started["pid"]
  end

  test "sequential/concurrent callers observe serialized transitions and exact replay", ctx do
    args = args(ctx, %{"amount" => 1})
    assert {:ok, first} = Manager.invoke(args, ctx.manager)
    assert {:ok, ^first} = Manager.invoke(args, ctx.manager)

    assert {:error, %{"code" => "REQUEST_ID_CONFLICT"}} =
             Manager.invoke(%{args | "event" => %{"amount" => 2}}, ctx.manager)

    tasks = for _ <- 1..10, do: Task.async(fn -> invoke(ctx, %{"amount" => 1}) end)
    results = Enum.map(tasks, &Task.await/1)

    assert Enum.sort(Enum.map(results, fn {:ok, value} -> value["reply"] end)) ==
             Enum.to_list(2..11)

    assert {:ok, %{"state" => %{"count" => 11}, "state_revision" => 12}} = snapshot(ctx)
  end

  test "every rejected callback retains PID, state, revisions and generation", ctx do
    {:ok, before} = snapshot(ctx)

    for {mode, code} <- [
          {"error", "CALLBACK_FAILED"},
          {"raise", "CALLBACK_FAILED"},
          {"exit", "CALLBACK_FAILED"},
          {"timeout", "CALLBACK_TIMEOUT"},
          {"malformed", "INVALID_TRANSITION"},
          {"reply_non_json", "INVALID_TRANSITION"},
          {"state_non_json", "INVALID_TRANSITION"},
          {"invalid_state", "INVALID_TRANSITION"},
          {"effects", "INVALID_TRANSITION"},
          {"heap", "CALLBACK_FAILED"}
        ] do
      assert {:error, %{"code" => ^code}} = invoke(ctx, %{"mode" => mode})
      assert {:ok, ^before} = snapshot(ctx)
    end

    assert {:ok, %{"reply" => 1}} = invoke(ctx, %{})
  end

  test "bad event types, byte bounds and unsupported fields cannot alter state", ctx do
    {:ok, before} = snapshot(ctx)

    for event <- [nil, [], %{"x" => self()}, %{"large" => String.duplicate("x", 16_384)}] do
      assert {:error, _error} = invoke(ctx, event)
      assert {:ok, ^before} = snapshot(ctx)
    end

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
             Manager.invoke(Map.put(args(ctx, %{}), "extra", 1), ctx.manager)

    assert {:ok, ^before} = snapshot(ctx)
  end

  test "exact event/reply/state limits pass and one-over outputs leave the last state intact",
       ctx do
    event = %{"v" => String.duplicate("x", 16_376)}
    assert byte_size(Jason.encode!(event)) == 16_384
    assert {:ok, _} = invoke(ctx, event)
    assert {:ok, result} = invoke(ctx, %{"mode" => "reply_payload", "bytes" => 16_382})
    assert byte_size(Jason.encode!(result["reply"])) == 16_384
    {:ok, before} = snapshot(ctx)

    for event <- [
          %{"mode" => "reply_payload", "bytes" => 16_383},
          %{"mode" => "state_payload", "bytes" => 16_377}
        ] do
      assert {:error, %{"code" => "LIMIT_EXCEEDED"}} = invoke(ctx, event)
      assert {:ok, ^before} = snapshot(ctx)
    end

    assert {:ok, _} = invoke(ctx, %{"mode" => "state_payload", "bytes" => 16_376})
    assert {:ok, final} = snapshot(ctx)
    assert byte_size(Jason.encode!(final["state"])) == 16_384
  end

  @tag limits: %{response_bytes: 2_048}
  test "full wire response preflight happens before the state commit", ctx do
    {:ok, before} = snapshot(ctx)

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             invoke(ctx, %{"mode" => "reply_payload", "bytes" => 1_500})

    assert {:ok, ^before} = snapshot(ctx)
    assert {:ok, %{"reply" => 1}} = invoke(ctx, %{})
  end

  test "callback errors have bounded reasons and replay their original failure", ctx do
    args = args(ctx, %{"mode" => "error", "reason" => String.duplicate("é", 3_000)})

    assert {:error, %{"details" => %{"reason" => reason}} = error} =
             Manager.invoke(args, ctx.manager)

    assert byte_size(reason) <= 2_048
    assert String.valid?(reason)
    assert {:error, ^error} = Manager.invoke(args, ctx.manager)
    assert {:ok, %{"state_revision" => 1}} = snapshot(ctx)
  end

  test "late callbacks cannot commit and a healthy peer remains responsive", ctx do
    assert {:error, %{"code" => "CALLBACK_TIMEOUT"}} = invoke(ctx, %{"mode" => "late"})
    peer = unique()

    {:ok, _} =
      Manager.start_worker(
        %{
          "worker_id" => peer,
          "artifact_id" => ctx.artifact,
          "config" => %{},
          "request_id" => unique()
        },
        ctx.manager
      )

    assert {:ok, %{"reply" => 1}} =
             Manager.invoke(
               %{"worker_id" => peer, "event" => %{}, "request_id" => unique()},
               ctx.manager
             )

    # This exceeds the fixture's delayed return; a killed callback has no late transition.
    Process.sleep(120)
    assert {:ok, %{"state" => %{"count" => 0}, "state_revision" => 1}} = snapshot(ctx)
  end

  test "unknown/stopped workers and direct non-Manager messages do not run generated events",
       ctx do
    [{_, pid}] = Registry.lookup(ElixirMixir.Runtime.ProcessRegistry, ctx.worker)

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
             ProcessHost.prepare_invoke(pid, %{}, %{generation: 2, request_id: unique()}, 1_000)

    assert {:ok, %{"state_revision" => 1}} = snapshot(ctx)

    assert {:error, %{"code" => "WORKER_NOT_FOUND"}} =
             Manager.invoke(
               %{"worker_id" => unique(), "event" => %{}, "request_id" => unique()},
               ctx.manager
             )

    {:ok, _} =
      Manager.stop_worker(%{"worker_id" => ctx.worker, "request_id" => unique()}, ctx.manager)

    assert {:error, %{"code" => "WORKER_NOT_RUNNING"}} = invoke(ctx, %{})
  end

  defp invoke(ctx, event), do: Manager.invoke(args(ctx, event), ctx.manager)

  defp args(ctx, event),
    do: %{"worker_id" => ctx.worker, "event" => event, "request_id" => unique()}

  defp snapshot(ctx),
    do: Manager.inspect_runtime(%{"worker_id" => ctx.worker, "detail" => "state"}, ctx.manager)

  defp unique, do: "invoke_#{System.unique_integer([:positive])}"
end
