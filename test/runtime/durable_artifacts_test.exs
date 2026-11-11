defmodule ElixirMixir.Runtime.DurableArtifactsTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.Definition
  alias ElixirMixir.Runtime.DurableArtifacts
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.ResponseBudget
  alias ElixirMixir.Runtime.Store
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.RuntimeFixture

  setup ctx do
    dir = RuntimeFixture.temp_path("mixir-artifacts")
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

    await_ready(manager)
    %{manager: manager, store: store}
  end

  test "definition source and exact replay are committed before registry publication", ctx do
    args = args()
    assert {:ok, result} = Manager.define(args, ctx.manager)
    assert {:ok, ^result} = Manager.define(args, ctx.manager)
    records = Store.snapshot(ctx.store)
    record = records[{:artifact, result["artifact_id"]}]
    assert record["source"] == args["source"]
    assert record["source_hash"] == result["source_hash"]
    assert record["original_module"] == result["module"]
    assert record["revision"] == 1
    assert records[:meta]["generation"] == 1
    assert records[:meta]["next_audit_sequence"] == 1
    assert records[{:request, args["request_id"]}]["status"] == "done"

    assert {:error, %{"code" => "REQUEST_ID_CONFLICT"}} =
             Manager.define(%{args | "source" => args["source"] <> "\n"}, ctx.manager)

    assert {:ok, artifact} = ArtifactRegistry.fetch(result["artifact_id"])
    assert artifact.source == args["source"]
  end

  test "compilation failure replays without consuming another slot or advancing generation",
       ctx do
    args = %{args() | "source" => "invalid"}
    before = ArtifactRegistry.status()["attempts"]
    assert {:error, failure} = Manager.define(args, ctx.manager)
    assert {:error, ^failure} = Manager.define(args, ctx.manager)
    assert ArtifactRegistry.status()["attempts"] == before + 1
    assert Store.snapshot(ctx.store)[:meta]["generation"] == 0

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
             Manager.define(Map.put(args, "extra", true), ctx.manager)

    assert Enum.count(Store.snapshot(ctx.store), fn {key, _} -> match?({:request, _}, key) end) ==
             1
  end

  @tag limits: %{response_bytes: 1_024}
  test "large compilation errors are bounded before their durable outcome commits", ctx do
    source = Fixtures.source(body: ~S|IO.warn(String.duplicate("x", 5_000))|)
    arguments = %{args() | "source" => source}
    assert {:error, error} = Manager.define(arguments, ctx.manager)
    assert error["code"] == "LIMIT_EXCEEDED"
    assert ResponseBudget.fits?(error, Limits.new(%{response_bytes: 1_024}))
    assert {:error, ^error} = Manager.define(arguments, ctx.manager)
    assert Store.snapshot(ctx.store)[:meta]["generation"] == 0
  end

  test "restoration preserves identity while source corruption is retained and revision high-water survives" do
    {:ok, _, _reservation, artifact} = Definition.prepare(args(), 1, Limits.new())
    diagnostic = "Elixir.Unseen_" <> Base.encode16(:crypto.strong_rand_bytes(16))
    record = Map.put(DurableArtifacts.record(artifact), "original_module", diagnostic)
    id = "retained-#{System.unique_integer([:positive])}"

    records = %{
      {:artifact, id} => record,
      {:artifact, "corrupt"} => %{record | "source_hash" => "wrong", "revision" => 20}
    }

    assert {:ok, %{"restored" => 1, "quarantined" => 1}} =
             DurableArtifacts.recover(records, Limits.new())

    assert {:ok, restored} = ArtifactRegistry.fetch(id)
    assert restored.source == artifact.source
    assert restored.module.init(%{"ready" => true}) == {:ok, %{"ready" => true}}
    assert restored.original_module == diagnostic
    assert_raise ArgumentError, fn -> String.to_existing_atom(diagnostic) end
    assert restored.id == id
    assert restored.module != artifact.module
    assert ArtifactRegistry.next_revision(artifact.logical_name) == 21
    assert records[{:artifact, "corrupt"}]["source_hash"] == "wrong"
  end

  test "excess retained definitions fail before arbitrary truncation or compilation" do
    records = %{{:artifact, "one"} => %{}, {:artifact, "two"} => %{}}
    before = ArtifactRegistry.status()["attempts"]

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             DurableArtifacts.recover(records, Limits.new(%{artifact_slots: 1}))

    assert ArtifactRegistry.status()["attempts"] == before
  end

  defp args do
    id = "durable-#{System.unique_integer([:positive])}"

    %{
      "logical_name" => id,
      "request_id" => id,
      "source" => Fixtures.source(),
      "expected_behavior" => "elixir_mixir.behavior.v1"
    }
  end

  defp await_ready(manager, attempts \\ 200)
  defp await_ready(_manager, 0), do: flunk("durable recovery did not complete")

  defp await_ready(manager, attempts) do
    case :sys.get_state(manager).recovery["status"] do
      "ready" ->
        :ok

      "recovering" ->
        Process.sleep(5)
        await_ready(manager, attempts - 1)
    end
  end
end
