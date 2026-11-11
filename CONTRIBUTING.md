# Contributing

## Development environment

The initial supported baseline is Elixir 1.18.3 and Erlang/OTP 27. The Mix project
requires Elixir `~> 1.18`. On Debian/Ubuntu, install the prerequisites:

```sh
sudo apt update
sudo apt install git elixir erlang-dev build-essential erlang-dialyzer
```

Distribution package versions vary. Check that your installed versions match the
baseline before developing:

```sh
elixir --version
mix --version
```

From the repository root, install Hex and fetch the locked dependencies:

```sh
mix local.hex --force
mix deps.get
./scripts/install-git-hooks.sh
```

Credo, Dialyxir, and Doctor are development/test tools and do not run as production
application dependencies. Commit `mix.lock` when changing dependencies. No
database, container, credentials, or external services are needed for this
bootstrap.

## Run the application

```sh
mix compile --warnings-as-errors
mix run -e 'IO.inspect(ElixirMixir.hello())'
iex -S mix
```

The greeting command prints `:world`. In IEx, call `ElixirMixir.hello()` or inspect
the supervision tree with
`Supervisor.which_children(ElixirMixir.Supervisor)`. Exit IEx with Ctrl+C twice.

To keep the OTP application running without an interactive shell:

```sh
mix run --no-halt
```

Stop it with Ctrl+C twice. The application starts the in-memory runtime Manager
and the loopback MCP endpoint at `http://127.0.0.1:4100/mcp`. Kernel development happens in this repository;
future demonstrations will create application behavior through MCP, as described
in [the architecture](docs/adr/001-architecture.md).

Readiness: `curl --fail http://127.0.0.1:4100/health`. Connect from a separate
terminal using the commands in [README](README.md). Client disconnects do not stop
the BEAM. `runtime_inspect`, `runtime_define`, `runtime_start`, `runtime_stop` and
`runtime_invoke`, `runtime_events` and `runtime_replace` exist at this checkpoint; see the
[runtime API](docs/runtime-api.md) for headers, schemas and size limits.

The default configuration enables MCP outside tests. `ELIXIR_MIXIR_PORT=4101 mix
run --no-halt` changes the runtime port; use the same port for health and clients.
Only IPv4 loopback is accepted. A bind failure prevents MCP startup. Host and
optional Origin must name the configured loopback port. Hermes payload logging is
disabled. For generated-code experiments use a disposable, trusted Linux VM
without credentials or valuable infrastructure; the runtime is not an Elixir sandbox.

Ordinary unit-test startup has no HTTP listener. The integration suite launches
independent BEAMs with ephemeral loopback ports, using the compiled test application.
Its reusable OTP HTTP/SSE client uses `:inets` only in the test environment.
Fixtures own OS-port cleanup even on test failure; production compilation excludes
all `test/support` modules and the test-only boot script.

```sh
mix test test/mcp test/integration --warnings-as-errors
```

## In-memory runtime foundation

Inspect the current runtime in IEx:

```elixir
ElixirMixir.Runtime.Manager.inspect_runtime(%{})
```

The result includes API version `"1"`, generation zero on startup (advancing on committed mutations/lifecycle changes),
health, worker summaries and resource/ledger retention limits. Use worker_id and
detail state for committed state. Artifacts can be defined and workers started/stopped;
invocation commits bounded atomic transitions; automatic recovery and asynchronous emit/schedule/log effects are bounded per worker and runtime. Definitions and request outcomes will
remain in memory only; stopping the BEAM loses them.

Configure downward resource overrides before starting the application, for example
in `config/config.exs`:

```elixir
config :elixir_mixir, :limits, %{ledger_entries: 128, ledger_retention_ms: 60_000}
```

The complete set of names and ceilings is returned by `ElixirMixir.Runtime.Limits.defaults/0`. Unknown names,
non-integers, non-positive values, and values above Phase 1 ceilings fail startup.
`page_default` must not exceed `page_max`. `response_bytes` must be at least 1,024 to
permit a bounded error envelope. Tests can start an isolated Manager with `limits:`
and an injected monotonic millisecond `clock:`.

The kernel coordinator serializes operations and reserves request IDs. Identical
validated operation arguments replay the recorded success or failure; changing
arguments or operation under the same ID returns `REQUEST_ID_CONFLICT`. Pending
entries never expire. Completed results expire after the retention window measured
from completion; retrying an expired ID may run the operation again. A full ledger
returns `BUSY` rather than evicting retained outcomes. Caller disconnect leaves an
accepted operation running. Read operations, failures and replay do not advance
generation; successful kernel mutations advance it once. The internal mutation
callback is trusted kernel code and must stage and preflight changes before commit.
It is never an interface for executing generated behavior.

## Tests

ExUnit runs unit tests and doctests. The bootstrap tests the `:world` greeting and
application supervisor startup.

```sh
mix test
mix test test/elixir_mixir_test.exs
mix test test/elixir_mixir_test.exs:5
mix test --cover
```

The `file:line` form selects the test at that line; adjust the line number as the
file changes. Coverage reports are written to the ignored `cover/` directory.

## Code quality

Run the required gate before submitting changes:

```sh
mix check
```

The alias uses the test environment and stops on a failed check. It checks
formatting, compiles with warnings treated as errors, runs strict Credo and
Doctor, runs ExUnit with warnings treated as errors, and runs Dialyzer.

Individual commands are available for faster feedback:

