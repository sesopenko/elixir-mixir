# live-replacement: Atomic behavior migration and revision checks

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

A running worker changes implementation inside its existing host; normal replacement retains PID/mailbox and compatible state, while failed candidates leave the previous worker intact.

## Prerequisites and required outputs

Prerequisite IDs: runtime-inspection

- [runtime-inspection](runtime-inspection.md): complete bounded snapshots/topology/history APIs.

A prerequisite is complete only after its focused verification, full `mix check`,
and working commit through the installed hook. Read the plan's resolved contracts;
this task refines those contracts and does not authorize architectural alternatives.

## Concrete implementation steps and components

Add Manager.replace/1 and Host replacement transition. Resolve candidate artifact without executing init; validate active target and expected_revision. Inside serialized Host handling, compare current worker_revision, bypass migrate for same schema, otherwise run candidate migrate(old_state,metadata) in the bounded callback helper. Validate candidate JSON state and response sizes before atomic Host artifact/data/revision update.
Coordinate confirmation: Host replies with committed active artifact, revisions and PID; Manager updates definition/generation and completes request ledger only after confirming it is the same live host. Monitor host death during staging/commit and return failure with diagnostic snapshot rather than false success. No effects on migration; no automatic rollback after a successful subsequent state change. Retain old artifact immutable.
Instrument replacement success and error/exception/invalid/timeout migration outcomes, stale revision, and host death. Make queued events execute before or after replacement according to Host mailbox order; no mixing candidate state with old callback. Test two requests competing for the same expected revision.

Add runtime_replace MCP component in the same checkpoint; reuse shared validation/encoding, pass through expected worker_revision/request_id, and expose the completed seven-tool set. Update exact discovery/schema assertions and server instructions to explain revision checks and explicit migration. All adapters must delegate solely to Manager; runtime_stop requires request_id, and inspect/events remain read-only.
Extend test/integration/phase01_runtime_test.exs through actual HTTP with two successive normal replacements, same-PID/state retention, changed behavior, explicit schema migration, invalid source/missing callbacks while a worker runs, migration error/exception/invalid/timeout and competing revision conflicts. Inspect old artifact/state/revisions after every failure and invoke again. Retain kernel monitors/barriers where needed to prove mailbox ordering or inject host death without adding an eighth tool.
Close a client during accepted replacement; reconnect/replay returns the single committed result or original failure with actual active artifact/PID/state verified. Complete the growing counter/aggregator journey and record all A01–A14 automated evidence in verification.md while keeping actual Codex claims pending. Exercise all seven schemas and stable error envelopes, request-ID conflicts/replay across sessions, bounded wire encoding and runtime identity continuity. These checks are part of this feature gate, not a subsequent integration task.

## Interfaces, inputs, outputs and errors

runtime_replace contract is the plan table. expected_revision is positive worker_revision, not artifact or global generation. Same-schema replacement retains data and state_revision; worker_revision and global generation increase once. Different-schema migration success increments state_revision as well. Failure preserves every prior committed field and emits bounded diagnostics; schema mismatch without usable migrate is MIGRATION_FAILED (missing callbacks were already rejected at define).
Return previous/new artifact revisions separately from worker_revision, migration_result (preserved or migrated), pid_before/pid_after. Same request replay returns original result; different request with stale expected_revision returns REVISION_CONFLICT. Stopped/failed target returns WORKER_NOT_RUNNING. Host death may reinitialize through lifecycle policy but must never be reported as successful replacement.

Use the governing plan's exact limits, errors, callback contracts, revision semantics,
and Phase 1 in-memory boundaries. Document public APIs with accurate docs/specs and
struct types; do not lower Doctor/Credo/Dialyzer thresholds.

## Focused tests, integration checks and failure scenarios

Create `test/runtime/replacement_test.exs`: increment v1, define v2, replace with expected worker revision, prove exact PID equality/no DOWN and state equality; verify next event uses v2. Change schema and migrate explicitly with verified metadata. Exercise missing artifact, stale revision, migration {:error}, raise, exit, timeout, malformed tuple, oversized/non-JSON state. After each rejection inspect old artifact/PID/state/revisions and invoke old behavior. Test replay, concurrent replacements (one wins), queued event ordering with controlled barriers, and externally killed host during replacement. Define invalid candidate source while a worker runs and assert active artifact unchanged. Explicit reverse migration fixture proves rollback requires a valid migration.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root after implementing this task:

```sh
mix test test/runtime/replacement_test.exs --warnings-as-errors
mix test test/mcp test/integration --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

Normal replacement preserves host PID/mailbox; compatible state is identical, schema changes migrate explicitly; all failed candidates leave old live state intact; stale competing requests cannot overwrite newer revisions.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Update docs/runtime-api.md with migration metadata, revision meanings, confirmation/failure boundaries, and explicit reverse migration. Update README/docs with all seven copyable tool examples and docs/sdlc/phase01/verification.md with completed automated coverage. Commit replacement/diagnostics/replace adapter/unit and HTTP tests as `feat(runtime): evolve live behavior without replacing its host`.

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
