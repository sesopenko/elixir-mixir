# Loaded only in an independent integration fixture BEAM, never production.
Application.put_env(:hermes_mcp, :log, false)
Application.put_env(:elixir_mixir, :mcp, enabled: true, ip: {127, 0, 0, 1}, port: 0)
Application.put_env(:logger, :level, :warning)

opts = System.argv() |> List.first("{}") |> Jason.decode!()

Process.sleep(Map.get(opts, "startup_delay_ms", 0))

Application.put_env(
  :elixir_mixir,
  :storage,
  if(opts["data_dir"], do: [mode: :durable, data_dir: opts["data_dir"]], else: [mode: :memory])
)

known =
  Map.new(ElixirMixir.Runtime.Limits.defaults(), fn {key, _} -> {Atom.to_string(key), key} end)

limits =
  Map.new(Map.get(opts, "limits", %{}), fn {key, value} -> {Map.fetch!(known, key), value} end)

Application.put_env(:elixir_mixir, :limits, limits)
Application.put_env(:elixir_mixir, :test_recovery_pause, Map.get(opts, "pause_recovery", false))

if opts["pause_delivery"] do
  Application.put_env(:elixir_mixir, :manager,
    delivery_timer: fn _message, _delay -> make_ref() end
  )
end

{:ok, _barrier} = ElixirMixir.TestSupport.CallbackBarrier.start_link([])
{:ok, _} = Application.ensure_all_started(:elixir_mixir)
{:ok, {{127, 0, 0, 1}, port}} = ElixirMixir.MCP.Supervisor.address()
IO.puts("MIXIR_READY:#{port}:#{System.pid()}")
ElixirMixir.TestSupport.RuntimeControl.run()
