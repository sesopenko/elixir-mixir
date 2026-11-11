# worker-recovery: Crash isolation and bounded automatic recovery

## Startup and context recovery

Implementation: [assignment](../../../prompts/phase01-implementation.md) and
[unattended continuation](../../../prompts/phase01-implementation-amendment-04.md).
Corrections: [02](../../../prompts/phase01-dependency-amendment-02.md),
[03](../../../prompts/phase01-dependency-amendment-03.md),
[05](../../../prompts/phase01-transport-amendment-05.md).

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

An actual host crash restarts only that logical worker within a bounded per-worker budget; healthy peers, Manager and the MCP endpoint remain alive. Explicit stop prevents resurrection.

## Prerequisites and required outputs

Prerequisite IDs: worker-invoke

- [worker-invoke](worker-invoke.md): complete start/stop/invoke/inspect operations, bounded callbacks and live HTTP worker suite.

A prerequisite is complete only after focused verification, full `mix check`, and
its working commit through the installed hook. Use the governing plan's resolved
contracts and intermediate checkpoint boundaries; no unfinished downstream feature
is required here.

## Concrete implementation steps and components

Extend Manager host monitors and retained definitions with the plan's automatic restart policy. Keep DynamicSupervisor children temporary; Manager schedules replacement host startups using the completed start/init path and active artifact/config. Permit three restart attempts per worker per rolling 10 seconds; count failing reinitialization attempts and mark failed when exhausted. Inject monotonic clock/timer controls for fast deterministic tests.
Rerun init on recovery, explicitly losing prior worker state in Phase 1; maintain monotonic lifecycle/state revisions, current Registry mapping, restart counts/status and bounded diagnostic events. Manual start of failed/stopped ID resets restart budget. Monitor old/new incarnations so stale DOWN/restart messages cannot affect a new host, and stop invalidates scheduled retries before termination.
Keep lifecycle failure handling and restart metadata inside Manager, no automatic application/kernel recovery. Test independent budgets so a crashing worker cannot exhaust a peer's allowance or terminate the supervisor/HTTP subtree. Update earlier worker-start host-death expectations from its intermediate manual-only policy to the final automatic policy; keep the original cleanup/isolation assertions. No new MCP tools are needed: extend current start/stop/invoke/inspect results and HTTP scenarios. Timer cancellation for generated scheduled effects is added later in event-effects.

## Interfaces, inputs, outputs and errors

Use the existing five MCP tools and worker-start/worker-invoke contracts. Real host death differs from callback-task failure: callback failure retains live host/data; host death reinitializes the active artifact from retained config with a new diagnostic PID, increased revisions and lost volatile data. Logical ID stays constant. During restart, inspect reports restarting; invoke returns WORKER_NOT_RUNNING rather than success. After budget exhaustion, status is failed and only explicit start restarts it.
Each restart attempt is counted once, including init failures; no fourth automatic attempt inside the rolling window. Stop is authoritative and cancels pending retries; completed stop cannot be undone by late DOWN/timer messages. All lifecycle outcomes are bounded/correlated. HTTP client disconnects do not affect restart policy.

Use the plan's exact limits, schemas, errors and in-memory boundaries. Document and
type every public API/struct; preserve all existing quality thresholds.

## Focused tests, integration checks and failure scenarios

Create test/runtime/worker_recovery_test.exs: Process.exit(pid,:kill), new PID/Registry mapping, reset init state, retained active artifact/config, monotonic revisions, peer/Manager/supervisor survival; failed init after initial boot exhausts exactly three retries; rolling-window expiration; independent worker budgets; explicit restart resets budget; explicit stop/old DOWN/timer races never resurrect worker; callback-task failures do not trigger host restart.
Extend real-HTTP suite while the external BEAM stays running: define/start two workers, increment one, kill its actual host through test control, poll inspect through HTTP and assert the peer still invokes correctly and MCP server/BEAM identity stays fixed. Verify new host state/revision/PID, restart-exhausted inspect/error, manual start, and stopped status across delayed retry. Test-only control must be unavailable in production API. Reconnect a client during recovery and confirm inspection reports actual lifecycle, not fabricated success.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root:

```sh
mix test test/runtime/worker_recovery_test.exs --warnings-as-errors
mix test test/runtime/worker_start_test.exs test/runtime/worker_invoke_test.exs --warnings-as-errors
mix test test/mcp test/integration --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

Exactly three automatic attempts per worker/window, no fourth; a crash leaves peer and HTTP available; manual start works after exhaustion; stop/restart races cannot resurrect a stopped worker; all growing HTTP scenarios pass.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Update docs/runtime-api.md to replace intermediate manual-only recovery with final restart policy/crash state-loss contract. Update docs/sdlc/phase01/verification.md with fault/reconnect evidence. Commit restart policy, lifecycle tests/HTTP checks and docs as feat(runtime): contain worker crashes with bounded recovery.

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

- Verified prerequisite commit `1c325d4`, reread governing instructions and preserved
  unrelated `scripts/codex.sh`.
- `mix test test/runtime/worker_recovery_test.exs --warnings-as-errors`: 5 tests,
  zero failures. Injected monotonic clock and retry scheduling prove exactly three
  attempts, failed init accounting, independent budgets, expiration at ten seconds,
  manual reset, and stale monitor/token immunity after stop and a new incarnation.
  Actual host kills prove new Registry/PID, reset state and monotonic revisions.
- `mix test test/runtime/worker_start_test.exs test/runtime/worker_invoke_test.exs --warnings-as-errors`:
  19 tests, zero failures. Earlier manual-only expectation now checks automatic
  recovery; callback failures retain their original host/state/revisions/budget.
- `mix test test/mcp test/integration --warnings-as-errors`: 40 tests, zero failures.
  Independent BEAM HTTP tests prove kill/reconnect recovery, healthy peer invocation,
  stable BEAM/health identity, three failed init attempts and explicit budget reset.
  Stop during a pending retry remains stopped after the retry delay has elapsed.
- `mix check`: passed; 2 doctests, 102 tests, zero failures; strict Credo clean,
  Doctor 100% documentation/typespec coverage, Dialyzer zero errors.
- `git diff --check`: passed; hook path `.githooks`. The commit containing this
  completed checklist is the checkpoint, recorded through the full-quality hook.
- Next task after that commit: `event-effects`. Generated effect timers remain
  that task's scope; recovery timers are now cancelled and incarnation guarded.
