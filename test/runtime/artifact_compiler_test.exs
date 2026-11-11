defmodule ElixirMixir.Runtime.ArtifactCompilerTest do
  use ExUnit.Case, async: false
  doctest ElixirMixir.Behavior

  alias ElixirMixir.Runtime.ArtifactRegistry
  alias ElixirMixir.Runtime.Diagnostics
  alias ElixirMixir.Runtime.EventLog
  alias ElixirMixir.Runtime.Execution
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures

  setup do
    manager = start_supervised!({Manager, name: nil})
    %{manager: manager}
  end

  test "valid source loads exactly one inactive artifact and preserves original source/hash",
       ctx do
    source = Fixtures.source(init: "(raise \"init must not run\"; {:ok, config})")
    args = args(source)
    before = ArtifactRegistry.status()
    assert {:ok, result} = Manager.define(args, ctx.manager)
    assert result["generation"] == 1
    assert result["callbacks_valid"]
    assert result["compilation_status"] == "compiled"
    assert result["state_schema"] == 1
    assert result["source_hash"] == :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    assert {:ok, artifact} = ArtifactRegistry.fetch(result["artifact_id"])
    assert artifact.source == source
    assert artifact.beam |> byte_size() > 0
    assert Atom.to_string(artifact.module) =~ ~r/ElixirMixir.Generated.Slot\d{3}/

    for {callback, arity} <- [init: 1, handle_event: 2, state_schema: 0, migrate: 2] do
      assert function_exported?(artifact.module, callback, arity)
    end

    assert ArtifactRegistry.status() == %{
             "artifacts" => before["artifacts"] + 1,
             "attempts" => before["attempts"] + 1
           }

    assert {:error, %{"code" => "ARTIFACT_NOT_FOUND"}} = ArtifactRegistry.fetch("missing")
  end

  test "successful logical revisions use distinct modules and cannot overwrite prior metadata",
       ctx do
    args = args(Fixtures.source())
    {:ok, first} = Manager.define(args, ctx.manager)
    {:ok, artifact} = ArtifactRegistry.fetch(first["artifact_id"])
    {:ok, second} = Manager.define(Map.put(args, "request_id", unique()), ctx.manager)
    assert second["revision"] == first["revision"] + 1
    refute second["module"] == first["module"]
    refute second["artifact_id"] == first["artifact_id"]
    assert {:ok, ^artifact} = ArtifactRegistry.fetch(first["artifact_id"])
    assert {:ok, reservation} = ArtifactRegistry.reserve(128)

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
             ArtifactRegistry.register(reservation, artifact)

    assert {:ok, ^artifact} = ArtifactRegistry.fetch(first["artifact_id"])
  end

  test "same request replays success or failure without compilation or new events", ctx do
    for source <- [Fixtures.source(), "invalid source"] do
      args = args(source)
      result = Manager.define(args, ctx.manager)
      status = ArtifactRegistry.status()
      events = EventLog.events(%{"limit" => 100})
      assert Manager.define(args, ctx.manager) == result
      assert ArtifactRegistry.status() == status
      assert EventLog.events(%{"limit" => 100}) == events

      assert {:error, %{"code" => "REQUEST_ID_CONFLICT"}} =
               Manager.define(Map.put(args, "source", source <> " "), ctx.manager)
    end
  end

  test "rejections retain the previous artifact, revision and generation", ctx do
    args = args(Fixtures.source())
    {:ok, first} = Manager.define(args, ctx.manager)
    {:ok, artifact} = ArtifactRegistry.fetch(first["artifact_id"])

    for source <- [
          "defmodule Generated do",
          "defmodule Other do end",
          "1; defmodule Generated do end",
          Fixtures.source(body: "defmodule Nested do end"),
          Fixtures.source(body: "Module.create(Other, quote(do: nil), [])"),
          Fixtures.source(body: "Code.compile_string(\"defmodule Other do end\")"),
          Fixtures.source(body: "IO.warn(\"warning is a failure\")"),
          Fixtures.source(schema: "(IO.warn(\"schema warning\"); 1)"),
          Fixtures.source(schema: "0"),
          Fixtures.source(schema: "{:error, :bad}"),
          Fixtures.source(schema: "raise \"bad schema\"")
        ] do
      before = ArtifactRegistry.status()

      assert {:error, %{"code" => "COMPILE_FAILED"}} =
               Manager.define(%{args | "source" => source, "request_id" => unique()}, ctx.manager)

      assert ArtifactRegistry.status()["attempts"] == before["attempts"] + 1
      assert ArtifactRegistry.status()["artifacts"] == before["artifacts"]
      assert {:ok, ^artifact} = ArtifactRegistry.fetch(first["artifact_id"])
      assert {:ok, %{"generation" => 1}} = Manager.inspect_runtime(%{}, ctx.manager)
    end

    {:ok, next} = Manager.define(%{args | "request_id" => unique()}, ctx.manager)
    assert next["revision"] == first["revision"] + 1
  end

  test "missing and wrong-arity callbacks fail the contract", ctx do
    for source <- [
          "defmodule Generated do end",
          "defmodule Generated do @behaviour ElixirMixir.Behavior end",
          "defmodule Generated do def init(), do: %{} end"
        ] do
      assert {:error, %{"code" => "CALLBACK_MISSING"}} = Manager.define(args(source), ctx.manager)
    end
  end

  test "macro-generated additional output modules cannot become artifacts", ctx do
    source =
      Fixtures.source(
        body:
          "require ElixirMixir.TestSupport.GeneratedFixtures\nElixirMixir.TestSupport.GeneratedFixtures.extra_module()"
      )

    assert {:error, %{"code" => "COMPILE_FAILED"}} = Manager.define(args(source), ctx.manager)
  end

  test "source and argument validation precede slot reservation", ctx do
    before = ArtifactRegistry.status()
    valid = args(Fixtures.source())

    for altered <- [
          Map.put(valid, "logical_name", "bad name"),
          Map.put(valid, "expected_behavior", "other"),
          Map.put(valid, "unknown", true),
          Map.delete(valid, "source"),
          Map.put(valid, "source", <<255>>),
          Map.put(valid, "source", String.duplicate("x", 32_769))
        ] do
      assert {:error, _} = Manager.define(Map.put(altered, "request_id", unique()), ctx.manager)
    end

    assert ArtifactRegistry.status() == before
    source = valid["source"]
    exact = source <> String.duplicate(" ", 32_768 - byte_size(source))

    assert {:ok, _} =
             Manager.define(%{valid | "source" => exact, "request_id" => unique()}, ctx.manager)
  end

  test "compilation and schema callbacks time out and keep Manager responsive" do
    manager =
      start_supervised!(
        {Manager, name: nil, limits: %{compile_timeout_ms: 100, callback_timeout_ms: 30}},
        id: :limited_manager
      )

    for source <- [
          Fixtures.source(body: "Process.sleep(:infinity)"),
          Fixtures.source(schema: "Process.sleep(:infinity)")
        ] do
      assert {:error, %{"code" => "COMPILE_FAILED"}} = Manager.define(args(source), manager)
      assert {:ok, %{"generation" => 0}} = Manager.inspect_runtime(%{}, manager)
    end
  end

  test "execution joins spawned compiler helpers and enforces initial heap controls" do
    parent = self()

    work = fn ->
      send(parent, {:heap, Process.info(self(), :max_heap_size)})
      helper = spawn(fn -> Process.sleep(:infinity) end)
      send(parent, {:helper, helper})
      Process.sleep(:infinity)
    end

    assert {:error, :timeout, 1} = Execution.run(ElixirMixir.CompilerTasks, work, 50, 1_024)
    assert_receive {:helper, helper}
    refute Process.alive?(helper)
    assert_receive {:heap, {:max_heap_size, %{size: 1_024, kill: true, error_logger: false}}}

    assert {:error, :failed, _} =
             Execution.run(
               ElixirMixir.CallbackTasks,
               fn ->
                 Enum.reduce(1..100_000, [], fn n, acc -> [{n, n} | acc] end)
               end,
               1_000,
               1_024
             )
  end

  test "diagnostic count and UTF-8 bytes stay bounded", ctx do
    message = String.duplicate("é", 3_000)
    source = Fixtures.source(body: "IO.warn(#{inspect(message)})")

    assert {:error, %{"details" => %{"diagnostics" => diagnostics}}} =
             Manager.define(args(source), ctx.manager)

    assert length(diagnostics) <= 10

    for diagnostic <- diagnostics do
      assert byte_size(diagnostic["message"]) <= 2_048
      assert String.valid?(diagnostic["message"])
    end

    assert Diagnostics.text("éé", Limits.new(%{diagnostic_bytes: 3})) == "é"
  end

  test "wire preflight rejects an unencodable outcome before artifact publication" do
    manager =
      start_supervised!({Manager, name: nil, limits: %{response_bytes: 1_024}},
        id: :small_wire_manager
      )

    before = ArtifactRegistry.status()

    assert {:error, %{"code" => "LIMIT_EXCEEDED", "generation" => 0}} =
             Manager.define(
               Map.put(args(Fixtures.source()), "request_id", String.duplicate("r", 64)),
               manager
             )

    assert ArtifactRegistry.status()["artifacts"] == before["artifacts"]
  end

  test "minimal EventLog ring exposes gaps, cursors and metadata omission" do
    log =
      start_supervised!({EventLog, name: nil, limits: %{history_records: 2, metadata_bytes: 16}})

    for id <- 1..3 do
      assert :ok =
               EventLog.append(
                 %{
                   "type" => "test",
                   "request_id" => to_string(id),
                   "metadata" => %{"too_large" => String.duplicate("x", 20)}
                 },
                 log
               )
    end

    page = EventLog.events(%{"after" => 0, "limit" => 1}, log)
    assert page["gap"]
    assert page["oldest_sequence"] == 2
    assert page["next_cursor"] == 2
    assert page["dropped"] == 1
    assert page["truncated"] == 3

    assert Enum.all?(page["events"], fn event ->
             not Map.has_key?(event, "metadata") or
               byte_size(Jason.encode!(event["metadata"])) <= 16
           end)

    assert [%{"sequence" => 2, "truncated" => true}] = page["events"]
    assert [%{"sequence" => 3}] = EventLog.events(%{"after" => 2}, log)["events"]
  end

  defp args(source),
    do: %{
      "logical_name" => unique(),
      "request_id" => unique(),
      "source" => source,
      "expected_behavior" => "elixir_mixir.behavior.v1"
    }

  defp unique, do: "test_#{System.unique_integer([:positive])}"
end
