# store-foundation: Establish storage authority and restart fixtures

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

A configured durable store atomically retains bounded kernel records across abrupt BEAM termination; memory startup remains disposable.

## Prerequisites and required outputs

Prerequisite IDs: none

No Phase 2 task prerequisites. Verify the committed Phase 1 baseline and its evidence.

## Implementation and contracts

- Add CubDB 2.0.2 as a production dependency and commit mix.lock. Implement Store start/snapshot/commit with fixed record tags, format version validation, expected-generation checks, sync enabled and bounded kernel errors. Keep backend calls behind Store; document/spec its public functions and types.
- Add validated :storage configuration and ELIXIR_MIXIR_DATA_DIR opt-in. Missing durable data_dir, unwritable paths and unsupported format fail closed. Defaults remain memory; no fixture may accidentally open user storage. Durable mutations return DURABILITY_UNAVAILABLE at this checkpoint.
- Supervise the store before runtime authority; preserve significant-child shutdown on authoritative store loss. Expose bounded storage mode and format via inspection; do not imply generated definitions are durable yet.
- Extend RuntimeFixture/boot controls to accept a retained temporary directory, capture the actual BEAM OS PID, send SIGKILL, wait for exit and reopen the same directory. Expected kills must not crash the owning test. New readiness timeout must clean up OS processes and files on failure. Add named internal fault barriers for later tasks without exposing production tools.

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- Store tests cover atomic multi-record commit, generation conflict, canceled transaction, JSON/value bounds, unknown format, directory failure, duplicate same-VM store owner and significant store death. Failure injection runs outside user directories.
- First actual OS restart test commits a Store record through test-only control, kills its owning BEAM, reopens and verifies the whole record set. Real HTTP inspect remains available in memory and durable modes; verify unsupported mutations do not execute callbacks.
- Assert SIGKILL is used rather than graceful application stop, directory reuse is explicit, ordinary fixtures are isolated, and failure cleanup leaves no child processes.

Every runtime task extends the growing real-HTTP independent-BEAM suite at its
own checkpoint, including relevant failure/abrupt-interruption cases. Observe
actual stored records and live state as well as response codes. No intentionally
failing downstream tests. Investigate unexpected results at their root, prove the
cause with a test and fix the system; after three unsuccessful fix attempts stop
and ask the user for direction.

## Verification commands and acceptance

Run from the repository root after creating the focused test files owned here:

```sh
mix test test/runtime/store_test.exs test/runtime/storage_config_test.exs --warnings-as-errors
mix test test/integration/phase02_store_test.exs --warnings-as-errors
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

Update CONTRIBUTING and runtime API with durable configuration, exclusive ownership and the intermediate unsupported-mutation boundary. Keep README current feature claims in-memory until generated artifacts are integrated.

Intended header: `feat(storage): establish an explicit durable runtime authority`. Add a blank line and a nonempty explanatory
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

Final size: 3

Small backend wrapper and fixture extension; no generated-worker transaction protocol yet. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
