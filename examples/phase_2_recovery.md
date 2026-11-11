# Durable Genesis through actual Codex sessions

This experiment uses two fresh Codex CLI processes and the isolated production
Docker release. Both clients author application behavior through the seven MCP
tools. An automated read-only observer checks recovery between clients. The
ordinary ExUnit HTTP suite and release smoke are separate evidence.

The [release walkthrough](../docs/phase02-recovery.md) explains the image, named
volume, permissions, readiness, port overrides and explicit volume deletion.
Codex credentials stay on the client host and are never mounted into the runtime.
Claude Code remains untested with this project.

## Reproduce the experiment

From the repository root on a disposable Linux machine with Docker, Python 3 and
a working authenticated Codex CLI:

```sh
mix test test/mcp test/integration --warnings-as-errors
docker build -t elixir-mixir:phase02 .
demo_evidence=$(mktemp -d /tmp/elixir-mixir-phase02-evidence.XXXXXX)
python3 -u scripts/run-phase02-codex-demo.py --evidence-dir "$demo_evidence"
python3 scripts/verify-phase02-demo.py --evidence-dir "$demo_evidence"
```

The driver creates an empty uniquely named volume, chooses an unused loopback
port, verifies the release restrictions and seven-tool catalog, and starts the
first actual CLI process. It uses the preserved [session 1 prompt](../docs/prompts/phase02-demo-session01.md).
Session 2 uses its [original prompt](../docs/prompts/phase02-demo-session02.md) plus
the separately preserved [callback-contract clarification](../docs/prompts/phase02-demo-session02-contract-amendment.md).
No kernel files are edited by either runtime client. Filesystem, shell, direct
HTTP and other tools are excluded from the runtime-agent prompts; transcript
extraction rejects shell/file/web actions or calls to another MCP server.

