# codex-demo: Isolated startup and actual Codex demonstration

## Startup and context recovery

Assignment snapshot: [phase01-planning.md](../../../prompts/phase01-planning.md).
Governing plan: [plan.md](../plan.md). Current task: this document.
Before starting this subtask and after every compaction, both planning and
implementation agents must reread the complete snapshot, governing plan, this task,
and separately recorded approved amendments. A compaction summary does not replace
these reads. Save complete new assignment instructions under `docs/prompts/` before
other work and identify that snapshot in its work plan; preserve originals and put
approved amendments in separate files. If documents are absent, read available
governing documents and partial drafts. Also read `AGENTS.md`, `CONTRIBUTING.md`,
and ADR-001. After a full context clear or new session, inspect `git status --short`,
`git log --oneline -15`, relevant commits and verification evidence to determine
progress from repository state and committed work. If task selection is unclear,
use the plan execution order and verify completed prerequisites first. Preserve
unrelated changes, including `scripts/codex.sh`.

## Objective and observable outcome

A fresh Codex session constructs and evolves the local counter/aggregator exclusively through MCP, disconnects, then another session observes the same living application; committed evidence closes Phase 1.

## Prerequisites and required outputs

Prerequisite IDs: runtime-integration

- [runtime-integration](runtime-integration.md): passing real HTTP fault/reconnect suite and coverage record.

A prerequisite is complete only after its focused verification, full `mix check`,
and working commit through the installed hook. Read the plan's resolved contracts;
this task refines those contracts and does not authorize architectural alternatives.

## Concrete implementation steps and components

Add Dockerfile/.dockerignore and tested Linux disposable startup commands matching plan isolation constraints. Resolve the Elixir 1.18.3/OTP 27 base image against the official image manifest, pin the verified digest, prefetch/build dependencies at image build time, build an OTP release and run bin/elixir_mixir start as nonroot with no credentials or source mounts. Disable distribution and put release temporary files under /tmp so read-only startup does not invoke Mix or fetch dependencies. Document read-only/tmpfs/host-loopback networking, memory/CPU/PID bounds, shutdown/cleanup, and disposable Linux VM alternative. Verify image startup works without runtime dependency downloads.
Update README/CONTRIBUTING for independent runtime process, /health readiness, endpoint/port config, codex mcp add/list, troubleshooting Origin/bind/session failures, and state loss on BEAM restart. Add root ARCHITECTURE.md as an entry point linking ADR-001 and docs/runtime-api.md, documenting resolved choices and Phase 2 seams without duplicating the ADR text.
Create `examples/phase_1_demo.md` with prompts, exact assertions and transcript format. Then actually run the prompts through Codex MCP tools on a fresh empty isolated runtime. Do not edit kernel/source/fixtures to create domain behavior. Capture sanitized tool calls/results, before/after identity/state, failures and reconnect. Record exact runtime/client versions and artifact hashes/revisions in verification.md. If Codex access or isolation prerequisites are unavailable, leave task incomplete and report the concrete external requirement; automated HTTP results cannot substitute for this demonstration.

## Interfaces, inputs, outputs and errors

Use only the seven documented MCP tools for domain behavior. Build counter v1 with count=0, increment once to 1. Define/start aggregator count=0,total=0. Define counter v2 same schema with emit of new count, replace using current worker_revision, increment twice: counter=3, aggregator events=2,total=5. Define counter v3 accepting positive amount, retain count/PID, invoke amount=4: counter=7, aggregator events=3,total=12. Reject zero/negative amount without change.
Also define a schema-changing v4 that migrates count into an explicitly versioned map, preserve value 7, then prove failure cases against this state: invalid define, a valid candidate with failing migrate, and stale expected_revision. Inspect actual state/artifact/PID after every rejection. Exercise structured log/delay as separate observed effects without altering the arithmetic above. Kill a worker only in automated test evidence; demo can show callback failure without introducing an eighth tool.
Exit Codex entirely, keep runtime container/process alive, launch a fresh Codex session and inspect the same runtime/PIDs/state/artifact versions. Actual MCP call transcript is required; a shell curl or direct Manager call is not Codex evidence.

Use the governing plan's exact limits, errors, callback contracts, revision semantics,
and Phase 1 in-memory boundaries. Document public APIs with accurate docs/specs and
struct types; do not lower Doctor/Credo/Dialyzer thresholds.

## Focused tests, integration checks and failure scenarios

No unrelated code tests for documentation. Re-run the automated HTTP suite as a regression check. Verify image builds, runs unprivileged/read-only with only loopback listener, /health responds, and cleanup removes the disposable container. Inspect image/container config for mounts/capabilities/resource settings; record the commands and outcomes. Validate Markdown links and executable command examples. In the actual Codex transcript, verify all A01–A14 claims, exact aggregate arithmetic, migration failures preserving state, and reconnect identity. Document demonstration evidence separately from ExUnit evidence.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root after implementing this task:

```sh
mix test test/integration/phase01_runtime_test.exs --warnings-as-errors
docker build -t elixir-mixir:phase01 .
docker run -d --name elixir-mixir-phase01 --network host --read-only --tmpfs /tmp:rw,noexec,nosuid,size=128m --cap-drop ALL --security-opt no-new-privileges --memory 512m --cpus 1 --pids-limit 128 elixir-mixir:phase01
curl --fail http://127.0.0.1:4100/health
codex mcp add elixir-mixir --url http://127.0.0.1:4100/mcp
codex mcp list
codex
docker inspect elixir-mixir-phase01
docker rm -f elixir-mixir-phase01
mix check
git diff --check
git config --get core.hooksPath
```

Actual Codex transcript closes A01–A14 with a continuously running local BEAM and unchanged normal-replacement PIDs; startup/isolation/connection instructions reproduce; all documentation links work and no domain module was added to lib/.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Commit Docker setup, README/CONTRIBUTING/ARCHITECTURE entry point, examples/phase_1_demo.md and sanitized docs/sdlc/phase01/verification.md evidence as `docs(phase01): make live genesis reproducible through Codex`. Include any necessary startup packaging changes and their focused regression checks in this same verified scope. Do not claim completion until the actual demonstration has run.

Use a Conventional Commit header, blank line, and nonempty explanatory body stating
why this capability was needed and why the approach fits. Stage only this task's
verified changes. The commit containing the completed checklist identifies the
checkpoint; no self-referential commit hash is needed inside the commit.

## Mandatory completion checklist

- [ ] Reread snapshot, governing plan, current task and approved amendments; verify prerequisite commits.
- [ ] Finish scoped implementation/documentation and focused unit tests, including relevant failure paths (document-only work uses applicable document checks).
- [ ] Pass focused tests and every task-specific verification above; record commands, results and evidence here.
- [ ] Pass full `mix check` and resolve every finding; keep the installed pre-commit hook enabled.
- [ ] Review diff and stage only the intended task changes, tests and documentation.
- [ ] Commit the verified task through the normal hook with Conventional Commit header and explanatory body.
- [ ] Only after that working commit exists, select the next task in the plan; this gate also applies to tasks without dependents.

Execution evidence: pending implementation.
