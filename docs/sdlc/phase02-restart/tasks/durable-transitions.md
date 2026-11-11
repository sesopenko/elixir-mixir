# durable-transitions: Commit event state before acknowledgement

Status: pending implementation.

## Startup and context recovery

Assignment snapshot: [Phase 2 planning](../../../prompts/phase02-restart-planning.md).
Governing plan: [restart plan](../plan.md). Current task: this document.
Evidence: [verification](../verification.md).
Before this subtask and after every compaction, both planning and implementation
agents must reread the complete snapshot, governing plan, current task, AGENTS.md
and separately recorded approved amendments. A compaction summary does not replace
these reads. Save any new implementation assignment under docs/prompts before work
and link it from the governing plan. Preserve snapshots; record amendments separately.
If documents do not exist yet, read available governing documents and partial drafts.
Also read CONTRIBUTING.md and ADR-001. After a new session or full context clear,
inspect `git status --short`, `git log --oneline -15`, relevant commits and evidence;
determine progress from committed state and verify prerequisites before selecting work.
Preserve unrelated user changes, including the archived-prompt relocation and scripts/codex.sh.

## Objective and observable outcome

Effect-free accepted events and their outcomes survive VM or host death without partial state or duplicate retained-request execution.

## Prerequisites and required outputs

Prerequisite IDs: durable-lifecycle

[durable-lifecycle](durable-lifecycle.md) must be verified and committed. Read its completed
outcome and evidence; it supplies the immediately preceding working checkpoint
and all earlier contracts in the governing plan. Do not rely on unfinished
downstream features.

## Implementation and contracts

- Enable durable effect-free invocation through prepared hosts. Atomically commit new state/schema/revision, exact reply/outcome, generation and audit; only then publish and acknowledge. Route all state changes through this coordinator; direct callbacks cannot mutate committed kernel state.
- Reject a nonempty effect batch with DURABILITY_UNAVAILABLE before committing or dispatching it until durable-outbox. Release all transient reservations and preserve old state. Memory mode retains its full existing effect support.
- Adapt automatic host recovery to inject the latest committed state without rerunning init or incrementing state revision. Persist crash/retry lifecycle changes and rolling restart budgets; explicit stop remains authoritative. Boot itself does not manufacture a state transition.
- Complete fail-closed handling of uncertain Store commit and failed host publication. A committed outcome remains authoritative; process shutdown/recovery must not replace it with CALLBACK_FAILED. Add test-only barriers immediately before commit, after commit and before publication/response.

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- HTTP increment, force lost response, SIGKILL and restart with the same store. Retried retained request ID returns the identical result/generation and the counter changed exactly once. Inspect actual stored state and the restored host snapshot.
- Kill before commit versus after commit: outcome is interrupted old state or complete new state, never a new state with missing outcome. Inject a commit exception/timeout and host death after commit; readiness drops and restart reads actual disk authority.
- Invalid/oversized/non-JSON state, callback exceptions/deadlines and unsupported effects preserve state. Retry retention, backward clock behavior, peer health, stop/retry races and three-attempt exhaustion remain bounded.

Every runtime task extends the growing real-HTTP independent-BEAM suite at its
own checkpoint, including relevant failure/abrupt-interruption cases. Observe
actual stored records and live state as well as response codes. No intentionally
failing downstream tests. Investigate unexpected results at their root, prove the
cause with a test and fix the system; after three unsuccessful fix attempts stop
and ask the user for direction.

## Verification commands and acceptance

Run from the repository root after creating the focused test files owned here:

```sh
mix test test/runtime/durable_transitions_test.exs test/runtime/worker_recovery_test.exs --warnings-as-errors
mix test test/integration/phase02_transitions_test.exs --warnings-as-errors
mix test test/mcp test/integration --warnings-as-errors
python3 docs/sdlc/phase02-restart/verify-plan.py
mix check
git diff --check
git config --get core.hooksPath
```

All focused behavior/failure assertions above must pass, alongside the growing
integration suite and full `mix check`. Exact new test filenames above are planned
outputs, not claims they exist in the baseline. Existing named test files must be
located before use if repository organization has changed. The hook path must be
`.githooks`; if absent, install with `./scripts/install-git-hooks.sh`. Never bypass
the installed pre-commit hook or lower quality thresholds. Record actual command
results and evidence; planning checks alone do not satisfy runtime acceptance.

## Documentation and intended commit

Update README, CONTRIBUTING and API with durable acknowledgement, host-state restoration, uncertain-response retry, retention caveat and trusted-callback IO limits. Do not claim durable effects yet.

Intended header: `feat(runtime): retain acknowledged event state across crashes`. Add a blank line and a nonempty explanatory
body describing why the change is needed and why this approach fits. Include only
this task's verified code, tests, documentation and progress evidence; leave
unrelated user edits unstaged. The commit containing the completed checklist is
the checkpoint; no self-referential hash is required inside it.

## Completion checklist

- [ ] Reread governing instructions and verify prerequisite commits.
- [ ] Complete scoped changes and focused unit tests, including relevant failures; documentation-only work uses document checks.
- [ ] Pass task-specific verification and the growing HTTP integration suite; record actual evidence.
- [ ] Pass full `mix check` without suppressions and verify local links/diff.
- [ ] Update public guidance when behavior changes and reconcile this task's verification entry.
- [ ] Commit only the verified task through the installed pre-commit hook using a Conventional Commit header and explanatory body.
- [ ] Only after that working commit exists, select the next task; this gate also applies to tasks without dependents.

Execution evidence: pending implementation.

## Relative size

Final size: 8

Establishes the durable/live ordering and uncertain-response behavior for every later state mutation. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