Each CLI invocation uses `codex exec --ignore-user-config --ephemeral --sandbox
read-only --skip-git-repo-check --json` in a separate temporary client directory,
with only the local `elixir_mixir` MCP server configured as required and its
explicitly requested tools approved. It reuses the host's saved authentication.
Official documentation describes [JSONL MCP-call events](https://learn.chatgpt.com/docs/non-interactive-mode)
and [MCP server settings](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
There is no model override. CLI thread IDs and command arguments are recorded;
raw reasoning/client stderr stay outside committed evidence.

## Arithmetic and evolution

| Stage | Counter | Aggregate events | Aggregate total | Evidence required |
| --- | --- | --- | --- | --- |
| Empty start | 0 | 0 | 0 | Durable mode, generation 0, no workers before creation |
| v1 amounts 2 and 3 | 5 | 2 | 7 | New count emitted after each event |
| Migrate v2 to schema 2 | 5 | 2 | 7 | Explicit flat-to-nested migration, same live PID |
| v2 amount 4 | 13 | 3 | 20 | Doubled amount behavior |
| Schedule value 11 | 13 | 3 | 20 | One durable schedule, 60-second deadline, accepted ID |
| SIGKILL/recreate | 13 | 3 | 20 | New container/OS/boot identity; selected artifact/state/revisions retained |
| Timer without Codex | 13 | 4 | 31 | One delivery, original ID/deadline, no pending work afterward |
| Fresh client, v2 amount 1 | 15 | 5 | 46 | Recovered implementation executes |
| Compatible v3 replacement | 15 | 5 | 46 | Revision 3, schema 2 preserved, same post-restart PID |
| v3 amount 2 | 21 | 6 | 67 | Tripled amount behavior |
| Reject amount 0 | 21 | 6 | 67 | State/selection/PID/revisions unchanged |

A third logical worker, `stopped_probe`, starts from the v1 artifact and is stopped
without receiving events. Its stopped definition and count 0 survive recovery.
This exercises `runtime_stop` while leaving counter and aggregate active. Each
client uses fresh request IDs; historical PID/module strings are not live handles.

## Disconnected termination and recovery

Session 1's final mutation is the schedule. It immediately inspects the committed
counter, aggregate and pending counts and exits. The operator's HTTP observer
records pending=1/timers=1, then sends `docker kill --signal KILL` to the owned
container and requires exit 137 without OOM termination. Its stopped container is
removed, keeping the named volume. The exact Docker commands are in the manifest.

A short-lived trusted reader opens the store only while the application is stopped.
It never puts records or compiles generated code. This captures the committed
pre-reboot source hashes, definitions, checkpoint and pending intent immediately
AFTER SIGKILL. Together with the pre-kill accepted ID and pending snapshot, it
proves that the exact intent committed before termination; it is not mislabeled
as a live pre-kill database read. Source hashes are checked against original MCP
source strings. No second VM opens a store while its application owner is running.

The driver recreates the same release and volume, waits for health before making
an observer MCP connection, and checks selected counter artifact/schema/count and
revisions plus the stopped definition. The first Codex process has exited and the
second has not started. It polls using read-only HTTP inspection until aggregate
is exactly events 4/total 31 and records the original effect's delivery history.
Only after those assertions pass does it launch the second fresh Codex process.
Actual exit/start timestamps bound this no-Codex interval.

After the second client's verified evolution, an independent observer records the
final state. The driver stops its owned runtime normally, records the closed final
store and removes its containers. Its populated named volume remains retained;
it never deletes volumes. Review the printed name before any deliberate cleanup.
Reusing committed evidence as output is refused; the temporary output directory in
the reproduction command keeps historical session artifacts intact.

## Observed result

On 2026-11-11, Codex CLI 0.167.1 completed 44 actual MCP calls: 27 in thread
`01a1ccd6-478a-7e63-9fdc-aa7c9e007388`, then 17 in the fresh thread
`01a1ccd7-fea4-74e2-8995-e634ead6eed8`. Both CLI processes exited zero.
The table above matches the captured tool results and independent store/HTTP
observations. The evidence verifier passed, including the intentional amount-zero
`CALLBACK_FAILED` result and unchanged worker snapshot. Codex labels that expected
MCP error as a failed tool item; the verifier permits exactly this negative case.

The first CLI exited at 23:00:45.424609 UTC. SIGKILL followed at 23:00:45.432367;
recovery was inspected at 23:00:46.809092; original timer delivery was observed
at 23:01:09.847817. The second CLI started at 23:01:09.852309. Host PIDs changed
from 667491 to 668698, boot IDs differed and lineage stayed constant. Source hashes,
selected revisions, nested state, stopped definition and original effect identity
were retained. Normal stop exited zero. Only owned containers were removed; volume
`mixir-phase02-codex-0b84c8e5a01f-data` remains available for deliberate inspection.

## ADR demonstration coverage

Call numbers refer to the normalized session transcripts linked in the verification
record; observer stages refer to `runtime-observations.json`.

| ADR 10.8 step | Evidence |
| --- | --- |
| 1. Empty durable store | Session 1 call 1: durable format 1, generation 0, no workers |
| 2. Connect Codex CLI | First thread/exit/command in `codex-sessions.json` |
| 3. Create counter/aggregator | Session 1 calls 2–7 |
| 4. Accumulate meaningful state | Session 1 calls 8–12: counter 5, aggregate 2/7 |
| 5. Replace counter | Session 1 calls 13–15: explicit schema migration |
| 6. Confirm behavior/state | Session 1 calls 16–19: counter 13, aggregate 3/20 |
| 7. Disconnect Codex | First client exit timestamp precedes pre-kill observer |
| 8. Abruptly terminate BEAM | Manifest and termination witness: intentional SIGKILL, exit 137, no OOM |
| 9. Restart same store without Codex | Same-volume Docker commands and bounded no-Codex interval |
| 10. Reconstruct intended workers | Restored observer: two running workers plus stopped probe |
| 11. Correct active revisions | Before/restored selected IDs and worker/state revisions match |
| 12. Correct restored state | Restored observer: counter 13 and aggregate 3/20 |
| 13. Process new events | Session 2 call 5: recovered v2 reaches 15, aggregate 5/46 |
| 14. Resume timers/effects | Original pending ID in closed store; observer reaches 4/31; final audit records one completion |
| 15. Reconnect and evolve | Session 2 calls 8–15: compatible v3, counter 21/aggregate 6/67, rejection preserves state |

## Evidence and incomplete attempts

[Phase 2 verification](../docs/sdlc/phase02-restart/verification.md#codex-restart-demo)
indexes the actual session IDs, normalized MCP calls, source hashes, cold-store
records, observer snapshots and restart manifest. `verify-phase02-demo.py` audits
arithmetic, migration, identity, timer completion, source integrity, session
provenance, failure preservation and basic redaction without contacting a runtime.

The first recorded attempt is preserved under
[attempt01](../docs/sdlc/phase02-restart/evidence/attempt01/failure.json). Recovery
and timer completion succeeded, but session 2 reversed reply/state tuple positions.
The runtime correctly rejected its positive event as `INVALID_TRANSITION`, retaining
count 15/aggregate total 46. That attempt is explicitly incomplete. The original
session 2 prompt omitted the full callback signature; a separate clarification
makes `{:ok, reply, new_state_map, effects}` explicit before repeating on a new empty
volume. No runtime code or quality threshold was changed to accept invalid output.

The [second attempt](../docs/sdlc/phase02-restart/evidence/attempt02/cleanup-failure.json)
completed the requested arithmetic and recovery journey, then failed the driver's
normal-shutdown assertion. Its five-second Docker deadline interrupted the
listener's 15-second SSE drain. Docker events and a separate open-stream diagnostic
proved the cause. The owning release correction `ffc70ad` changes the documented
normal stop to 30 seconds and adds a real SSE smoke regression. Its domain results
remain preserved as an incomplete attempt; the final evidence comes from a fresh
empty volume after the correction.
