# runtime-inspection: Bounded runtime topology and diagnostic history

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

Inspect and events provide enough structured evidence to explain worker state, active artifacts, relationships, failures, restarts and pending actions within fixed response sizes.

## Prerequisites and required outputs

Prerequisite IDs: event-effects

- [event-effects](event-effects.md): validated effects, dispatcher reservations, timers and correlated events.

A prerequisite is complete only after its focused verification, full `mix check`,
and working commit through the installed hook. Read the plan's resolved contracts;
this task refines those contracts and does not authorize architectural alternatives.

## Concrete implementation steps and components

Finish Runtime.Inspector and EventLog query APIs; expose Manager.events/1 and complete inspect_runtime/1. Add every Phase 1 lifecycle event enumerated in the plan using a single EventLog append contract. Preserve existing ring/cursor implementation and add gap handling and filters. Do not fabricate Phase 2 recovery events.
Read kernel-owned host snapshots with finite timeout; report unavailable/failed/stopped honestly. Supply sorted paginated workers and edges, state detail, active artifact metadata, generations/revisions, counts, restart budgets, and dispatcher/ledger/limit status. Bound all aggregation and diagnostic data; omit source/BEAM from default inspection. Cursor must encode position and runtime generation; reject stale cursor with INVALID_ARGUMENT and a restart-pagination hint.
Implement response-size preflight/encoding with allowance for MCP text plus structured duplication. Page-shrink and field-omission metadata must make loss visible; do not truncate mutation input or state. Extend runtime_inspect and add runtime_events now that Manager.events/1 is complete. Advertise exactly six tools and validate schemas/unknown fields through shared helpers. Update server instructions and tool discovery tests in this same checkpoint.

Extend test/integration/phase01_runtime_test.exs through real HTTP for topology after counter/aggregator delivery, pending timers, correlated lifecycle/effect failures and restart counts, stopped/failed state, filtered event cursors, eviction gaps and stale pagination cursor rejection. Drive every now-available tool with handshake/session headers; verify diagnostics and state against actual test-controlled host/registry state. Exercise maximum-size data and escaped Unicode so the complete JSON-RPC/content encoding stays <=65536 bytes; explicit omissions/gap metadata must be visible. New client sessions can continue event queries without changing runtime generation. No replacement test may depend on the not-yet-introduced replace tool.

## Interfaces, inputs, outputs and errors

inspect_runtime inputs/outputs and events(after,limit,worker_id) follow the plan. Event records carry monotonic seq, timestamp, type, worker/artifact, correlation, outcome, metadata. Event filtering advances cursor over scanned records so empty filtered pages cannot loop. Oldest sequence and gap distinguish evicted history. Unknown worker gives WORKER_NOT_FOUND, bad/stale cursor INVALID_ARGUMENT, invalid/overlarge requested page LIMIT_EXCEEDED or INVALID_ARGUMENT consistently documented.
Topology contains directed observed emit/schedule relationships with aggregate counts and pending status, not unbounded payload samples. Summary is read-only; no generated callback executes while inspecting. Returned PID is diagnostic only.

Use the governing plan's exact limits, errors, callback contracts, revision semantics,
and Phase 1 in-memory boundaries. Document public APIs with accurate docs/specs and
struct types; do not lower Doctor/Credo/Dialyzer thresholds.

## Focused tests, integration checks and failure scenarios

Create `test/runtime/inspection_test.exs`: running/stopped/failed snapshots, state revisions, unavailable host timeout, artifact metadata, pending timers, observed graph edge counts, histories for compile/crash/restart/migration-ready event names, correlation propagation, UTC and sequence monotonicity, ring overflow with gap and filtering cursor progression. Verify page cursor ordering/no duplication, stale cursor handling, metadata truncation, invalid worker/detail/limits, and encoded response <=65536 bytes including duplicated wire content. Inspect/events must not change generation or call generated callbacks. Test large maximum-size states/worker counts and bounded edge cardinality.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root after implementing this task:

```sh
mix test test/runtime/inspection_test.exs --warnings-as-errors
mix test test/mcp test/integration --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

Runtime and worker snapshots expose actual state/topology/health; every required Phase 1 event is produced or has a tested append path; history and tool-size limits hold at maximum configured load.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Document inspect fields, omissions, pagination/cursor errors, bounded history and diagnostics in docs/runtime-api.md. Update README tool list/examples and docs/sdlc/phase01/verification.md with real-HTTP history/topology/bounds evidence. Commit Inspector/EventLog queries/instrumentation, events adapter and unit/HTTP tests as `feat(runtime): make live state and failures inspectable within bounds`.

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
