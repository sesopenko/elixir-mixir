defmodule ElixirMixir.TestSupport.DurableFixture do
  @moduledoc "Isolated committed workers and injectable UTC scheduling for durable delivery tests."

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.DurableArtifacts
  alias ElixirMixir.Runtime.EffectDispatcher
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.RuntimeFixture

  @doc "Compiles one shared counting fixture with declarative event/config effects and failure modes."
  @spec artifact() :: map()
  def artifact do
    source =
      Fixtures.source(
        init: ~S|{:ok, Map.merge(%{"count" => 0, "total" => 0}, config)}|,
        event: ~S"""
        effects = Map.get(event, "effects", Map.get(state, "effects", []))
        next = state |> Map.update!("count", &(&1 + 1)) |> Map.update!("total", &(&1 + Map.get(event, "amount", 1)))
        case event["mode"] do
          "error" -> {:error, "rejected"}
          "timeout" -> Process.sleep(:infinity)
          "invalid" -> {:ok, 1, %{"pid" => self()}, effects}
          _normal -> {:ok, next["count"], next, effects}
        end
        """
      )

    {:ok, manager} = Manager.start_link(name: nil)

    {:ok, result} =
      Manager.define(
        %{
          "source" => source,
          "logical_name" => unique(),
          "request_id" => unique(),
          "expected_behavior" => "elixir_mixir.behavior.v1"
        },
        manager
      )

    GenServer.stop(manager)

    {:ok, artifact} = ArtifactRegistry.fetch(result["artifact_id"])
    artifact
  end

  @doc "Starts a fresh store and Manager, seeding an already compiled fixture without extra lifetime slots."
  @spec setup(map()) :: map()
  def setup(ctx) do
    dir = RuntimeFixture.temp_path(unique())
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)

    store =
      ExUnit.Callbacks.start_supervised!(
        {Store, data_dir: dir, limits: Map.get(ctx, :limits, %{})}
      )

    dispatcher = ExUnit.Callbacks.start_supervised!({EffectDispatcher, name: nil})
    clock = ExUnit.Callbacks.start_supervised!({Agent, fn -> 1_700_000_000_000 end})
    parent = self()

    timer = fn message, delay ->
      send(parent, {:armed, message, delay})
      make_ref()
    end

    manager =
      ExUnit.Callbacks.start_supervised!(
        {Manager,
         name: nil,
         dispatcher: dispatcher,
         store: store,
         limits: Map.get(ctx, :limits, %{}),
         storage: [mode: :durable, data_dir: dir],
         wall_clock: fn -> Agent.get(clock, & &1) end,
         delivery_timer: timer}
      )

    await(fn -> :sys.get_state(manager).recovery["status"] == "ready" end)

    {:ok, nil} =
      Store.commit(store, 0, %{
        puts: %{{:artifact, ctx.artifact.id} => DurableArtifacts.record(ctx.artifact)},
        deletes: [],
        outcome: nil,
        operation_id: "fixture",
        advance: false
      })

    %{
      manager: manager,
      store: store,
      dispatcher: dispatcher,
      clock: clock,
      source: unique(),
      target: unique(),
      artifact: ctx.artifact
    }
  end

  @doc "Starts one retained worker using the shared artifact."
  @spec start(map(), String.t(), map()) :: map()
  def start(ctx, id, config \\ %{}) do
    {:ok, result} =
      Manager.start_worker(
        %{
          "worker_id" => id,
          "artifact_id" => ctx.artifact.id,
          "config" => config,
          "request_id" => unique()
        },
        ctx.manager
      )

    result
  end

  @doc "Invokes one worker and returns its bounded outcome."
  @spec invoke(map(), String.t(), map()) :: {:ok | :error, map()}
  def invoke(ctx, id, event),
    do:
      Manager.invoke(
        %{"worker_id" => id, "event" => event, "request_id" => unique()},
        ctx.manager
      )

  @doc "Reads a committed checkpoint."
  @spec data(map(), String.t()) :: map()
  def data(ctx, id), do: Store.snapshot(ctx.store)[{:state, id}]["data"]

  @doc "Lists actual pending effect records."
  @spec pending(map()) :: map()
  def pending(ctx),
    do: Map.filter(Store.snapshot(ctx.store), fn {key, _} -> match?({:effect, _}, key) end)

  @doc "Fires the currently armed trusted timer and waits for the Manager mailbox."
  @spec fire(map()) :: tuple()
  def fire(ctx) do
    %{id: id, nonce: nonce} = :sys.get_state(ctx.manager).delivery_timer
    message = {:durable_delivery, id, nonce}
    send(ctx.manager, message)
    :sys.get_state(ctx.manager)
    message
  end

  @doc "Waits for observable OTP fixture state."
  @spec await((-> boolean()), non_neg_integer()) :: :ok
  def await(check, attempts \\ 400)
  def await(_check, 0), do: raise("durable fixture did not settle")

  def await(check, attempts) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await(check, attempts - 1)
        )
  end

  @doc "Returns a unique logical fixture identity."
  @spec unique() :: String.t()
  def unique, do: "delivery-#{System.unique_integer([:positive])}"
end
