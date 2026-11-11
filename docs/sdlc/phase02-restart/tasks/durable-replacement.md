# durable-replacement: Commit implementation selection and migration together

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

A committed replacement recovers its selected artifact and compatible or migrated state atomically; uninterrupted replacement retains its host PID.

## Prerequisites and required outputs

Prerequisite IDs: durable-transitions

[durable-transitions](durable-transitions.md) must be verified and committed. Read its completed
outcome and evidence; it supplies the immediately preceding working checkpoint
and all earlier contracts in the governing plan. Do not rely on unfinished
downstream features.

## Implementation and contracts

- Enable durable replacement using staged-host preparation. Validate expected worker revision and durable candidate artifact, run migration only for different schemas, validate state and preflight result before the single Store transaction.
- Commit artifact selection, state/schema/revisions, request outcome, generation and audit together. Publish in the original host only after commit. Keep existing same-schema state-revision behavior; no automatic migration during boot.
- Handle commit uncertainty and publication failure through the common shutdown/recovery protocol. An uncommitted candidate leaves old durable selection/state; committed migrated state restores directly without invoking migrate again.
- Apply current callback/heap/deadline/result bounds to migrations and preserve previously committed pending work (none is accepted in durable mode until the outbox task).

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- Real HTTP compatible replace preserves PID/state; schema-changing migration changes state exactly once. SIGKILL restores selected ID/revisions/schema/state without an LLM; a fresh retained-request replay matches the historical replacement response.
- Crash before/after the transaction with barriers, including after migration but before commit. Assert either old selection/old state or new selection/new state across all records.
- Invalid candidate, missing callbacks, bad migration, migration timeout, stale expected revision and oversized response preserve prior state/selection. A fixture whose migration fails on second execution proves boot does not rerun it.

Every runtime task extends the growing real-HTTP independent-BEAM suite at its
own checkpoint, including relevant failure/abrupt-interruption cases. Observe
actual stored records and live state as well as response codes. No intentionally
failing downstream tests. Investigate unexpected results at their root, prove the
cause with a test and fix the system; after three unsuccessful fix attempts stop
and ask the user for direction.

## Verification commands and acceptance

Run from the repository root after creating the focused test files owned here:

```sh
mix test test/runtime/durable_replacement_test.exs --warnings-as-errors
mix test test/integration/phase02_replacement_test.exs --warnings-as-errors
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

Update API and README for milestone 6, recovered implementation selection, same-PID live versus fresh-host boot behavior, and failure semantics. CONTRIBUTING lists the migration interruption checks.

Intended header: `feat(runtime): recover atomic implementation replacements`. Add a blank line and a nonempty explanatory
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

Execution evidence: 2026-11-11, prerequisite `a0114e0` verified and pushed before
work. Focused durable replacement checks passed (4 tests), independent HTTP checks
passed (7 tests), growing MCP/integration suite passed (90 tests), and full
`mix check` passed (223 tests, 2 doctests, Credo clean, Doctor 100%, Dialyzer zero
findings). The [evidence entry](../verification.md#durable-replacement) records
same-host replacement, schema migration, five real SIGKILL boundaries and direct
restoration without repeated migration. Milestone 6's automated exit is verified;
durable outbox/delivery and the actual client demonstration remain pending.

## Relative size

Final size: 5

Reuses the established transition path for bounded migrations and selection changes. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
