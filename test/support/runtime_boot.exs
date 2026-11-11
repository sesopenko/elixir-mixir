# Loaded only in an independent integration fixture BEAM, never production.
Application.put_env(:hermes_mcp, :log, false)
Application.put_env(:elixir_mixir, :mcp, enabled: true, ip: {127, 0, 0, 1}, port: 0)
Application.put_env(:logger, :level, :warning)
Application.ensure_all_started(:elixir_mixir)
{:ok, {{127, 0, 0, 1}, port}} = ElixirMixir.MCP.Supervisor.address()
IO.puts("MIXIR_READY:#{port}:#{System.pid()}")

# Closing the owning OS port closes stdin; shutdown is reliable even on test failure.
case IO.gets("") do
  _stop_or_eof -> System.halt(0)
end
