defmodule ElixirMixir.Runtime.KernelAPITest do
  use ExUnit.Case, async: true

  alias ElixirMixir.Runtime.Error
  alias ElixirMixir.Runtime.Limits
  alias ElixirMixir.Runtime.Manager
  alias ElixirMixir.Runtime.RequestLedger
  alias ElixirMixir.Runtime.Values

  test "validates every configured limit and rejects unknown or excessive overrides" do
    defaults = Limits.defaults()

    for {key, maximum} <- defaults do
      minimum = if key == :response_bytes, do: 256, else: 1

      overrides =
        if key == :page_max, do: %{page_max: 1, page_default: 1}, else: %{key => minimum}

      assert Limits.new(overrides)[key] == minimum
      assert_raise ArgumentError, fn -> Limits.new(%{key => maximum + 1}) end
      assert_raise ArgumentError, fn -> Limits.new(%{key => 0}) end
      assert_raise ArgumentError, fn -> Limits.new(%{key => -1}) end
      assert_raise ArgumentError, fn -> Limits.new(%{key => 1.5}) end
    end

    assert_raise ArgumentError, fn -> Limits.new(%{unknown: 1}) end
    assert_raise ArgumentError, fn -> Limits.new(%{page_max: 1}) end
  end

  test "rejects response limits too small to encode a bounded error envelope" do
    assert_raise ArgumentError, fn -> Limits.new(%{response_bytes: 1}) end
  end

  test "IDs are nonempty ASCII identifiers of at most 64 bytes" do
    for id <- ["A", "abc-DEF_123", String.duplicate("a", 64)], do: assert(Values.valid_id?(id))

    for id <- [nil, :id, 123, "", "with space", "é", "a\n", String.duplicate("a", 65), <<255>>],
        do: refute(Values.valid_id?(id))
  end

  test "JSON encoding determines exact size limits for each value kind" do
    for kind <- [:config, :event, :state, :reply, :metadata] do
      key =
        Map.fetch!(
          %{
            config: :config_bytes,
            event: :event_bytes,
            state: :state_bytes,
            reply: :reply_bytes,
            metadata: :metadata_bytes
          },
          kind
        )

      value = %{"x" => "é\n"}
      size = byte_size(Jason.encode!(value))
      assert :ok = Values.validate(value, kind, Limits.new(%{key => size}))

      assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
               Values.validate(value, kind, Limits.new(%{key => size - 1}))
    end

    assert :ok = Values.validate("é", :source, Limits.new(%{source_bytes: 2}))

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             Values.validate("éa", :source, Limits.new(%{source_bytes: 2}))
  end

  test "depth bounds include nested values, with roots at depth zero" do
    at_limit = Enum.reduce(1..16, nil, fn _, acc -> [acc] end)
    assert :ok = Values.validate(at_limit, :reply, Limits.defaults())

    assert {:error, %{"code" => "LIMIT_EXCEEDED"}} =
             Values.validate([at_limit], :reply, Limits.defaults())
  end

  test "rejects non-JSON terms, improper lists, invalid keys and invalid UTF-8" do
    for value <- [
          :atom,
          self(),
          make_ref(),
          fn -> :ok end,
          ~D[2026-11-10],
          %{atom: 1},
          %{<<255>> => 1},
          <<255>>,
          [1 | 2],
          %{"x" => {1, 2}}
        ] do
      assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
               Values.validate(value, :reply, Limits.defaults())
    end

    for kind <- [:config, :event, :state, :metadata] do
      assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
               Values.validate([], kind, Limits.defaults())
    end

    assert {:error, %{"code" => "INVALID_ARGUMENT"}} =
             Values.validate(%{}, :source, Limits.defaults())

    assert :ok = Values.validate([nil, true, false, 1, -1, 1.5, %{}], :reply, Limits.defaults())
  end

  test "canonical hashes preserve types and ignore map order and request ID only" do
    args = %{"request_id" => "a", "nested" => %{"b" => 1, "a" => [true, nil]}}
    other = %{"nested" => Map.new([{"a", [true, nil]}, {"b", 1}]), "request_id" => "b"}
    hash = Values.request_hash("invoke", args)
    assert hash == Values.request_hash("invoke", other)
    assert byte_size(hash) == 64
    refute hash == Values.request_hash("start", args)
    refute hash == Values.request_hash("invoke", Map.put(args, "nested", []))
    refute Values.request_hash("x", %{"a" => 1}) == Values.request_hash("x", %{"a" => 1.0})
  end

  test "ledger replays success and error exactly and completes reservations once" do
    for result <- [{:ok, %{"generation" => 1}}, {:error, Error.new("CALLBACK_FAILED")}] do
      ledger = RequestLedger.new(Limits.defaults())
      assert {:admitted, ledger} = RequestLedger.admit(ledger, "a", "hash", 0)
      assert {:pending, ^ledger} = RequestLedger.admit(ledger, "a", "hash", 1)

      assert {:error, %{"code" => "REQUEST_ID_CONFLICT"}, ^ledger} =
               RequestLedger.admit(ledger, "a", "different", 1)

      assert {:ok, ledger} = RequestLedger.complete(ledger, "a", result, 2)
      assert {:error, :not_pending} = RequestLedger.complete(ledger, "a", result, 3)
      assert {:error, :not_pending} = RequestLedger.complete(ledger, "unknown", result, 3)
      assert {:replay, ^result, ^ledger} = RequestLedger.admit(ledger, "a", "hash", 3)
    end
  end

  test "ledger expires completed entries only, measured from completion" do
    ledger = RequestLedger.new(Limits.new(%{ledger_entries: 2, ledger_retention_ms: 10}))
    {:admitted, ledger} = RequestLedger.admit(ledger, "pending", "h", 0)
    {:admitted, ledger} = RequestLedger.admit(ledger, "done", "h", 0)
    {:ok, ledger} = RequestLedger.complete(ledger, "done", {:ok, %{}}, 5)
    assert {:error, %{"code" => "BUSY"}, ^ledger} = RequestLedger.admit(ledger, "third", "h", 14)
    assert {:admitted, ledger} = RequestLedger.admit(ledger, "third", "h", 15)
    assert {:pending, ^ledger} = RequestLedger.admit(ledger, "pending", "h", 999)
    assert map_size(ledger.entries) == 2
  end

  test "empty Manager status is read-only, versioned, and supervised" do
    assert {:ok,
            %{
              "api_version" => "1",
              "generation" => 0,
              "workers" => [],
              "topology" => [],
              "health" => "ok",
              "ledger" => ledger
            }} =
             Manager.inspect_runtime(%{})

    assert ledger == %{"capacity" => 1_024, "retention_ms" => 600_000}

    assert {:error, %{"code" => "INVALID_ARGUMENT", "generation" => 0}} =
             Manager.inspect_runtime(%{"extra" => true})

    assert Enum.any?(Supervisor.which_children(ElixirMixir.Supervisor), fn
             {Manager, pid, :worker, _} -> pid == Process.whereis(Manager)
             _ -> false
           end)
  end

  test "kernel mutation wrapper replays outcomes and advances generation only for success" do
    manager = manager()
    args = %{"request_id" => "one", "value" => 1}
    callback = fn generation -> {:ok, %{"observed" => generation}} end

    assert {:ok, %{"generation" => 1, "request_id" => "one"} = data} =
             Manager.mutate(manager, "test", args, callback)

    assert {:ok, ^data} = Manager.mutate(manager, "test", args, fn _ -> flunk("reexecuted") end)

    for {op, altered} <- [{"different", args}, {"test", Map.put(args, "value", 2)}] do
      assert {:error, %{"code" => "REQUEST_ID_CONFLICT", "generation" => 1}} =
               Manager.mutate(manager, op, altered, callback)
    end

    failure = fn _ -> {:error, Error.new("CALLBACK_FAILED")} end

    assert {:error, %{"generation" => 1} = error} =
             Manager.mutate(manager, "test", %{"request_id" => "two"}, failure)

    assert {:error, ^error} =
             Manager.mutate(manager, "test", %{"request_id" => "two"}, callback)

    assert {:ok, %{"generation" => 1}} = Manager.inspect_runtime(%{}, manager)
  end

  test "concurrent duplicate requests run one kernel operation" do
    manager = manager()
    parent = self()

    callback = fn _ ->
      send(parent, :executed)
      {:ok, %{}}
    end

    tasks =
      for _ <- 1..10,
          do:
            Task.async(fn ->
              Manager.mutate(manager, "test", %{"request_id" => "same"}, callback)
            end)

    results = Enum.map(tasks, &Task.await/1)
    assert length(Enum.uniq(results)) == 1
    assert_receive :executed
    refute_receive :executed
    assert {:ok, %{"generation" => 1}} = Manager.inspect_runtime(%{}, manager)
  end

  test "caller disconnect does not cancel an accepted kernel mutation" do
    manager = manager()
    parent = self()
    args = %{"request_id" => "disconnect"}

    callback = fn _ ->
      send(parent, :accepted)

      receive do
        :finish -> {:ok, %{"committed" => true}}
      after
        1_000 -> flunk("test did not release accepted operation")
      end
    end

    caller = spawn(fn -> Manager.mutate(manager, "test", args, callback) end)
    assert_receive :accepted
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    send(manager, :finish)

    assert {:ok, %{"committed" => true, "generation" => 1}} =
             Manager.mutate(manager, "test", args, fn _ -> flunk("reexecuted") end)
  end

  test "Manager uses injected time for saturation, expiry and retry" do
    clock = start_supervised!({Agent, fn -> 0 end})

    manager =
      manager(
        limits: %{ledger_entries: 1, ledger_retention_ms: 10},
        clock: fn -> Agent.get(clock, & &1) end
      )

    callback = fn _ -> {:ok, %{}} end
    assert {:ok, _} = Manager.mutate(manager, "test", %{"request_id" => "a"}, callback)

    assert {:error, %{"code" => "BUSY", "generation" => 1}} =
             Manager.mutate(manager, "test", %{"request_id" => "b"}, callback)

    Agent.update(clock, fn _ -> 10 end)

    assert {:ok, %{"generation" => 2}} =
             Manager.mutate(manager, "test", %{"request_id" => "a"}, callback)
  end

  test "invalid arguments and oversized staged responses do not advance generation" do
    manager = manager(limits: %{response_bytes: 512})
    callback = fn _ -> flunk("invalid operation executed") end

    for args <- [%{}, %{"request_id" => ""}, %{"request_id" => "ok", "bad" => self()}, nil] do
      assert {:error, %{"code" => "INVALID_ARGUMENT", "generation" => 0}} =
               Manager.mutate(manager, "test", args, callback)
    end

    callback = fn _ -> {:ok, %{"reply" => String.duplicate("x", 513)}} end

    assert {:error, %{"code" => "LIMIT_EXCEEDED", "generation" => 0} = data} =
             Manager.mutate(manager, "test", %{"request_id" => "large"}, callback)

    assert byte_size(Jason.encode!(data)) <= 512
    assert {:error, ^data} = Manager.mutate(manager, "test", %{"request_id" => "large"}, callback)
  end

  defp manager(opts \\ []) do
    start_supervised!({Manager, Keyword.put(opts, :name, nil)})
  end
end
