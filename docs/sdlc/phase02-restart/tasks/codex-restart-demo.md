# codex-restart-demo: Demonstrate actual Codex recovery and continued evolution

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

Recorded actual Codex MCP sessions create and evolve the application, then reconnect and modify its automatically recovered state.

## Prerequisites and required outputs

Prerequisite IDs: release-storage

[release-storage](release-storage.md) must be verified and committed. Read its completed
outcome and evidence; it supplies the immediately preceding working checkpoint
and all earlier contracts in the governing plan. Do not rely on unfinished
downstream features.

## Implementation and contracts

- Preserve the demonstration instructions under docs/prompts before execution and link them here. Use an empty dedicated durable volume in the supported isolated environment; capture lineage/boot IDs and artifacts/workers/revisions without secrets.
- Have actual Codex use MCP to define a counter/aggregator, accumulate known state, replace the counter with explicit migration where applicable and verify behavior. Arrange and record a durable pending timer/effect using a testable delay and pre-kill inspection.
- Disconnect Codex, SIGKILL the BEAM/container, recreate the runtime with the same store and no LLM/client attached. Use the existing automated HTTP inspector to verify readiness, selected revisions, committed values and scheduled-work completion before starting the second Codex session.
- Connect a fresh actual Codex session, inspect then invoke/replace the recovered application and verify another behavior change. Keep application behavior authored through MCP, not production lib/. Store bounded/redacted session transcripts, commands, expected/observed values and manifest/effect evidence under this phase's evidence directory.
- Reuse passing unit/integration tests; fix any root cause in the owning feature with a regression test and a verified commit rather than hiding a runtime change in demonstration artifacts. If actual client/tool access is unavailable, leave the task pending and report the blocker; never substitute simulated transcripts.

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- Rerun the existing automated recovery journey before the actual demo. Verify each ADR 10.8 step against recorded evidence, especially no connected LLM during restore and actual post-restart mutation through Codex.
- Distinguish fresh host construction from coincidental reuse of printed PIDs using boot/OS-process identity. Verify timer/effect evidence includes a pending durable record before kill and completed/failed outcome afterward with exact state.
- Validate transcript redaction, local links, all seven tool availability, revision/state arithmetic and session provenance. Ordinary automated tests are not evidence that Codex or Claude was actually used.

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

Also execute the preserved actual Codex demo prompts using the existing documented
client connection workflow, and the recovery walkthrough's exact SIGKILL/restart
commands. Record both session IDs, MCP call evidence and the no-client recovery
interval. Automated HTTP execution alone cannot complete this task.

All focused behavior/failure assertions above must pass, alongside the growing
integration suite and full `mix check`. Exact new test filenames above are planned
outputs, not claims they exist in the baseline. Existing named test files must be
located before use if repository organization has changed. The hook path must be
`.githooks`; if absent, install with `./scripts/install-git-hooks.sh`. Never bypass
the installed pre-commit hook or lower quality thresholds. Record actual command
results and evidence; planning checks alone do not satisfy runtime acceptance.

## Documentation and intended commit

Update recovery walkthrough and phase verification with the actual demonstration. README may claim the demonstrated behavior only once evidence exists; preserve the Claude Code untested qualification.

Intended header: `docs(phase02): prove Codex can evolve a recovered application`. Add a blank line and a nonempty explanatory
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

Requires two real client sessions and carefully preserved runtime/effect evidence; no new kernel behavior. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
