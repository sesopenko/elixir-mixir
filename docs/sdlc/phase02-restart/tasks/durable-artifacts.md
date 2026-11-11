# durable-artifacts: Retain source definitions and request outcomes

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

An HTTP-defined artifact and its request result survive SIGKILL and are recompiled without an LLM; definition retries do not create another revision.

## Prerequisites and required outputs

Prerequisite IDs: staged-hosts

[staged-hosts](staged-hosts.md) must be verified and committed. Read its completed
outcome and evidence; it supplies the immediately preceding working checkpoint
and all earlier contracts in the governing plan. Do not rely on unfinished
downstream features.

## Implementation and contracts

- Implement persisted request admission and completion in Manager/Store, with unique operation IDs, argument hashes, wall-clock deadlines and existing capacity/retention. Convert incomplete external admissions at boot to retained OPERATION_INTERRUPTED outcomes. Keep malformed pre-admission validation failures unrecorded as today.
- Stage compilation using current limits, then atomically commit source/metadata, logical revision, generation, outcome and audit before registry publication. Completed compilation errors retain bounded failure outcomes but consume the current BEAM slot as before. Store uncertainty closes availability; never falsely return a rollback.
- Use opaque random artifact IDs; update tests that coupled identity to slots. Add registry restoration that preserves artifact IDs/revisions while allocating fresh fixed slots deterministically in sorted ID order. Persist original module identity as diagnostic metadata, not an executable atom. Rebuild revision high-water marks, enforce retained artifact capacity and never reset the BEAM-lifetime counter on application restart.
- Add basic recovery continuation/readiness now, not only in recovery-quarantine. Validate hashes/contracts before recompilation; retain invalid artifacts as diagnostic entries without activation. Until lifecycle integration, durable start/stop/invoke/replace stay gated.

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- Define via real HTTP, SIGKILL, start with the same directory and no client, then inspect retained source/hash/ID/revision through bounded test control. New definition of the logical name advances the saved revision; no arbitrary disk text becomes an atom.
- Kill after admission, after compilation before durable commit, and after commit before response/registry publish. Verify interrupted rejection or exact committed replay with one artifact; compare database contents as well as HTTP results.
- Test retained request conflict, error replay, expiry including downtime/backward clock, ledger capacity and capacity after restored artifacts. Confirm old module diagnostic replay does not claim a current handle. Corrupt one inactive source/hash and retain its evidence.

Every runtime task extends the growing real-HTTP independent-BEAM suite at its
own checkpoint, including relevant failure/abrupt-interruption cases. Observe
actual stored records and live state as well as response codes. No intentionally
failing downstream tests. Investigate unexpected results at their root, prove the
cause with a test and fix the system; after three unsuccessful fix attempts stop
and ask the user for direction.

## Verification commands and acceptance

Run from the repository root after creating the focused test files owned here:

```sh
mix test test/runtime/durable_artifacts_test.exs test/runtime/durable_requests_test.exs --warnings-as-errors
mix test test/integration/phase02_artifacts_test.exs --warnings-as-errors
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

Update README and runtime API with opt-in durable artifact support, historical diagnostics, interrupted-operation handling and request-expiry limits. CONTRIBUTING gets the repeatable artifact SIGKILL test command.

Intended header: `feat(storage): recover generated definitions and their outcomes`. Add a blank line and a nonempty explanatory
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

Adds artifact identity, compilation restoration and reusable durable admission without worker restoration. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
