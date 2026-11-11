# worker-invoke: Bounded invocation and atomic state transitions

## Startup and context recovery

Implementation assignment: [resume Phase 1](../../../prompts/phase01-implementation.md).
Continuation: [amendment 04](../../../prompts/phase01-implementation-amendment-04.md).
Transport/lifetime: [amendment 05](../../../prompts/phase01-transport-amendment-05.md).
Dependency corrections: [02](../../../prompts/phase01-dependency-amendment-02.md),
[03](../../../prompts/phase01-dependency-amendment-03.md).
Assignment snapshot: [phase01-planning.md](../../../prompts/phase01-planning.md).
Approved amendment: [amendment 01](../../../prompts/phase01-planning-amendment-01.md).
Governing plan: [plan.md](../plan.md). Current task: this document.
Before starting this subtask and after every compaction, both planning and
implementation agents must reread the complete snapshot, governing plan, this task,
and separately recorded approved amendments. A compaction summary does not replace
these reads. Save complete new assignment instructions under `docs/prompts/` before
other work and identify that snapshot in its work plan; preserve originals and put
approved amendments in separate files. If documents are absent, read available
governing documents and partial drafts. Also read `AGENTS.md`, `CONTRIBUTING.md`,
and ADR-001. After a full context clear or new session, inspect `git status --short`,
`git log --oneline -15`, relevant commits and verification evidence to determine
progress from repository state and committed work. If task selection is unclear,
use the plan execution order and verify completed prerequisites first. Preserve
unrelated changes, including `scripts/codex.sh`.

## Objective and observable outcome

A generated worker accepts events through MCP and commits valid replies/state atomically; callback failures/timeouts leave its last committed state intact. Effects are not yet supported.

## Prerequisites and required outputs

Prerequisite IDs: worker-start

- [worker-start](worker-start.md): supervised logical hosts, bounded init helper, inspect/start/stop MCP tools and HTTP lifecycle suite.

A prerequisite is complete only after focused verification, full `mix check`, and
its working commit through the installed hook. Use the governing plan's resolved
contracts and intermediate checkpoint boundaries; no unfinished downstream feature
is required here.

## Concrete implementation steps and components

Add ProcessHost event transition and Manager.invoke/1, reusing the completed callback helper. Serialize host events, run handle_event in unlinked monitored task under the same heap/deadline, and stage the entire callback tuple/reply/state before committing. Reject all nonempty effects lists with INVALID_TRANSITION until event-effects; do not return false effect acknowledgements.
Implement event/reply/state JSON/byte bounds, malformed tuple and {:error,reason} handling, task exception/exit/timeout cleanup, late-result suppression, state_revision/global generation updates on success only, and request-ledger replay/conflict. Preflight bounded wire results before committing. A host death still follows worker-start's manual-recovery policy; automatic restarts belong to the next checkpoint.
Add runtime_invoke MCP component with exact plan schema and common bounded errors. Advertise five tools. Extend the existing HTTP journey from define/start into counter increment/inspect and failure behavior. Confirm HTTP disconnect during accepted work does not cancel or duplicate a mutation, using the shared independent BEAM fixture.

## Interfaces, inputs, outputs and errors

Invoke takes worker_id/event/request_id, returns reply, worker_revision, state_revision and empty effects. Event roots and new state roots are maps; reply may be any bounded JSON value. Valid {:ok,reply,new_state,[]} commits once; malformed return/state/reply or nonempty effects returns INVALID_TRANSITION, unchanged state/revisions. Callback {:error,reason}, raise or exit maps to CALLBACK_FAILED with bounded reason; deadline maps to CALLBACK_TIMEOUT. Stopped/failed target returns WORKER_NOT_RUNNING, unknown target WORKER_NOT_FOUND.
Host processes one transition at a time. Request replay returns exactly the original result without another increment; different payload/operation with the same ID returns REQUEST_ID_CONFLICT. PID is unchanged across successful events and callback-level failure. Basic worker inspection from worker-start is sufficient to verify state without future Inspector features.

