defmodule ElixirMixir.Integration.Phase02StoreTest do
  use ExUnit.Case, async: false
  alias ElixirMixir.TestSupport.MCPClient, as: Client
  alias ElixirMixir.TestSupport.RuntimeFixture

  @tag capture_log: true
  test "readiness timeout terminates its owned OS process" do
    fixture =
      start_supervised!(
        Supervisor.child_spec(
          {RuntimeFixture, boot_timeout_ms: 200, startup_delay_ms: 2_000},
          restart: :temporary
        )
      )

    ref = Process.monitor(fixture)
    {:os_pid, os_pid} = fixture |> :sys.get_state() |> Map.fetch!(:port) |> Port.info(:os_pid)
    assert_receive {:DOWN, ^ref, :process, ^fixture, :boot_timeout}, 3_000
    assert_os_dead(os_pid, 100)
  end

  test "loss of the authoritative store shuts down the runtime" do
    dir = Path.join(System.tmp_dir!(), "mixir-store-death-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    fixture = start_supervised!({RuntimeFixture, data_dir: dir})
    RuntimeFixture.ready(fixture)

    assert RuntimeFixture.control(fixture, %{"op" => "kill_store"}) ==
             %{"kernel_down" => true, "manager_alive" => false}
  end

  test "SIGKILL retains the atomic store while HTTP rejects an unknown replacement target" do
    dir = Path.join(System.tmp_dir!(), "mixir-restart-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    fixture = start_supervised!({RuntimeFixture, data_dir: dir})
    ready = RuntimeFixture.ready(fixture)
    client = Client.new(ready.port)
    {_init, _notification, client} = Client.initialize(client)
    {response, _} = Client.call(client, "runtime_inspect", %{})

    assert response.data["result"]["structuredContent"]["storage"] ==
             %{"mode" => "durable", "format_version" => 1}

    {response, _} =
      Client.call(client, "runtime_replace", %{
        "request_id" => "rejected",
        "worker_id" => "never",
        "artifact_id" => "missing",
        "expected_revision" => 1
      })

    assert response.data["result"]["structuredContent"]["code"] == "WORKER_NOT_FOUND"

    assert RuntimeFixture.control(fixture, %{"op" => "registry_status"}) == %{
             "artifacts" => 0,
             "attempts" => 0
           }

    Client.close(client)

    assert RuntimeFixture.control(fixture, %{"op" => "store_commit", "value" => %{"value" => 42}}) ==
             %{"saved" => true}

    before = RuntimeFixture.control(fixture, %{"op" => "store_snapshot"})
    assert :ok = RuntimeFixture.kill(fixture)
    refute RuntimeFixture.alive?(fixture)
    restarted = start_supervised!({RuntimeFixture, data_dir: dir}, id: :restarted)
    next = RuntimeFixture.ready(restarted)
    refute ready.os_pid == next.os_pid
    assert RuntimeFixture.control(restarted, %{"op" => "store_snapshot"}) == before
    assert before["meta"]["generation"] == 1
    assert before["first"] == %{"value" => 42}
    assert before["second"] == %{"paired" => true}
  end

  defp assert_os_dead(_pid, 0), do: flunk("fixture left an OS process alive")

  defp assert_os_dead(pid, attempts) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} ->
        Process.sleep(10)
        assert_os_dead(pid, attempts - 1)

      {_output, _exited} ->
        :ok
    end
  end
end
