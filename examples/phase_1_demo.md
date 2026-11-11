# Phase 1 — Live Genesis through actual Codex MCP sessions

This experiment uses a fresh, independently running runtime and two separate
Codex CLI processes. Application behavior is generated exclusively through the
seven MCP tools. Automated ExUnit HTTP checks are separate evidence; they do not
establish that Codex performed the experiment.

## Disposable runtime

On a disposable Linux machine with Docker, from the repository root:

```sh
docker build -t elixir-mixir:phase01 .
docker run -d --name elixir-mixir-phase01 --network host --read-only --tmpfs /tmp:rw,noexec,nosuid,size=128m --cap-drop ALL --security-opt no-new-privileges --memory 512m --cpus 1 --pids-limit 128 elixir-mixir:phase01
curl --fail http://127.0.0.1:4100/health
```

The official Elixir 1.18.3/OTP 27 image is pinned by multi-platform manifest digest
in Dockerfile. Dependency downloads and release assembly happen at build time.
The runtime starts bin/elixir_mixir, runs as UID/GID 1000, disables distribution,
and needs no host source/credential/socket mounts. Its root filesystem is
read-only; only tmpfs is writable. Release startup caps threads and the VM port
table, keeping the documented 512 MiB/128-PID budget even when Docker supplies a
billion-FD limit. See [the architecture entry point](../ARCHITECTURE.md).

Use host networking on Linux because the listener binds 127.0.0.1. Port publishing
cannot expose a container-loopback-only listener. Host networking permits network
access; it is not a network sandbox. A disposable Linux VM without credentials or
valuable infrastructure is the alternative for stronger isolation or non-Linux
hosts. Codex credentials remain on the separate client host, outside the runtime.

Verify container settings and the host loopback listener:

```sh
docker inspect elixir-mixir-phase01
ss -ltn '( sport = :4100 )'
```

The container must have no bind mounts, user 1000:1000, read-only root, tmpfs,
CapDrop ALL, no-new-privileges, memory 536870912, NanoCpus 1000000000, PidsLimit 128
and host networking. A host listener must be 127.0.0.1:4100. Readiness is not proof
of the domain demonstration; the first MCP snapshot must have generation 0 and
no workers.

## Session 1: construct and evolve

Register the already-running endpoint, keeping the runtime independent:

```sh
codex mcp add elixir-mixir --url http://127.0.0.1:4100/mcp
codex mcp list
codex
```

Paste the complete [session 1 prompt](../docs/prompts/phase01-demo-session01.md).
It specifies callbacks, exact effect shapes, bounds, request IDs and every assertion.
Do not let the runtime agent edit kernel/fixture files or use direct HTTP/Manager
calls to create behavior. Poll MCP inspection/history for asynchronous delivery.

The required arithmetic and evolution are:

| Stage | Counter value | Aggregate events | Aggregate total | Required observation |
| --- | --- | --- | --- | --- |
| v1, one increment | 1 | — | — | Original counter PID and schema 1 |
| Start aggregate | 1 | 0 | 0 | Second supervised logical worker |
| Replace v2, two increments | 3 | 2 | 5 | Same counter PID/state; emits new count |
| Replace v3, amount 4 | 7 | 3 | 12 | Same PID; positive amount behavior |
| Reject amount 0 and -1 | 7 | 3 | 12 | No state/artifact/PID/revision change |
| Migrate v4, schema 2 | 7 | 3 | 12 | Explicit nested versioned state, same PID |
| Reject bad source/migrate/stale revision | 7 | 3 | 12 | Inspect unchanged active fields after each |

Define a separate probe for structured logging and a delayed self-event; observe
one tick and correlated history, then stop probe. This must not alter counter or
aggregate arithmetic. Leave counter and aggregate alive, no pending deliveries,
and record final snapshots/artifact hashes/revisions. All seven tools are exercised.

For a machine-readable actual CLI transcript, installed Codex versions supporting
exec can run the same prompt noninteractively from a separate empty client directory:

