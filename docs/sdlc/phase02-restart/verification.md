# Phase 2 implementation verification

Status: store-foundation and staged-hosts verified; remaining checkpoints and application recovery
evidence are pending. Planning results belong in [planning-verification](planning-verification.md).
Governing [plan](plan.md); [assignment snapshot](../../prompts/phase02-restart-planning.md).

For each checkpoint record date, baseline and resulting commit, actual commands,
test counts/results, focused failure injections and HTTP increments, full quality
gate and hook results, observed durable/live state, and artifact locations. Never
record a planned result as observed. Update the owning task's checklist only when
the verified commit is created. Keep logs bounded and free of secrets.

Automated tests and actual Codex evidence are separate. For restart cases record
the owned BEAM/container kill mechanism, retained-directory identity, before/after
boot IDs, no-client recovery interval and state/revision/effect assertions. A fresh
printed PID string alone is not proof of reconstruction.

## store-foundation

Verified 2026-11-11 against baseline `5c7f8ea` (this checkpoint commit).
Implementation assignment: [snapshot](../../prompts/phase02-restart-implementation.md).

- `python3 scripts/verify-phase01-demo.py`: verified 59 actual Phase 1 Codex calls,
  confirming the committed prerequisite evidence before selecting this task.
- Focused storage/config/restart command: 8 tests passed. Coverage includes atomic
  paired writes and generation, conflict/canceled writes, invalid JSON and size/
  table limits, changed-record dependencies, unknown format preservation,
  invalid directory, duplicate owner, normal close/reopen, significant store loss,
  readiness-timeout child cleanup and real HTTP inspect/rejected define.
- `mix test test/mcp test/integration --warnings-as-errors`: 57 tests passed.
- `mix check`: 159 tests and 2 doctests passed, no warnings, strict Credo clean,
  Doctor documentation/typespec coverage 100%, Dialyzer zero errors/skips.
- `python3 docs/sdlc/phase02-restart/verify-plan.py` and `git diff --check`: passed;
  installed hook path is `.githooks`. Commit runs the same full gate.

`test/integration/phase02_store_test.exs` owns a unique `/tmp/mixir-restart-*`
directory, commits two audit records at generation 1, sends `kill -KILL` to the
reported BEAM OS PID, waits for exit status 137, then starts another independent
BEAM against that exact directory without an LLM. It verifies a different OS PID
and exact equality of metadata (including lineage/generation) and both records.
The fixture clears inherited storage/port settings. Production Store owns all
backend access, synchronous writes and compaction; test corruption setup alone
uses CubDB directly. A normal-close test caught a leaked backend process; explicit
backend shutdown now allows immediate same-directory reopen.

This proves store durability only. All durable application mutations fail with
`DURABILITY_UNAVAILABLE` before compiler slot use (zero attempts/artifacts);
memory behavior remains covered by the full prior suite. Generated definitions,
worker state, outbox recovery and the actual Phase 2 client demo remain pending.
README, CONTRIBUTING and runtime API describe this boundary.

## staged-hosts

Verified 2026-11-11, prerequisite `b9dea1a` committed and pushed before work.
This checkpoint preserves memory behavior and keeps durable mutations disabled.

- `mix test test/runtime/staged_hosts_test.exs test/runtime/worker_invoke_test.exs test/runtime/replacement_test.exs --warnings-as-errors`: 25 passed.
- `mix test test/integration/phase02_staging_test.exs --warnings-as-errors`: 1 passed.
- `mix test test/mcp test/integration --warnings-as-errors`: 58 passed.
- Full `mix check`: 168 tests, 2 doctests; strict Credo clean, Doctor 100%,
  Dialyzer zero errors/skips. Plan verifier and diff checks passed. The installed
  `.githooks` hook reruns the full gate for the checkpoint commit.

Prepared invoke/replacement leaves committed snapshots unchanged; candidates have
no Registry route. Tests cover abort and real candidate/dispatcher-lease expiry,
one candidate per host, caller ownership, stale revision/incarnation/ticket
rejection, repeated publication without repeating generated callbacks, same-host
replacement, owner/host death and capacity release. Publication pins the effect
reservation before exposing state so a lease cannot expire between publication
and Manager batch commit. A route-collision regression first demonstrated a
Manager crash; failed registration now closes the candidate and preserves the
original route plus both Managers.

The independent HTTP fixture pauses the coordinator at its injected trusted
`before_publish` hook. Direct host snapshots show the original source and peer
state, while the dispatcher shows one reserved effect and zero pending work.
Physical client disconnect leaves the accepted operation running; after release,
a fresh session replays exactly one committed source transition and the peer
receives exactly one effect (total 7, count 1). Existing host-kill/reconnect tests
also pass with explicit `{manager_pid, host_pid}` Registry values. No application
restart recovery is claimed at this checkpoint.

## durable-artifacts

Pending. Owning [task](tasks/durable-artifacts.md). No execution evidence yet.

## durable-lifecycle

Pending. Owning [task](tasks/durable-lifecycle.md). No execution evidence yet.

## durable-transitions

Pending. Owning [task](tasks/durable-transitions.md). No execution evidence yet.

## durable-replacement

Pending. Owning [task](tasks/durable-replacement.md). No execution evidence yet.

## durable-outbox

Pending. Owning [task](tasks/durable-outbox.md). No execution evidence yet.

## durable-delivery

Pending. Owning [task](tasks/durable-delivery.md). No execution evidence yet.

## recovery-quarantine

Pending. Owning [task](tasks/recovery-quarantine.md). No execution evidence yet.

## release-storage

Pending. Owning [task](tasks/release-storage.md). No execution evidence yet.

## codex-restart-demo

Pending. Owning [task](tasks/codex-restart-demo.md). No execution evidence yet.

## evidence-review

Pending. Owning [task](tasks/evidence-review.md). No execution evidence yet.

## Acceptance and milestone evidence

All A01–A14 and milestone 5–7 results are pending. Add an evidence table mapping
each criterion to exact tests/results and committed artifacts as features land.
The final evidence-review reconciles these existing records; it does not create
missing runtime coverage.

## Actual Codex demonstration

Pending. No Phase 2 actual Codex session has been run for this planning checkpoint.
Record prompt snapshots, session provenance, tool calls, pre-kill state, disconnected
SIGKILL/restart, automatic restoration, resumed timers/effects and fresh-session
post-recovery evolution. Preserve the distinction from automated HTTP fixtures and
from Claude Code, which remains untested with this project.