Use the plan's exact limits, schemas, errors and in-memory boundaries. Document and
type every public API/struct; preserve all existing quality thresholds.

## Focused tests, integration checks and failure scenarios

Create test/runtime/worker_invoke_test.exs: counter event/reply and state revisions; stable host PID; sequential/concurrent events; malformed tuple, callback error/raise/exit/timeout, non-JSON/oversized event/state/reply, empty-effects requirement, late-result suppression, stopped/missing worker, ledger replay/conflict, unchanged state/revisions on every rejected transition. Verify a healthy peer works after a timed-out callback.
Extend the real-HTTP suite with define/start/increment/inspect, input and response limits, error envelopes and exact five-tool schemas. Close a client connection during a controlled accepted invoke, initialize a fresh client and retry the same request ID: observe exactly one increment and original result in the same live BEAM/host. While the counter runs, submit invalid source/missing callbacks via runtime_define and assert active artifact/state remain unchanged; invoke the old worker afterward. Test controls may observe/kill fixtures but never create a production testing tool.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root:

```sh
mix test test/runtime/worker_invoke_test.exs --warnings-as-errors
mix test test/mcp test/integration --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

Five MCP tools work; HTTP invocation commits exactly once across reconnect/retry; valid state changes are atomic and invalid/timeout callbacks preserve PID/data/revisions; all transition payloads are bounded.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Update docs/runtime-api.md with invocation/errors/temporary empty-effects restriction, and docs/sdlc/phase01/verification.md with timeout and disconnect/replay evidence. Commit transition handling, invoke adapter, unit/HTTP tests and docs as feat(runtime): commit bounded worker event transitions.

Use a Conventional Commit header, blank line, and nonempty explanatory body stating
why this capability was needed and why the approach fits. Stage only this task's
verified changes. The commit containing the completed checklist identifies the
checkpoint; no self-referential commit hash is needed inside the commit.

## Mandatory completion checklist

- [x] Reread snapshot, governing plan, current task and approved amendments; verify prerequisite commits.
- [x] Finish scoped implementation/documentation and focused unit tests, including relevant failure paths (document-only work uses applicable document checks).
- [x] Pass focused tests and the growing real-HTTP integration suite for currently implemented capabilities; record commands, results and evidence here.
- [x] Pass full `mix check` and resolve every finding; keep the installed pre-commit hook enabled.
- [x] Review diff and stage only the intended task changes, tests and documentation.
- [x] Commit the verified task through the normal hook with Conventional Commit header and explanatory body.
- [x] Only after that working commit exists, select the next task in the plan; this gate also applies to tasks without dependents.

Execution evidence (2026-11-11):

- Reread assignment/plan/task/amendments and verified prerequisite `76f0178`;
  preserved unrelated `scripts/codex.sh`.
- `mix test test/runtime/worker_invoke_test.exs --warnings-as-errors`: 9 tests,
  zero failures. Covers atomic reply/state/revisions, PID preservation, concurrency,
  failure/timeout/heap/late results, JSON/byte/wire bounds, replay/conflicts,
  healthy peer and stopped/unknown/non-Manager callers.
- `mix test test/mcp test/integration --warnings-as-errors`: 39 tests, zero failures.
  Exactly five tools; counter HTTP journey, active artifact survival after rejected
  definitions, failure/limit envelopes and full-response preflight pass. A physical
  HTTP disconnect during controlled accepted work is followed by fresh initialize
  and same-ID retries: one increment, original result/generation, same host PID.
- `mix check`: passed; 2 doctests, 96 tests, zero failures; strict Credo clean,
  Doctor 100% documentation/typespec coverage, Dialyzer zero errors.
- `git diff --check`: passed. Hook path `.githooks`; reviewed task-only changes.
  Evidence is in [verification.md](../verification.md).
- The commit containing this checked task is the checkpoint, through the normal
  pre-commit gate. Nonempty effects remain rejected and recovery remains manual.
- Next task only after that verified commit: `worker-recovery`.
