import Config

if port = System.get_env("ELIXIR_MIXIR_PORT") do
  config :elixir_mixir, :mcp, enabled: true, ip: {127, 0, 0, 1}, port: String.to_integer(port)
end

if config_env() != :test and System.get_env("ELIXIR_MIXIR_DATA_DIR") do
  data_dir = System.fetch_env!("ELIXIR_MIXIR_DATA_DIR")
  config :elixir_mixir, :storage, mode: :durable, data_dir: data_dir
end
