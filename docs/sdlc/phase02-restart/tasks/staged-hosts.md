# staged-hosts: Prepare transitions before publishing live state

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

Existing in-memory tools still work, while callback results can be prepared and rejected without changing public state or dispatching effects.

## Prerequisites and required outputs

Prerequisite IDs: store-foundation

[store-foundation](store-foundation.md) must be verified and committed. Read its completed
outcome and evidence; it supplies the immediately preceding working checkpoint
and all earlier contracts in the governing plan. Do not rely on unfinished
downstream features.

## Implementation and contracts

- Split ProcessHost invocation/replacement into Manager-owned prepare/publish/abort operations. Store a single staged candidate with operation identity, base revisions and incarnation; snapshot still returns committed state. Reject unsupported callers and stale publication.
- Keep the existing bounded callback runner, schema migration and full response preflight. Prepared effects reserve capacity but never dispatch until publication. Release reservations on abort, owner death, host death or preparation timeout; remove orphan candidates.
- Adapt Workers and Manager so memory mode prepares, preflights, publishes and records its result in a single serialized operation. Repeated publication of the last committed operation is safe; a different/stale token is rejected. Durable mode remains mutation-gated until subsequent feature tasks.
- Introduce candidate host startup that has no Registry route. Move logical routing ownership to Manager with explicit host PID values, cleaning monitors/routes on death and stop. Keep generated callbacks unaware of the routing change.

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- Assert prepared invoke/replacement leaves snapshot, artifact selection and dispatched-effect count unchanged. Abort, invalid migration, response-size failure and stale revisions preserve the old state.
- Exercise owner/host death and late publish/abort races, one prepared operation per host, callback count, capacity release, same-PID replacement and explicit Registry-value lookup.
- Extend HTTP tests with a test-controlled pause between prepare/publish: no effect reaches a peer early, disconnect does not cancel an accepted operation, and snapshots after completion match existing Phase 1 outcomes. Run the existing kill/reconnect suite unchanged except for legitimate internal routing expectations.

Every runtime task extends the growing real-HTTP independent-BEAM suite at its
own checkpoint, including relevant failure/abrupt-interruption cases. Observe
actual stored records and live state as well as response codes. No intentionally
failing downstream tests. Investigate unexpected results at their root, prove the
cause with a test and fix the system; after three unsuccessful fix attempts stop
and ask the user for direction.

## Verification commands and acceptance

Run from the repository root after creating the focused test files owned here:

```sh
mix test test/runtime/staged_hosts_test.exs test/runtime/worker_invoke_test.exs test/runtime/replacement_test.exs --warnings-as-errors
mix test test/integration/phase02_staging_test.exs --warnings-as-errors
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

Update runtime API internal commit-order explanation and contributor test-fixture guidance; README capabilities do not change. Preserve memory-mode semantics and document no new restart guarantee.

Intended header: `refactor(runtime): prepare worker changes before publication`. Add a blank line and a nonempty explanatory
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

Final size: 5

Crosses host, Manager and dispatcher contracts but preserves existing memory semantics. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
