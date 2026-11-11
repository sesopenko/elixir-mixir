# evidence-review: Reconcile acceptance evidence and close the phase

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

A reader can trace every Phase 2 acceptance criterion and milestone to committed automated and actual-client evidence.

## Prerequisites and required outputs

Prerequisite IDs: codex-restart-demo

[codex-restart-demo](codex-restart-demo.md) must be verified and committed. Read its completed
outcome and evidence; it supplies the immediately preceding working checkpoint
and all earlier contracts in the governing plan. Do not rely on unfinished
downstream features.

## Implementation and contracts

- Read all checked task documents, relevant commits and verification evidence; confirm every prerequisite has a verified commit. Reconcile plan status, evidence index and milestone exit conditions with actual outcomes.
- Run the structural verifier, check changed documentation links and confirm all fourteen acceptance rows cite evidence rather than promises. Preserve the historical planning-verification record as evidence of planning, not proof of implementation.
- Review README/CONTRIBUTING/API/recovery walkthrough for current behavior, memory/durable distinction, readiness/volume instructions, limitations and actual Codex versus untested Claude claims. Do not introduce missing integration tests or kernel features here.
- If a criterion lacks evidence, keep the phase incomplete and return it to its owning task. Only record completion when all prior checkpoints and demonstrations are verified.

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- Run document/graph/link checks and audit the full criterion-to-evidence mapping. No new unit test is required for this documentation-only task.
- Verify every referenced transcript/manifest/result exists and agrees with worker state, revisions, boot identity and effect outcomes. Verify no executable task has size 13 and no incomplete checklist is represented as complete.

Every runtime task extends the growing real-HTTP independent-BEAM suite at its
own checkpoint, including relevant failure/abrupt-interruption cases. Observe
actual stored records and live state as well as response codes. No intentionally
failing downstream tests. Investigate unexpected results at their root, prove the
cause with a test and fix the system; after three unsuccessful fix attempts stop
and ask the user for direction.

## Verification commands and acceptance

Run from the repository root after creating the focused test files owned here:

```sh
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

Update this phase plan/verification and affected public documentation only where reconciliation requires it. Record phase completion and all checkpoint IDs without rewriting historical evidence.

Intended header: `docs(phase02): reconcile restart recovery acceptance evidence`. Add a blank line and a nonempty explanatory
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

Execution evidence: 2026-11-11, prerequisite `048d531` verified and pushed before
review. All eleven prerequisite task documents and commits have verified checklists,
explanatory bodies and ordered origin ancestry. The final acceptance table maps
all fourteen ADR criteria and milestones 5–7 to inspected persisted/live assertions
and actual Codex artifacts. Growing suite passes 122 tests; full `mix check` passes
280 tests, two doctests, Doctor 100%, strict Credo and Dialyzer zero errors/skips.
Both client evidence verifiers pass (59 Phase 1 calls; 44 Phase 2 calls). Structural
verification passes; 206 local/heading links across 21 current documents and diff
checks pass. Public guidance is reconciled without changing client syntax, runtime
code or tests. Claude Code remains explicitly untested. See the
[review entry](../verification.md#evidence-review) and
[acceptance table](../verification.md#acceptance-and-milestone-evidence).

## Relative size

Final size: 1

Smallest task: document verification and reconciliation against existing evidence, with no feature work. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
