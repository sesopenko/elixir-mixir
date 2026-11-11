# Retain a local application across restart

This Linux Docker workflow keeps generated implementations, worker definitions,
committed state and pending work in a named volume. Recovery runs without a client.
The automated production-release smoke test below verifies this deployment; the
[actual Codex restart demonstration](../examples/phase_2_recovery.md) records two
client sessions around a disconnected SIGKILL and automatic timer recovery.

Use a disposable Linux environment without credentials or valuable infrastructure.
Generated code has the privileges of the Erlang VM. The container uses host
networking for its IPv4 loopback listener, which also permits outbound access.
For other host platforms, use a disposable Linux VM. Docker and either a working
Codex CLI or an HTTP MCP client must be installed on that machine.

## Build and start

Run from the repository root on the Linux Docker host:

```sh
docker build -t elixir-mixir:phase02 .
docker volume create elixir-mixir-phase02-data
docker run -d --name elixir-mixir-phase02 --network host --read-only --tmpfs /tmp:rw,noexec,nosuid,size=128m --cap-drop ALL --security-opt no-new-privileges --memory 512m --cpus 1 --pids-limit 128 --mount type=volume,source=elixir-mixir-phase02-data,target=/data --env ELIXIR_MIXIR_DATA_DIR=/data elixir-mixir:phase02
curl --fail --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:4100/health
```

Creating an existing named volume reuses it. Keep one runtime per volume; two VMs
must never share a live store. The image prepares `/data` for UID/GID 1000, so an
empty named volume receives the correct ownership without a root startup process
or host-directory permissions changes. The application tree is root-owned and
read-only. Temporary release/configuration/crash files use the separate `/tmp`
tmpfs. No source directory, credentials or Docker socket is mounted.

Wait for health to return `"status":"ready"` before connecting. Startup validates
and recompiles retained code, reconstructs healthy routes and queue accounting,
and then resumes work. Quarantines can coexist with readiness; inspect their
[diagnostics and repair guidance](runtime-api.md#recovery-diagnostics-and-repair).
An invalid/unwritable directory, incompatible global format or capacity overflow
prevents readiness and never falls back to memory.

Port 4100 must be free. To use 4101, add `--env ELIXIR_MIXIR_PORT=4101` to both
container launches in this document and change every health and MCP URL to 4101.
Do not publish a non-loopback listener to solve networking issues.

## Connect and create an application

In another terminal on that same host:

```sh
codex mcp add elixir-mixir --url http://127.0.0.1:4100/mcp
codex mcp list
codex
```

Skip registration if the matching URL is already registered. Follow the concrete
[counter, replacement and scheduling prompts](../README.md#try-durable-worker-definitions).
Inspect existing workers first: a reused volume can already contain those IDs.
Confirm actual state, selected implementations and pending work before disconnecting.
The build agent edits kernel source; the experiment creates behavior through MCP.

Claude Code is untested with this project, but should theoretically work through
HTTP MCP. The same readiness wait and port apply:

```sh
claude mcp add --transport http elixir-mixir http://127.0.0.1:4100/mcp
claude mcp list
claude
```

Skip existing registration and start a fresh client session. The [README client
sections](../README.md#try-it-with-codex) and [contributor connection guidance](../CONTRIBUTING.md#connect-claude-code-untested)
retain the official syntax sources and the distinction between verified Codex
behavior and expected Claude compatibility. The automated smoke client below is
not an actual Codex or Claude session.

## Kill and recreate the owned runtime

Disconnect the client first. In the runtime terminal, abruptly terminate only the
container created above, verify the OS exit, and remove its stopped container:

```sh
docker kill --signal KILL elixir-mixir-phase02
docker inspect --format '{{.State.ExitCode}}' elixir-mixir-phase02
docker rm elixir-mixir-phase02
```

The exit code should be 137. Recreate it with the same volume and options:

```sh
docker run -d --name elixir-mixir-phase02 --network host --read-only --tmpfs /tmp:rw,noexec,nosuid,size=128m --cap-drop ALL --security-opt no-new-privileges --memory 512m --cpus 1 --pids-limit 128 --mount type=volume,source=elixir-mixir-phase02-data,target=/data --env ELIXIR_MIXIR_DATA_DIR=/data elixir-mixir:phase02
curl --fail --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:4100/health
```

Recovery needs no client connection. Start a fresh Codex/HTTP MCP session afterward;
old MCP session IDs do not survive. Inspect restored logical IDs, selected artifact,
state and revisions, then invoke another event. Boot ID changes, while lineage and
committed state remain with the volume. Printed PID/module strings in historical
request replies are diagnostics, so use current inspection for live information.

Schedules keep their original absolute UTC deadlines. Overdue work becomes eligible
after healthy routing is restored. Internal delivery consumes its ID with target
state and children atomically; stale wakeups cannot repeat that transition. Logs
can repeat if interrupted between output and completion. Direct generated-code IO
is outside kernel transactions. External request replay expires after its bounded
retention interval, including downtime; reusing an expired caller key can run again.

## Stop normally or deliberately discard data

Normal shutdown and container removal retain the volume. Allow 30 seconds so
the listener can finish its 15-second connection drain, including MCP event streams:

```sh
docker stop --time 30 elixir-mixir-phase02
docker rm elixir-mixir-phase02
```

Do not remove the volume when preserving an experiment. Only when you deliberately
want to discard every stored artifact, definition, state, outcome and pending item:

```sh
docker volume rm elixir-mixir-phase02-data
```

The [default memory-mode workflow](../README.md#try-it-with-codex) remains available:
omit both the data mount and `ELIXIR_MIXIR_DATA_DIR`. It loses the generated
application when the runtime exits. A client disconnect alone does not stop either
mode. Retain and back up a durable volume according to its host's storage lifetime;
this test establishes abrupt process recovery, not machine power-loss certification.

## Automated production-release smoke test

Python 3 and Docker are required for this explicit deployment check. Ordinary
`mix test` does not require Docker. After the build above:

```sh
python3 scripts/smoke-phase02-release.py --image elixir-mixir:phase02 --output /tmp/elixir-mixir-release-smoke.json
```

The script creates uniquely named containers and an otherwise empty named volume.
It verifies UID 1000, root-owned immutable application files, writable `/data`,
absence of test/generated modules and source/credential mounts, loopback readiness
on a chosen port, and real HTTP define/start/invoke to count 10. It disconnects,
sends SIGKILL, verifies exit 137 without OOM termination, recreates the release with
the same volume, verifies a different boot/OS process and fresh MCP session, checks
restored state/revision/lineage, and invokes to 12. Normal stop with an open SSE stream uses a 30-second deadline and exits zero. A separate
unwritable `/app` storage path must fail startup. The JSON report records the image
ID, exact Docker commands and observed assertions.

Only its own containers are removed automatically. The script prints its retained
volume name, including after a failure; it never deletes volumes. That populated
smoke volume is separate from the empty volume reserved for the actual Codex demo.
For deliberate smoke-data cleanup, review the printed name and run
`docker volume rm <printed-smoke-volume>` yourself. Committed execution evidence is
in the [Phase 2 verification record](sdlc/phase02-restart/verification.md#release-storage).