| Task | Command |
| --- | --- |
| Apply formatting | `mix format` |
| Check formatting without edits | `mix format --check-formatted` |
| Compile without warnings | `mix compile --warnings-as-errors` |
| Check style and consistency | `mix credo --strict` |
| Check documentation and typespec coverage | `mix doctor --raise` |
| Run tests without warnings | `mix test --warnings-as-errors` |
| Analyze types | `MIX_ENV=test mix dialyzer` |
| Explain a Dialyzer warning | `mix dialyzer.explain WARNING_NAME` |

[Doctor](https://doctor.hexdocs.pm/readme.html) enforces 100% module documentation,
function documentation, and typespec coverage through `.doctor.exs`. Document
exceptions and provide a `t()` typespec for structs. Do not lower thresholds or
exclude modules to pass the gate.

Dialyzer uses inferred types and `@spec` annotations to find type mismatches and
impossible calls. It complements tests; a clean analysis does not prove every
input is safe. Its first run builds Persistent Lookup Tables (PLTs), which can
take several minutes. Later runs reuse the caches under ignored
`_build/dialyzer/`. Runtime upgrades and dependency changes can require rebuilding
or updating them. Do not commit PLTs or suppress findings to pass the gate.

Use idiomatic Elixir naming, focused modules, documented public APIs, accurate
typespecs, and focused behavior tests. See the
[code-quality rules](rules/30-code-quality.md). For unexpected results, follow the
[root-cause rule](rules/00-root-cause.md): prove the cause with a test before
fixing the system, and stop and ask the user after three unsuccessful attempts.

## Git hooks

Install the project hooks once per clone with `./scripts/install-git-hooks.sh`.
The installer sets the repository-local `core.hooksPath` to `.githooks`, so the
tracked hook stays up to date as you pull changes. Reinstalling is safe; the
installer refuses to replace a different configured hook directory.

The pre-commit hook runs the complete `mix check` gate in the test environment.
A failed check prevents the commit. It checks the current working tree, so stage
the intended, verified changes before committing. Dependencies and system
prerequisites must be installed first; the hook does not install them for you.

To uninstall this hook configuration, run this from the repository root:

```sh
git config --local --unset core.hooksPath
```

Any globally configured hooks then apply again.

## Agent instructions

Work in small, independently reviewable subtasks. Finish the unit tests for a
subtask and get them passing, then run the full `mix check` gate. Commit that
working state before beginning the next subtask so changes are easy to roll
back. Do not move on with unfinished tests, failing gates, or an uncommitted
completed subtask. See the [subtask workflow rules](rules/50-subtask-workflow.md)
and [commit-message rules](rules/40-commit-messages.md).

Project instructions live in separate `rules/*.md` files. Their numeric filename
prefixes determine the order of the generated `AGENTS.md`.

After changing any rule, run:

```sh
./scripts/build-agent-rules.sh
```

Include the regenerated `AGENTS.md` with the rule changes. Do not edit it
directly.

## Production release and disposable demonstration

The [Dockerfile](Dockerfile) uses a digest-pinned official Elixir 1.18.3/OTP 27
image, installs the builder CA store, fetches only production dependencies and
builds an OTP release. Its build context is a whitelist of mix.exs/mix.lock,
config/, lib/ and rel/; Git, tests, credentials and local experiments are excluded.
No build credentials or host files are copied into the runtime stage.

The [release environment](rel/env.sh.eex) disables distribution and directs release
temporary/crash files to /tmp. Fixed thread counts fit the 128-PID cap. A 65,536
port ceiling avoids OTP 27 allocating a multi-gigabyte port table when Docker
supplies a billion-file-descriptor limit. This is a VM startup resource setting,
not a change to the runtime's worker/event API limits.

Use the exact build/run/cleanup commands in [README](README.md) and follow the
[actual Codex demonstration](examples/phase_1_demo.md). Keep runtime and Codex
processes separate. Do not mount client auth, source directories or Docker sockets
inside the generated-code container. Linux host networking exposes only the
configured loopback listener but permits outbound/network access; a disposable
Linux VM is the stronger isolation and non-Linux alternative.

## MCP connection troubleshooting

- Start the runtime first and wait for GET /health. If port 4100 is occupied, use
  ELIXIR_MIXIR_PORT=4101 for Mix, or add --env ELIXIR_MIXIR_PORT=4101 to docker run;
  register the matching http://127.0.0.1:4101/mcp URL. Runtime code rejects non-loopback
  bind settings. Do not solve container reachability by binding 0.0.0.0.
- Use /mcp, not a legacy /sse URL. MCP POST needs application/json Content-Type and
  Accept application/json, text/event-stream. Codex negotiates this automatically.
- Host and optional Origin must match localhost/127.0.0.1 and the configured port.
  Browsers/proxies adding a different Origin or duplicate headers are rejected.
- Initialize a new session and retain its mcp-session-id. Do not reuse a previous
  BEAM's session header after restart. Closing a client/session does not stop workers.
- Allow at least the seven-second operation wait in client tool timeouts; compilation
  may consume its five-second deadline. Reuse the identical mutation request_id after
  an uncertain response so an accepted operation replays instead of running twice.
- isError true is a tool/runtime failure with a stable code, distinct from transport
  JSON-RPC errors. Inspect actual state and read runtime_events rather than assuming
  an accepted effect was delivered or a failed mutation changed state.
- Phase 1 stores everything in memory. Host crash recovery reruns init and loses
  that worker's volatile state; BEAM/container restart loses the complete application.
  Client reconnect alone preserves it.
