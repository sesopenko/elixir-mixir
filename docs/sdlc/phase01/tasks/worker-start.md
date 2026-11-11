# worker-start: Supervised worker startup, identity and stop

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

A generated artifact starts in a supervised stable host, is inspectable by logical ID, and can be explicitly stopped/restarted through MCP. This checkpoint does not expose event invocation or automatic crash recovery.

## Prerequisites and required outputs

Prerequisite IDs: artifact-compiler

- [artifact-compiler](artifact-compiler.md): verified contract, immutable artifacts, runtime_define and reusable HTTP fixtures.

A prerequisite is complete only after focused verification, full `mix check`, and
its working commit through the installed hook. Use the governing plan's resolved
contracts and intermediate checkpoint boundaries; no unfinished downstream feature
is required here.

## Concrete implementation steps and components

Add unique Registry, worker DynamicSupervisor, callback Task.Supervisor and ProcessHost. Add Manager.start_worker/1 and stop_worker/1, retained definitions and basic worker inspect. Start hosts as temporary children, publish a running definition only after successful bounded init and JSON-state validation, and monitor hosts for cleanup.
Introduce the reusable bounded callback helper for init: unlinked/monitored task, 8 MiB heap, 200ms deadline, kill/join on timeout, and late-result rejection. Keep callback execution out of Manager/MCP. Snapshot reads use only kernel-owned state; they must not run generated callbacks.
Implement duplicate ID/capacity checks, init failure cleanup, stop retaining definition, explicit start from stopped/failed, and revisions/generation/ledger behavior. Unexpected host death marks its retained definition failed, clears routing and records diagnostics; explicit start is available. Automatic restart policy is deliberately introduced in worker-recovery, with no placeholder timers now.
Add runtime_start/runtime_stop MCP components and extend runtime_inspect for worker state. With inspect/define already available, advertise exactly four tools. Use the shared envelope/schema validation and result-size checks; reject unknown fields and missing request IDs. Extend the growing real-HTTP suite within this task.

## Interfaces, inputs, outputs and errors

Start requires worker_id/artifact_id/config/request_id, returns logical ID, diagnostic PID string, active artifact version, worker/state revisions and running status. Host owns {artifact,data,revisions}; Manager owns desired definition/status and Registry resolves logical IDs. Stop requires worker_id/request_id and returns stopped/definition_retained/worker_revision. An already-stopped retained worker is an idempotent success without a generation increase; unknown IDs fail.
Unknown artifact/worker, duplicate active worker, init error/exception/timeout/invalid state, and config/state/worker bounds return the plan's errors with no half-created live definition. Client request replay must not start a second host. Explicit start can reinitialize a stopped/failed retained ID with supplied config/artifact. Inspect provides bounded state and actual lifecycle without executing handle_event. Do not expose runtime_invoke until worker-invoke; handlers for unsupported direct host messages return a kernel error without executing user code.

Use the plan's exact limits, schemas, errors and in-memory boundaries. Document and
type every public API/struct; preserve all existing quality thresholds.

## Focused tests, integration checks and failure scenarios

Create test/runtime/worker_start_test.exs: init state; Registry/supervisor membership; inspect identity; duplicate IDs; missing artifact/worker; init error/raise/exit/timeout/oversize/non-JSON state; capacity including stopped definitions; stop retaining definition; repeat stop; explicit restart with monotonic revisions; ledger replay/conflict. Kill a host and prove failed status/cleanup and peer/Manager survival, with no automatic restart at this checkpoint.
Extend test/integration/phase01_runtime_test.exs with define/start/inspect/stop using actual MCP HTTP, schema/error boundaries, exact tool discovery, and reconnect to the independently running BEAM: same worker PID/state after client disconnect. Exercise init timeout and a real test-controlled host kill while HTTP/healthy peer remain available. No new production kill tool; test-only control is separate from HTTP runtime API. Inspect actual state/membership as well as response codes. Cleanup hosts/OS fixtures on failure.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root:

```sh
mix test test/runtime/worker_start_test.exs --warnings-as-errors
mix test test/mcp test/integration --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

Four MCP tools work on real HTTP; start/inspect/stop/reinitialize are complete and bounded; init failures leave no live residue; client reconnect preserves host state and identity.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Update docs/runtime-api.md, README tool availability, and docs/sdlc/phase01/verification.md with startup/stop and HTTP evidence, explicitly documenting manual recovery until worker-recovery. Commit host identity/start/stop, MCP adapters, unit/HTTP tests and docs as feat(runtime): give generated workers supervised logical identities.

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
