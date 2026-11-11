# elixir-mixir

elixir-mixir lets a coding agent build and change a running application through
conversation. Ask Codex to create a counter, connect it to another worker, or change
how it handles input. The agent writes Elixir code and sends it to a local runtime,
where you can inspect the results as the application runs.

You can change a worker's behavior while it keeps running and retains its state.
A counter can learn to send updates to an
aggregator without losing its count. Close Codex, open a fresh session, and the
application is still there for the next agent to inspect and work on.

This is an experimental project for exploring how agents can evolve software that
is already running. It's useful for trying small event-driven systems, testing
changes against live state, and studying what an agent needs to understand before
changing an application.

## How it works

The runtime runs separately from Codex on Erlang's virtual machine, called the BEAM.
It uses Elixir and Erlang's supervision libraries to manage running processes.
Each **worker** is a process with its own state and behavior. Workers can
receive events, send events to other workers, schedule a later event, and write logs.

Codex connects through the Model Context Protocol (MCP), a way for agents to call
tools provided by another program. The tools let it define and compile behavior,
start workers, send events, inspect state and history, replace behavior, and stop
workers. The runtime starts empty; the agent creates the application through those
tools.

A replacement can preserve the worker's process and state. When a change needs a
different state structure, the agent supplies an explicit migration. Failed
compilation or migration leaves the active implementation in place. The runtime
also limits code execution time and worker restarts so you can inspect failures
and continue experimenting.

## Try it with Codex

You'll need a Linux machine with Docker and a working Codex CLI installation.
Clone this repository and run the following from its root. Use a disposable
environment without secrets or valuable infrastructure: generated code runs with
the privileges of the Erlang VM.

Build and start the runtime, then wait for it to be ready:

```sh
docker build -t elixir-mixir:phase01 .
docker run -d --name elixir-mixir-phase01 --network host --read-only --tmpfs /tmp:rw,noexec,nosuid,size=128m --cap-drop ALL --security-opt no-new-privileges --memory 512m --cpus 1 --pids-limit 128 elixir-mixir:phase01
curl --fail --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:4100/health
```

Readiness returns `"status":"ready"`. Connect Codex on the same machine:

```sh
codex mcp add elixir-mixir --url http://127.0.0.1:4100/mcp
codex mcp list
codex
```

If you've already registered this URL, skip `codex mcp add` and start a fresh Codex
session. Keep the container running while you try the prompts below. If startup or
connection fails, see [connection troubleshooting](CONTRIBUTING.md#mcp-connection-troubleshooting).

The container runs as a nonroot user with a read-only filesystem, temporary scratch
space, and memory, CPU and process limits. It mounts no host directories or Docker
socket. Its Linux host networking makes the local endpoint reachable but also
allows network access. These settings do not make generated code safe to run
against secrets. For non-Linux hosts or stronger isolation, use a disposable Linux VM.

To develop the runtime itself, follow [CONTRIBUTING.md](CONTRIBUTING.md) and start
the runtime in a separate terminal with `mix run --no-halt`. Use this as an
alternative to Docker; both use port 4100 by default. Set
`ELIXIR_MIXIR_PORT=4101 mix run --no-halt` to choose another port, and use that port
in the readiness and MCP connection commands too.

## Example prompts

Try these in order in Codex. They ask the agent to use the running application's
tools, so you can see state change without editing the runtime's source code. The
`demo_` names keep the examples separate from other experiments; the first prompt
asks the agent to check for existing workers.

Start with one worker:

> Use the elixir-mixir MCP tools to inspect the runtime. If demo_counter or
> demo_aggregate already exists, report its state and stop instead of changing it.
> Otherwise, define and start demo_counter with count 0. Give it an increment
> event that adds one. Increment it once, inspect its state, and show me its count
> and process ID. Create the behavior through MCP, without editing local files.

Connect two workers:

> Using only the elixir-mixir MCP tools, create demo_aggregate with events 0 and
> total 0. It should receive a value, add it to total, and increment events.
> Update demo_counter so each increment sends its new count to demo_aggregate.
> Preserve the counter's current state and process ID. Increment it twice and
> inspect both workers. Confirm count 3, events 2 and total 5, waiting for the
> events to arrive before reporting the result.

Change the behavior while it runs:

> Using only the elixir-mixir MCP tools, update demo_counter to accept a positive
> integer amount. Keep its state and process ID, then add 4. Confirm count 7 and
> demo_aggregate events 3, total 12 after delivery. Reject zero and negative
> amounts. Try each and inspect the counter to verify its state stayed unchanged.

Then close Codex, leave the container running, and open a fresh session:

> Use the elixir-mixir MCP tools to inspect demo_counter and demo_aggregate without
> changing them. Show their state and process IDs, and read their recent event
> history. Report what the running system tells you; don't recreate the workers.

For a longer experiment with state migration, deliberate failures, logs and delayed
events, follow the [counter and aggregator walkthrough](examples/phase_1_demo.md).
It includes the recorded results from two actual Codex sessions.

## What to expect today

Live replacement and reconnecting from a fresh Codex session are implemented and
tested. Everything lives in memory. Closing Codex leaves the
application running, but restarting the runtime or container loses its workers,
code, state and history. A crashed worker can restart under supervision, but it
starts from its initial state. There is no persistence or autonomous controller yet.

When you're finished, remove the container. This discards the application you built:

```sh
docker rm -f elixir-mixir-phase01
```

## Learn more

- [Runtime API](docs/runtime-api.md): all seven tools, argument examples and limits.
- [Architecture](ARCHITECTURE.md): the kernel design and plans for future phases.
- [Verification](docs/sdlc/phase01/verification.md): automated checks and actual Codex demonstration evidence.
- [Contributing](CONTRIBUTING.md): development setup, troubleshooting and the required `mix check` quality gate.
