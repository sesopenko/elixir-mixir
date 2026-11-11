# elixir-mixir

An experimental Elixir/OTP runtime for creating and evolving a live application
through MCP. See the [architecture](docs/adr/001-architecture.md) for the design
and phased implementation plan.

The repository currently contains a supervised Mix application, a hello-world
function, ExUnit tests, and development quality tooling. The supervision tree is
empty; MCP endpoints, dynamic workers, and persistence are not implemented yet.

See [CONTRIBUTING.md](CONTRIBUTING.md) for environment setup, running the
application, tests, and the required `mix check` quality gate.
