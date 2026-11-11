defmodule ElixirMixir.MCP.Config do
  @moduledoc "Validated configuration for the IPv4 loopback MCP listener."

  @type t :: %{enabled: boolean(), ip: :inet.ip4_address(), port: :inet.port_number()}

  @doc "Builds listener settings, rejecting unknown keys and non-loopback binding. Port zero is ephemeral."
  @spec new(keyword()) :: t()
  def new(opts) do
    settings = Map.new(opts)
    config = Map.merge(%{enabled: true, ip: {127, 0, 0, 1}, port: 4100}, settings)

    unless Map.keys(settings) -- [:enabled, :ip, :port] == [] and
             is_boolean(config.enabled) and config.ip == {127, 0, 0, 1} and
             is_integer(config.port) and config.port in 0..65_535 do
      raise ArgumentError, "MCP requires a loopback address, valid port and known options"
    end

    config
  end
end
