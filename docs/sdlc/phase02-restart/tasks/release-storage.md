# release-storage: Retain durable storage in the supported local release

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

The documented isolated Linux release can be killed and recreated with its application restored from an explicitly retained writable volume.

## Prerequisites and required outputs

Prerequisite IDs: recovery-quarantine

[recovery-quarantine](recovery-quarantine.md) must be verified and committed. Read its completed
outcome and evidence; it supplies the immediately preceding working checkpoint
and all earlier contracts in the governing plan. Do not rely on unfinished
downstream features.

## Implementation and contracts

- Extend Docker/release demonstration configuration with an explicit data volume mounted at /data and ELIXIR_MIXIR_DATA_DIR=/data. Keep the root filesystem read-only, runtime permissions minimal, loopback transport and temporary release files separate. Verify non-root write permissions without making source or credentials writable.
- Provide exact commands to create/reuse the volume, wait for readiness, initialize a fresh MCP session, SIGKILL the owned container and recreate it with the same volume. Keep normal shutdown and deliberate volume deletion distinct; never delete a user's data volume automatically.
- Keep current memory-mode disposable workflow available with its explicit loss-of-state explanation. Update README/CONTRIBUTING Codex and Claude connection examples consistently; do not claim Claude verification from runtime tests.
- Add release smoke coverage for permissions/config/readiness and a retained-volume automated HTTP journey. Reuse the existing passing SIGKILL suite; no runtime integration is deferred here.

Use the governing plan's resolved storage, identity, commit, recovery, error and
capacity contracts. Maintain public documentation/typespec coverage and existing
quality thresholds. This task's intermediate guarantees must be explicit; advertise
no unfinished capability and add no placeholders requiring future code to pass tests.

## Focused tests and continuous integration

- Build the production release/image and show that generated code/test controls/credentials are excluded as before. Exercise an empty writable volume, reused volume and unwritable path; no silent memory fallback.
- Automated real-HTTP define/start/invoke, abrupt container termination and recreation restores state with a new boot and accepts a further invocation. Record actual commands and outcomes; Docker is required for this task-specific check, not ordinary ExUnit.
- Validate all edited local links and shell examples; verify readiness waits, endpoint/port overrides and new MCP-session guidance match both client sections. Official client syntax must be reverified if changed.

Every runtime task extends the growing real-HTTP independent-BEAM suite at its
own checkpoint, including relevant failure/abrupt-interruption cases. Observe
actual stored records and live state as well as response codes. No intentionally
failing downstream tests. Investigate unexpected results at their root, prove the
cause with a test and fix the system; after three unsuccessful fix attempts stop
and ask the user for direction.

## Verification commands and acceptance

Run from the repository root after creating the focused test files owned here:

```sh
mix test test/runtime/storage_config_test.exs --warnings-as-errors
mix test test/integration/phase02_release_config_test.exs --warnings-as-errors
mix test test/mcp test/integration --warnings-as-errors
python3 docs/sdlc/phase02-restart/verify-plan.py
mix check
git diff --check
git config --get core.hooksPath
```

Also run `docker build -t elixir-mixir:phase02 .` and the retained-volume smoke
procedure documented by this task in `docs/phase02-recovery.md`; record its exact
commands, OS kill evidence and state assertions. Keep the named volume for the
next demo only if explicitly designated as that demo's otherwise empty store.

All focused behavior/failure assertions above must pass, alongside the growing
integration suite and full `mix check`. Exact new test filenames above are planned
outputs, not claims they exist in the baseline. Existing named test files must be
located before use if repository organization has changed. The hook path must be
`.githooks`; if absent, install with `./scripts/install-git-hooks.sh`. Never bypass
the installed pre-commit hook or lower quality thresholds. Record actual command
results and evidence; planning checks alone do not satisfy runtime acceptance.

## Documentation and intended commit

Update README and CONTRIBUTING together, plus a focused docs/phase02-recovery.md walkthrough. Include exclusive store ownership, volume lifetime, readiness wait and supported Linux assumptions.

Intended header: `feat(release): retain the application across local runtime restarts`. Add a blank line and a nonempty explanatory
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

Small deployment/configuration change using an already tested recovery runtime. Assigned during the late sizing pass; see the plan's original-13
split record. No executable task may retain size 13.
