# event-effects: Kernel event routing, scheduling and logging

## Startup and context recovery

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

Two generated workers exchange events using logical IDs; delayed events and structured log effects are visible and bounded without recursive synchronous execution.

## Prerequisites and required outputs

Prerequisite IDs: worker-recovery

- [worker-recovery](worker-recovery.md): supervised Host, logical routing, bounded invocation and verified per-worker restart policy over HTTP.

A prerequisite is complete only after its focused verification, full `mix check`,
and working commit through the installed hook. Read the plan's resolved contracts;
this task refines those contracts and does not authorize architectural alternatives.

## Concrete implementation steps and components

Add EffectDispatcher and replace the temporary empty-effects restriction with complete effect validation/reservation. Validate an entire result and reserve batch capacity before committing host state. Token expiry/host DOWN/validation failure releases reservations. Host returns committed batch to Manager; Manager confirms state and then publishes batch. Dispatcher queues deliveries through asynchronous messages to Manager, never calls Manager synchronously while Manager awaits dispatcher or host.
Implement emit/schedule/log shapes, deterministic effect IDs derived from request ID and index/path, inherited correlation, hop budget, timer cancellation on source stop, destination resolution on delivery, queue/timer capacity, and finite dispatch deadlines. Generate a fresh internal delivery operation ID per effect while retaining original correlation; preserve deduplication for retried source requests. Increment inherited hop use across emitted chains rather than resetting it at each invoke.
Record accepted, scheduled, delivered, failed and log events with bounded metadata; missing/stopped destinations and exhausted hops fail observably after source acceptance. No retry loops or external I/O effects. Bound structured Logger metadata/message before logging. Aggregate relationship counts in bounded per-worker maps for the next inspector task.

Replace earlier nonempty-effect rejection fixtures with unsupported/malformed-effect rejection checks now that valid effects are implemented; retain atomic-state assertions. Extend the existing runtime_invoke adapter/response examples for accepted effect IDs without introducing a new tool (discovery remains five tools). In the same task extend test/integration/phase01_runtime_test.exs: define/start counter and aggregator through MCP, invoke counter and inspect exact aggregator count/total through HTTP; exercise delayed events/logs, missing/stopped target, queue/timer/hop bounds and stop cancellation. The test harness can read internal EventLog to confirm correlation until runtime_events arrives; do not depend on the unfinished events tool.
Close the HTTP client during an accepted source invoke, reconnect and retry its request ID; assert exactly one source increment and one aggregator delivery. Include target crash/restart routing using the completed recovery feature. Confirm a rejected state/effect batch produces no downstream event; bounded eventual polling is sufficient, not a fixed arbitrary sleep. Update this feature's automated coverage record and examples immediately.

## Interfaces, inputs, outputs and errors

Effects and delivery semantics exactly match the plan. reserve_batch validates count/shape/JSON/size and total 256 pending deliveries/timers, returns a token or LIMIT_EXCEEDED/INVALID_TRANSITION. commit_batch consumes token once; release is safe on repeated cleanup. Reply contains accepted IDs; asynchronous downstream failure never rewrites a committed source reply. Each queued event reuses the same host transition path, ledger/context and validation as external invokes. Logs accept only four named levels. Schedule delay is integer 0..60000; stop cancels source-owned timers. Timers carry generation/incarnation information to discard stale cancellation races, without coupling destination routing to stale PID.

Use the governing plan's exact limits, errors, callback contracts, revision semantics,
and Phase 1 in-memory boundaries. Document public APIs with accurate docs/specs and
struct types; do not lower Doctor/Credo/Dialyzer thresholds.

## Focused tests, integration checks and failure scenarios

Create `test/runtime/event_effects_test.exs`: generated counter emits to aggregator and aggregator state reaches exact event count/total; delayed event absent before deadline then present; zero/max/invalid delay; structured log metadata via capture_log; missing/stopped target; target restart logical routing; rejected result releases reservations and preserves source; batch atomic validation; no effects after failed callback; replay produces one delivery; queued cyclic workers stop at hop 16; timer/queue/effect saturation; stop cancels timers including firing race; worker/task DOWN releases reservation. Inspect real host state and history; use bounded eventual assertions/fake clock for timers instead of arbitrary sleeps.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root after implementing this task:

```sh
mix test test/runtime/event_effects_test.exs --warnings-as-errors
mix test test/mcp test/integration --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

Worker-to-worker delivery reaches exact aggregate state, delays/logs work, failed transitions emit nothing, cyclic effects terminate, and all pending resources remain within limits.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Update docs/runtime-api.md for effects, acknowledgements vs delivery, timer lifecycle and Phase 1 crash gap. Update docs/sdlc/phase01/verification.md with two-worker HTTP/replay evidence. Commit dispatcher/host staging/routing/events, adjusted adapter and unit/HTTP tests as `feat(runtime): route bounded effects between logical workers`.

Use a Conventional Commit header, blank line, and nonempty explanatory body stating
why this capability was needed and why the approach fits. Stage only this task's
verified changes. The commit containing the completed checklist identifies the
checkpoint; no self-referential commit hash is needed inside the commit.

## Mandatory completion checklist

- [ ] Reread snapshot, governing plan, current task and approved amendments; verify prerequisite commits.
- [ ] Finish scoped implementation/documentation and focused unit tests, including relevant failure paths (document-only work uses applicable document checks).
- [ ] Pass focused tests and the growing real-HTTP integration suite for currently implemented capabilities; record commands, results and evidence here.
- [ ] Pass full `mix check` and resolve every finding; keep the installed pre-commit hook enabled.
- [ ] Review diff and stage only the intended task changes, tests and documentation.
- [ ] Commit the verified task through the normal hook with Conventional Commit header and explanatory body.
- [ ] Only after that working commit exists, select the next task in the plan; this gate also applies to tasks without dependents.

Execution evidence: pending implementation.
