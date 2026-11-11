import Config

# Overrides may only reduce the validated Phase 1 resource ceilings.
config :elixir_mixir, :limits, %{}

config :elixir_mixir, :mcp, enabled: config_env() != :test, ip: {127, 0, 0, 1}, port: 4100
config :hermes_mcp, log: false
