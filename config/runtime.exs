import Config

if port = System.get_env("ELIXIR_MIXIR_PORT") do
  config :elixir_mixir, :mcp, enabled: true, ip: {127, 0, 0, 1}, port: String.to_integer(port)
end
