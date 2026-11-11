# elixir-mixir

An experimental Elixir/OTP runtime for creating and evolving a live application
through MCP. The current checkpoint exposes runtime inspection and bounded generated-artifact
compilation and supervised worker start/invoke/inspect/stop over localhost HTTP, backed by
an in-memory Manager and request ledger. Replacement is planned
in [Phase 1](docs/sdlc/phase01/plan.md). Persistence is a later phase.

After the setup in [CONTRIBUTING.md](CONTRIBUTING.md), start the runtime in its own
terminal:

```sh
mix run --no-halt
```

Wait for readiness from another terminal:

```sh
curl --fail http://127.0.0.1:4100/health
```

Connect a Codex client on the same machine:

```sh
codex mcp add elixir-mixir --url http://127.0.0.1:4100/mcp
codex mcp list
codex
```

The tools are `runtime_define`, `runtime_start`, `runtime_invoke`, `runtime_inspect`,
`runtime_events` and `runtime_stop`. Inspect reads state and paginated topology;
events reads correlated lifecycle/effect history with sequence cursors and eviction gaps.
Define compiles an inactive artifact; start runs its bounded init in a supervised
logical worker; invoke commits bounded reply/state transitions and admits asynchronous
emit, schedule and structured log effects.
Host crashes reinitialize within three attempts per rolling ten seconds; exhausted workers require explicit start. Closing and restarting
Codex leaves the BEAM running; Ctrl+C twice in the runtime terminal stops it.
The endpoint is an independently running service. Override its port with
`ELIXIR_MIXIR_PORT=4101 mix run --no-halt` and use the same port in client commands.

Generated-code experiments must use a trusted, disposable environment without
credentials or valuable infrastructure. Generated Elixir runs with the
BEAM's privileges; loopback binding and callback limits are not a code sandbox.
The isolated release/container setup and actual Codex demonstration belong to the
final Phase 1 task and remain pending.

See the [runtime API](docs/runtime-api.md), [automated evidence](docs/sdlc/phase01/verification.md),
and [architecture](docs/adr/001-architecture.md). Run `mix check` before committing.
