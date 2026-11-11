# durable-lifecycle: Commit the desired graph and restore initial worker state

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

Started and stopped logical definitions survive an abrupt restart with their committed initial state and fresh live hosts.

## Prerequisites and required outputs

Prerequisite IDs: durable-artifacts

[durable-artifacts](durable-artifacts.md) must be verified and committed. Read its completed
outcome and evidence; it supplies the immediately preceding working checkpoint
and all earlier contracts in the governing plan. Do not rely on unfinished
downstream features.

## Implementation and contracts

- Durable start runs bounded init in an unroutable candidate, validates/preflights, then commits worker/config/initial state/schema/revisions/outcome before publishing routing. Failed commit removes the candidate; uncertain commit shuts authority down for recovery.
- Durable stop commits desired stopped status and outcome before terminating/unregistering. Preserve no-op repeat-stop and retained definitions; stopped records remain stopped on boot. Explicit restart continues to initialize from supplied config.
- Restore sorted desired-running definitions by injecting validated committed state through an internal constructor, without calling init or migrate. Preserve artifact IDs and committed revisions; allocate new hosts/monitors/routes. Boot identity rather than PID-string inequality proves a new process lifetime.
- Persist lifecycle status and restart-budget wall timestamps. Restore exhausted/failed definitions as failed; stop cancels pending retries. Initially a durable host crash restores its committed initial state because invoke remains gated; durable-transitions expands the same path to updated state.
- Gate readiness until validation, recompile, host restoration and routing finish. Keep basic bounded local quarantine on unusable references/schema from this first restoration task; the later recovery task broadens fault coverage and diagnostics.

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- HTTP define/start/inspect/stop two linked-by-config workers, kill the VM, restart with no MCP client and verify same logical IDs/config/artifacts, initial state/revisions and stopped status. New boot ID/OS process plus observed host creation prove reconstruction even if printed PIDs repeat.
- Test init failure, timeout, duplicate start, stop replay, failed-definition edit restriction, candidate route invisibility and stale DOWN/retry tokens. Kill on both sides of start/stop commit; assert an entirely old or committed definition and outcome.
- Health is 503 while a recovery barrier is held, mutations cannot enter, healthy routes appear together at readiness and schema mismatch does not execute migration. Exhaustion does not reset merely because BEAM restarted.

Every runtime task extends the growing real-HTTP independent-BEAM suite at its
own checkpoint, including relevant failure/abrupt-interruption cases. Observe
actual stored records and live state as well as response codes. No intentionally
failing downstream tests. Investigate unexpected results at their root, prove the
cause with a test and fix the system; after three unsuccessful fix attempts stop
and ask the user for direction.

## Verification commands and acceptance

Run from the repository root after creating the focused test files owned here:

```sh
mix test test/runtime/durable_lifecycle_test.exs --warnings-as-errors
mix test test/integration/phase02_lifecycle_test.exs --warnings-as-errors
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

Update README, CONTRIBUTING and runtime API for milestone 5, no-LLM restoration, explicit-start versus recovery semantics, fresh MCP sessions and readiness waits. State that invocation/replacement durability is still pending.

Intended header: `feat(runtime): reconstruct committed logical worker definitions`. Add a blank line and a nonempty explanatory
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

Coordinates initialization, routing, desired status and no-client boot recovery across several failure windows. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