```sh
mkdir -p /tmp/elixir-mixir-demo-client
codex exec --ignore-user-config --ephemeral --sandbox read-only --skip-git-repo-check --cd /tmp/elixir-mixir-demo-client --json --config 'mcp_servers.elixir_mixir={url="http://127.0.0.1:4100/mcp",required=true,default_tools_approval_mode="approve",startup_timeout_sec=15,tool_timeout_sec=15}' --output-last-message /tmp/elixir-mixir-session01-final.json - < docs/prompts/phase01-demo-session01.md > /tmp/elixir-mixir-session01.jsonl
```

This inline configuration applies only to this invocation; it allows the expressly
requested local runtime mutations and does not grant shell write access. CLI auth
stays on the client. `--json` captures actual MCP calls/results; `--ephemeral` avoids
persisting a resumable client session. See official
[Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) and
[noninteractive JSONL output](https://learn.chatgpt.com/docs/non-interactive-mode).

## Session 2: a fresh client

Exit the first Codex process entirely. Do not stop or restart the container. Record
container ID, host PID and StartedAt so continuous BEAM lifetime can be checked.
Launch a NEW Codex process rather than resuming/forking the old thread:

```sh
codex
```

Paste the [session 2 prompt](../docs/prompts/phase01-demo-session02.md) and the first
session's final checkpoint as expected data. Only runtime_inspect/runtime_events
are allowed in this session. Inspect actual state/PIDs/artifacts/revisions and
history; compare to the checkpoint. Counter must retain value 7/schema 2, aggregate
must retain events 3/total 12, and generation must stay fixed across reconnect/reads.
For exec capture, concatenate the prompt and prior checkpoint on stdin and use a
new process with only the read tools enabled:

```sh
cat docs/prompts/phase01-demo-session02.md /tmp/elixir-mixir-session01-final.json | codex exec --ignore-user-config --ephemeral --sandbox read-only --skip-git-repo-check --cd /tmp/elixir-mixir-demo-client --json --config 'mcp_servers.elixir_mixir={url="http://127.0.0.1:4100/mcp",required=true,default_tools_approval_mode="approve",enabled_tools=["runtime_inspect","runtime_events"],startup_timeout_sec=15,tool_timeout_sec=15}' --output-last-message /tmp/elixir-mixir-session02-final.json - > /tmp/elixir-mixir-session02.jsonl
```

Do not use exec resume. The recorded run supplied the same prompt/checkpoint through
a temporary stdin file rather than a pipe.

## Evidence and cleanup

Keep sanitized MCP tool calls/results from both actual CLI processes, their distinct
thread IDs, client/runtime versions, exact container configuration/identity before
and after reconnect, artifact hashes/revisions, final snapshots and all error
assertions. Never include auth files, tokens, cookies or unrelated MCP settings.
A valid transcript contains calls, not just a final narrative claiming success.
Record evidence separately from automated tests in
[verification.md](../docs/sdlc/phase01/verification.md).

After reconnect evidence is captured, stop/remove only this disposable container:

```sh
docker rm -f elixir-mixir-phase01
```

Removing/restarting the BEAM loses this entire in-memory application. Rebuild a
fresh empty runtime to repeat the experiment; do not seed it from fixture modules.

## Recorded actual run

The 2026-11-11 run completed two distinct Codex CLI 0.167.1 processes: 51 MCP calls
creating/evolving the application, then 8 read-only MCP calls from a fresh client.
Both retained original counter/aggregate PIDs, state, artifacts and generation 23.
The sanitized calls, checkpoints, source hashes, versions and container identity
are under [evidence/](../docs/sdlc/phase01/evidence/codex-sessions.json). Duplicate
text content was verified equal to structured content before omission; prompts,
MCP arguments/results and intentional runtime failures remain visible. Authentication,
unrelated settings, agent narration and stderr are excluded.

Audit the recorded observations without starting any runtime:

```sh
python3 scripts/verify-phase01-demo.py
```

The verifier checks source hashes, all seven tools, exact arithmetic, rejected
mutations preserving active state, distinct threads, fresh-client identity/state/
generation equality and container isolation/cleanup. Automated host-kill/restart
coverage remains in the separate ExUnit evidence; the actual demo does not expose
an eighth process-control tool. Full details and acceptance mapping are in the
[verification record](../docs/sdlc/phase01/verification.md#codex-demo).
