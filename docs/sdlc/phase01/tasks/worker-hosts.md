# worker-hosts: Supervised stable logical hosts and invocation

## Startup and context recovery

Assignment snapshot: [phase01-planning.md](../../../prompts/phase01-planning.md).
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

A compiled artifact starts under DynamicSupervisor with a logical ID; events update bounded JSON state through a stable host; stopping and bounded crash restarts have observable lifecycle semantics.

## Prerequisites and required outputs

Prerequisite IDs: artifact-compiler

- [artifact-compiler](artifact-compiler.md): verified Behavior contract, immutable registry and define API.

A prerequisite is complete only after its focused verification, full `mix check`,
and working commit through the installed hook. Read the plan's resolved contracts;
this task refines those contracts and does not authorize architectural alternatives.

## Concrete implementation steps and components

Add unique Registry, worker DynamicSupervisor, callback Task.Supervisor, and ProcessHost in the startup order from the plan. Implement Manager.start_worker/1, invoke/1, stop_worker/1, plus worker inspection sufficient for testing actual state. Keep authoritative logical definitions and restart counters in Manager, committed state in Host. Use temporary children with explicit bounded Manager restart policy.
Run init/handle_event in unlinked monitored helpers under the 200ms deadline; task exception/exit/timeout is data returned to Host. Kill/join helpers on expiry; reject late results. Stage and validate reply/state before updating host; do not mutate on error. At this task, accept only an empty effects list and reject nonempty effects with INVALID_TRANSITION, so unsupported delivery cannot be reported successful.
Implement start failure cleanup, duplicate-ID rejection, explicit stopped/failed retained definitions, stop/restart race handling, host DOWN monitoring, init retry budgeting, and deterministic clock-driven per-worker restart windows. Peer workers and MCP subtree must survive a host crash. Explicit stop cancels pending restart attempts. Bump lifecycle/state revisions as specified and expose lost-state-on-crash behavior. No crash state restoration.

## Interfaces, inputs, outputs and errors

Start requires worker_id/artifact_id/config/request_id; successful output includes diagnostic PID string, status and revisions. Invoke requires worker_id/event/request_id and returns bounded reply, revisions and empty effects. Host kernel APIs are snapshot, transition, stop and lifecycle notification; generated source never controls GenServer callbacks directly.
Unknown IDs/artifacts, duplicate active IDs, stopped invocation, init exceptions, callback malformed tuples/state, timeouts, and capacity failures use the plan error codes. Callback {:error, reason} is CALLBACK_FAILED with bounded reason; data/revisions stay unchanged. Same request replay does not increment state. Stop is idempotent for an existing already-stopped definition (no generation change), unknown ID errors. Explicit start of retained ID may replace artifact/config only after stop/failed status. Three automatic restart attempts per 10 seconds then failed status; manual start resets budget.

Use the governing plan's exact limits, errors, callback contracts, revision semantics,
and Phase 1 in-memory boundaries. Document public APIs with accurate docs/specs and
struct types; do not lower Doctor/Credo/Dialyzer thresholds.

## Focused tests, integration checks and failure scenarios

Create `test/runtime/worker_hosts_test.exs`: counter init/increment/reply, Registry and supervisor membership, stable PID across events, duplicate IDs, missing artifact/worker, config/state/reply limits, invalid callback/error/raise/exit/infinite callback, late result suppression, nonempty-effects rejection, replay/conflicts, stop retaining definition, start after stop, capacity including stopped definitions. Kill a host with Process.exit(pid,:kill), assert peer/Manager/MCP identity (when MCP enabled) survives, reinitialized count resets, logical lookup changes PID, revisions increase. Use a host fixture whose init fails after first boot to exhaust restart budget; assert no fourth restart, explicit restart works, stop races do not resurrect workers. Timers/clocks must keep tests fast and deterministic.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root after implementing this task:

```sh
mix test test/runtime/worker_hosts_test.exs --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

Generated worker creation/invocation/inspection/stop works using only completed compiler/manager primitives; callbacks terminate within bounded deadlines; host crash isolation and three-attempt budget are proven.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Extend docs/runtime-api.md with worker lifecycle, revision counters, callback limits, explicit stop vs retained definition, and crash state-loss semantics. Commit host/supervision/Manager lifecycle and tests as `feat(runtime): isolate generated transitions in supervised logical hosts`.

Use a Conventional Commit header, blank line, and nonempty explanatory body stating
why this capability was needed and why the approach fits. Stage only this task's
verified changes. The commit containing the completed checklist identifies the
checkpoint; no self-referential commit hash is needed inside the commit.

## Mandatory completion checklist

- [ ] Reread snapshot, governing plan, current task and approved amendments; verify prerequisite commits.
- [ ] Finish scoped implementation/documentation and focused unit tests, including relevant failure paths (document-only work uses applicable document checks).
- [ ] Pass focused tests and every task-specific verification above; record commands, results and evidence here.
- [ ] Pass full `mix check` and resolve every finding; keep the installed pre-commit hook enabled.
- [ ] Review diff and stage only the intended task changes, tests and documentation.
- [ ] Commit the verified task through the normal hook with Conventional Commit header and explanatory body.
- [ ] Only after that working commit exists, select the next task in the plan; this gate also applies to tasks without dependents.

Execution evidence: pending implementation.
