# elixir-mixir

An experimental Elixir/OTP runtime for creating and evolving a live application
through MCP. The current checkpoint exposes runtime inspection and bounded generated-artifact
compilation and supervised worker start/invoke/inspect/stop over localhost HTTP, backed by
an in-memory Manager and request ledger. Live replacement retains the host PID and
compatible state, with explicit migration for schema changes. Persistence is a later phase.

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
`runtime_events`, `runtime_replace` and `runtime_stop`. Inspect reads state and paginated topology;
events reads correlated lifecycle/effect history with sequence cursors and eviction gaps.
Replace requires the current worker revision from inspection. See the
[seven tool argument examples](docs/runtime-api.md#tool-argument-examples).
Define compiles an inactive artifact; start runs its bounded init in a supervised
logical worker; invoke commits bounded reply/state transitions and admits asynchronous
emit, schedule and structured log effects.
Host crashes reinitialize within three attempts per rolling ten seconds; exhausted workers require explicit start. Closing and restarting
Codex leaves the BEAM running; Ctrl+C twice in the runtime terminal stops it.
The endpoint is an independently running service. Override its port with
`ELIXIR_MIXIR_PORT=4101 mix run --no-halt` and use the same port in client commands.

For generated-code experiments, use the disposable Linux release container instead
of running generated code on a valuable host:

```sh
docker build -t elixir-mixir:phase01 .
docker run -d --name elixir-mixir-phase01 --network host --read-only --tmpfs /tmp:rw,noexec,nosuid,size=128m --cap-drop ALL --security-opt no-new-privileges --memory 512m --cpus 1 --pids-limit 128 elixir-mixir:phase01
curl --fail http://127.0.0.1:4100/health
```

The image pins official Elixir 1.18.3/OTP 27, builds dependencies and an OTP release
before startup, runs as UID/GID 1000 and disables distribution. Its release uses
/tmp and bounded VM threads/ports, with no runtime Mix/dependency downloads.
No host credentials, source directories or Docker socket are mounted. Linux host
networking makes the loopback listener reachable; it permits network access and
is not a network sandbox. Use a disposable Linux VM for stronger isolation or
non-Linux hosts. Generated Elixir has BEAM privileges; callback limits are not a
hostile-code sandbox.

Follow the [two-session Codex demonstration](examples/phase_1_demo.md) to create and
evolve the counter/aggregator exclusively through MCP, then reconnect to the same
living application. Kernel source contains no seeded domain workers. Stop/remove
only the disposable demo container when finished:

```sh
docker rm -f elixir-mixir-phase01
```

Client disconnect leaves runtime state alive. A BEAM/container restart loses all
Phase 1 artifacts, workers, state, effects, history and request outcomes.

See the [runtime API](docs/runtime-api.md), [automated evidence](docs/sdlc/phase01/verification.md),
and [architecture entry point](ARCHITECTURE.md). Run `mix check` before committing.
