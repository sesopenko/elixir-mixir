# durable-outbox: Commit outgoing work with its originating state

Status: verified in this checkpoint commit.

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

An accepted transition retains its entire effect/timer/log intent batch with its state across restart; this checkpoint deliberately keeps durable dispatch paused.

## Prerequisites and required outputs

Prerequisite IDs: durable-replacement

[durable-replacement](durable-replacement.md) must be verified and committed. Read its completed
outcome and evidence; it supplies the immediately preceding working checkpoint
and all earlier contracts in the governing plan. Do not rely on unfinished
downstream features.

## Implementation and contracts

- Replace the durable nonempty-effect rejection with validated pending records in the same transaction as origin state, revisions, outcome and audit. Memory mode keeps existing dispatch. In durable mode do not execute even log effects before commit.
- Derive effect IDs from persisted unique operation ID plus path; preserve request correlation separately. Compute immutable absolute due_at timestamps for schedules and persist bounded hop/source/target context without PIDs, tokens or VM clock values.
- Treat dispatcher reservations as transient capacity accounting against durable pending count. Rollback releases reservations; recovered records reconstruct pending counts without stale reservations. Reject a whole batch before commit if any member is invalid or exceeds capacity.
- Stop atomically deletes still-pending source effects with the stopped definition and audit. Host crash preserves pending intents; replacement leaves them unchanged. This task exposes accepted pending counts and documents that dispatch is paused until durable-delivery.

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- HTTP invoke with emit/schedule/log batch, SIGKILL on either side of commit and inspect the reopened store: complete state plus complete batch or neither. No log or peer state change occurs before commit or while durable dispatch is paused.
- Validate deterministic IDs on retained request replay, distinct IDs when expired caller keys are reused, reservation cleanup on host/owner death, full-queue batch rejection and state/response-size failure rollback.
- Test stop/cancel race, preserved effects across host crash/replacement, UTC deadlines unchanged across reopening and retained pending limits. Growing Phase 1 memory-mode effect tests must continue passing.

Every runtime task extends the growing real-HTTP independent-BEAM suite at its
own checkpoint, including relevant failure/abrupt-interruption cases. Observe
actual stored records and live state as well as response codes. No intentionally
failing downstream tests. Investigate unexpected results at their root, prove the
cause with a test and fix the system; after three unsuccessful fix attempts stop
and ask the user for direction.

## Verification commands and acceptance

Run from the repository root after creating the focused test files owned here:

```sh
mix test test/runtime/durable_outbox_test.exs --warnings-as-errors
mix test test/integration/phase02_outbox_test.exs --warnings-as-errors
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

Update runtime API and contributor guidance with transactional pending intents, fixed deadlines and the temporary paused-dispatch boundary. README must avoid claiming resumed delivery until the next task.

Intended header: `feat(runtime): retain effects with their originating transitions`. Add a blank line and a nonempty explanatory
body describing why the change is needed and why this approach fits. Include only
this task's verified code, tests, documentation and progress evidence; leave
unrelated user edits unstaged. The commit containing the completed checklist is
the checkpoint; no self-referential hash is required inside it.

## Completion checklist

- [x] Reread governing instructions and verify prerequisite commits.
- [x] Complete scoped changes and focused unit tests, including relevant failures; documentation-only work uses document checks.
- [x] Pass task-specific verification and the growing HTTP integration suite; record actual evidence.
- [x] Pass full `mix check` without suppressions and verify local links/diff.
- [x] Update public guidance when behavior changes and reconcile this task's verification entry.
- [x] Commit only the verified task through the installed pre-commit hook using a Conventional Commit header and explanatory body.
- [x] Only after that working commit exists, select the next task; this gate also applies to tasks without dependents.

Execution evidence: 2026-11-11, prerequisite `461350f` verified and pushed before
work. Focused durable outbox checks passed (6 tests), independent HTTP checks
passed (6 tests), growing MCP/integration suite passed (96 tests), and full
`mix check` passed (235 tests, 2 doctests, Credo clean, Doctor 100%, Dialyzer zero
findings). The [evidence entry](../verification.md#durable-outbox) records atomic
batch/state acceptance and cancellation at six real SIGKILL boundaries, stable
identities/deadlines, capacity reconstruction and paused delivery. Durable delivery
and the actual client demonstration remain pending.

## Relative size

Final size: 8

Unifies capacity reservations, durable identity, state and the complete effect batch. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
