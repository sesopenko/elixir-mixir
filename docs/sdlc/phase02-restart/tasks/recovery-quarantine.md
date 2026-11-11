# recovery-quarantine: Isolate invalid retained application records

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

Broken generated records remain inspectable while healthy workers recover and accept operations; global storage faults fail closed.

## Prerequisites and required outputs

Prerequisite IDs: durable-delivery

[durable-delivery](durable-delivery.md) must be verified and committed. Read its completed
outcome and evidence; it supplies the immediately preceding working checkpoint
and all earlier contracts in the governing plan. Do not rely on unfinished
downstream features.

## Implementation and contracts

- Complete isolated validation/quarantine for artifact hash/compile/contract, missing references, schema/state mismatch and invalid effect records. Keep original source/state/intent records intact for diagnosis. No automatic boot migration or endless restart attempts of quarantined code.
- Expose bounded/paginated recovery counts, quarantine diagnostics, storage format/mode, lineage and boot ID through existing inspect/events. Preserve response/state bounds and path/source omission; record recovery diagnostics in bounded audit without copying full source/state.
- Make readiness depend on recovered graph and reconstructed queue, not process existence. Ready-with-quarantines is explicit in inspection; /health is 200 only once healthy reconstruction is complete. Reject mutations before admission while recovery is active.
- Exercise the supported repair workflow: stop affected definition, define/select a valid artifact and explicitly start it. Preserve original evidence. Distinguish global unsupported format/store unreadability/limit overflow from isolated generated-record failures.

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- Corrupt one retained source/hash/contract/state/schema/reference at a time in an owned store with a healthy peer. Actual SIGKILL/reopen proves the peer continues, broken records are unchanged and diagnostics fit at minimum configured response size.
- Test corrupt inactive artifact and pending effect, migration failure retaining old committed state, unknown format and store IO failure, lowered capacity conflict, exhausted restart budget, and recovery barrier readiness/mutation gating.
- Verify safe repair via real HTTP, fresh client initialization and no new production tools or arbitrary source/host path leaks. Kernel authority death stops availability rather than reconstructing from stale memory.

Every runtime task extends the growing real-HTTP independent-BEAM suite at its
own checkpoint, including relevant failure/abrupt-interruption cases. Observe
actual stored records and live state as well as response codes. No intentionally
failing downstream tests. Investigate unexpected results at their root, prove the
cause with a test and fix the system; after three unsuccessful fix attempts stop
and ask the user for direction.

## Verification commands and acceptance

Run from the repository root after creating the focused test files owned here:

```sh
mix test test/runtime/recovery_quarantine_test.exs --warnings-as-errors
mix test test/integration/phase02_quarantine_test.exs --warnings-as-errors
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

Update README limits, contributor fault-injection guidance and API inspection/error contracts. Document repair and global failure behavior; keep Claude Code explicitly untested.

Intended header: `feat(runtime): quarantine broken definitions during recovery`. Add a blank line and a nonempty explanatory
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

Expands existing recovery into a comprehensive fault matrix with bounded diagnostics. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
