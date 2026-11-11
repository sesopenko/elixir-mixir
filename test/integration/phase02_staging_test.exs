defmodule ElixirMixir.Integration.Phase02StagingTest do
  use ExUnit.Case, async: false

  alias ElixirMixir.TestSupport.GeneratedFixtures, as: Fixtures
  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  test "HTTP disconnect during preparation retains old state and dispatches only after publication" do
    fixture = start_supervised!({RuntimeFixture, []})
    ready = RuntimeFixture.ready(fixture)
    client = Client.new(ready.port)
    {_init, _notification, client} = Client.initialize(client)
    on_exit(fn -> Client.close(%{client | session: nil}) end)

    artifact =
      tool(client, "runtime_define", %{
        "logical_name" => "staging-http",
        "source" => Fixtures.effects_source(),
        "expected_behavior" => "elixir_mixir.behavior.v1",
        "request_id" => "define"
      })

    for {id, config} <- [{"peer", %{}}, {"source", %{"forward" => "peer"}}] do
      tool(client, "runtime_start", %{
        "worker_id" => id,
        "artifact_id" => artifact["artifact_id"],
        "config" => config,
        "request_id" => "start-#{id}"
      })
    end

    before = RuntimeFixture.control(fixture, %{"op" => "host_state", "id" => "source"})
    RuntimeFixture.control(fixture, %{"op" => "publication_barrier", "enabled" => true})
    args = %{"worker_id" => "source", "event" => %{"amount" => 7}, "request_id" => "accepted"}

    pending =
      Task.async(fn ->
        try do
          Client.call(client, "runtime_invoke", args)
        rescue
          MatchError -> :connection_closed
        end
      end)

    await(fn ->
      RuntimeFixture.control(fixture, %{"op" => "barrier_status", "key" => "publication"})[
        "waiting"
      ]
    end)

    assert RuntimeFixture.control(fixture, %{"op" => "host_state", "id" => "source"}) == before

    assert RuntimeFixture.control(fixture, %{"op" => "host_state", "id" => "peer"})["state"][
             "total"
           ] == 0

    stats = RuntimeFixture.control(fixture, %{"op" => "dispatcher_status"})
    assert stats["reserved"] == 1
    assert stats["pending"] == 0
    Client.disconnect(client)
    RuntimeFixture.control(fixture, %{"op" => "release_barrier", "key" => "publication"})
    assert Task.await(pending) == :connection_closed
    RuntimeFixture.control(fixture, %{"op" => "publication_barrier", "enabled" => false})
    fresh = Client.new(ready.port)
    {_init, _notification, fresh} = Client.initialize(fresh)
    on_exit(fn -> Client.close(%{fresh | session: nil}) end)
    result = tool(fresh, "runtime_invoke", args)
    assert result["reply"] == 1
    assert result["state_revision"] == 2
    assert tool(fresh, "runtime_invoke", args) == result

    await(fn ->
      RuntimeFixture.control(fixture, %{"op" => "host_state", "id" => "peer"})["state"]["total"] ==
        7
    end)

    assert RuntimeFixture.control(fixture, %{"op" => "host_state", "id" => "source"})["state"][
             "total"
           ] == 7

    assert RuntimeFixture.control(fixture, %{"op" => "host_state", "id" => "peer"})["state"][
             "count"
           ] == 1
  end

  defp tool(client, name, args) do
    {response, _} = Client.call(client, name, args)
    refute response.data["result"]["isError"]
    response.data["result"]["structuredContent"]
  end

  defp await(check, attempts \\ 200)
  defp await(_check, 0), do: flunk("staging barrier or delivery did not settle")

  defp await(check, attempts) do
    unless check.() do
      Process.sleep(5)
      await(check, attempts - 1)
    end
  end
end
