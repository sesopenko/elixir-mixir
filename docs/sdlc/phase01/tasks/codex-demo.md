# codex-demo: Isolated startup and actual Codex demonstration

## Startup and context recovery

Implementation: [assignment](../../../prompts/phase01-implementation.md),
[unattended continuation](../../../prompts/phase01-implementation-amendment-04.md).
Corrections: [02](../../../prompts/phase01-dependency-amendment-02.md),
[03](../../../prompts/phase01-dependency-amendment-03.md),
[05](../../../prompts/phase01-transport-amendment-05.md).
Actual client prompts: [session 1](../../../prompts/phase01-demo-session01.md),
[fresh session 2](../../../prompts/phase01-demo-session02.md).

Assignment snapshot: [phase01-planning.md](../../../prompts/phase01-planning.md).
Approved amendment: [amendment 01](../../../prompts/phase01-planning-amendment-01.md).
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

Prerequisite IDs: live-replacement

- [live-replacement](live-replacement.md): all seven MCP tools with the incrementally passing HTTP lifecycle/fault/reconnect suite and coverage record.

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

No unrelated code tests for documentation. Reuse the incrementally built automated HTTP suite as a regression check; no scenario required by an earlier feature may be deferred to this task. Verify image builds, runs unprivileged/read-only with only loopback listener, /health responds, and cleanup removes the disposable container. Inspect image/container config for mounts/capabilities/resource settings; record the commands and outcomes. Validate Markdown links and executable command examples. In the actual Codex transcript, verify all A01–A14 claims, exact aggregate arithmetic, migration failures preserving state, and reconnect identity. Document demonstration evidence separately from ExUnit evidence.

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

- [x] Reread snapshot, governing plan, current task and approved amendments; verify prerequisite commits.
- [x] Finish scoped implementation/documentation and focused unit tests, including relevant failure paths (document-only work uses applicable document checks).
- [x] Pass focused tests and the growing real-HTTP integration suite for currently implemented capabilities; record commands, results and evidence here.
- [x] Pass full `mix check` and resolve every finding; keep the installed pre-commit hook enabled.
- [x] Review diff and stage only the intended task changes, tests and documentation.
- [x] Commit the verified task through the normal hook with Conventional Commit header and explanatory body.
- [x] Only after that working commit exists, select the next task in the plan; this gate also applies to tasks without dependents.

Execution evidence (2026-11-11):

- Verified prerequisite `baabfe9`, reread governing instructions and preserved
  unrelated `scripts/codex.sh`. All domain behavior was created through actual
  Codex MCP calls; the image contains only trusted kernel/release inputs.
- Docker 26.1.5, official Elixir 1.18.3/OTP 27 image manifest digest
  `sha256:fc227cb4b0c568a1f7cf6a8e40269185248cd29204c0d4e95cdefe31f5d1a873`;
  actual runtime OTP 27.3.4/ERTS 15.2.7, app 0.1.0, Linux/amd64.
- `docker build -t elixir-mixir:phase01 .`: passed. Builder installs CA trust for
  verified dependency downloads; production release excludes test fixtures/tooling.
  A reproduced base-VM OOM showed Docker's 1,073,741,816-FD limit causing a
  134,217,727-port table and ~2 GiB system allocation. Release/build flags now cap
  ports at 65,536; the required 512 MiB/128-PID limits remain unchanged.
- Exact documented constrained docker run and curl /health passed. Inspect/actual
  process checks proved UID/GID 1000, read-only root, tmpfs only, dropped caps,
  no-new-privileges, 512 MiB/one CPU/128 PIDs, no host mounts/socket/test fixtures,
  distribution disabled and IPv4 loopback only. A separate same-image container
  started with --network none and returned health 200 ready without downloads.
- `codex mcp add elixir-mixir --url http://127.0.0.1:4100/mcp` and filtered list
  verification passed. Two actual Codex CLI 0.167.1 exec processes exited 0, with
  distinct thread IDs: 51 creation/evolution calls, then 8 fresh read-only calls.
  All seven tools used; original counter/aggregate PIDs, artifact versions/state/
  revisions and generation 23 survived client exit/reconnect. Counter migrated
  to nested schema-2 value 7; aggregate ended events=3,total=12. Rejected amounts,
  source, migration and stale revision preserved active fields; probe log/delay
  delivered once then probe stopped. See sanitized [evidence](../evidence/codex-sessions.json).
- `python3 scripts/verify-phase01-demo.py`: passed; independently recomputes source
  hashes and verifies actual calls/arithmetic/failures/reconnect/isolation/cleanup.
  Original text content was checked equal to structured data before omission;
  no auth, cookies, unrelated settings or agent narration are committed.
- Before/after Docker identity stayed container 6be756fce623, host PID 232827,
  StartedAt 2026-11-11T08:51:26.544177969Z, restart count zero. Actual demo, offline
  startup and version-probe containers were removed and absence verified.
- `mix test test/integration/phase01_runtime_test.exs --warnings-as-errors`:
  28 tests, zero failures, separate from actual Codex evidence.
- Final contract audit reproduced a failed-definition startup mismatch: start could
  change retained artifact/config without the explicit stop required by the plan.
  A focused recovery regression failed before the fix. Startup now rejects those
  changes (including integer/float type differences) with INVALID_ARGUMENT/stop-first hint; same-definition recovery still
  works, and explicit stop permits new artifact/config. Unit and real-HTTP tests
  prove failed-state/revision preservation and successful changed start after stop.
  The release and both actual Codex sessions were rerun against this final code.
- `mix check`: passed; 2 doctests and 151 tests, zero failures, strict Credo clean,
  Doctor 100% documentation/typespec coverage, Dialyzer zero errors.
- Shell syntax, local Markdown links, JSON examples/template syntax, evidence JSON,
  credential-pattern scan and `git diff --check` pass; `.githooks` stays enabled.
  The commit containing this completed checklist is the final checked checkpoint.
- A01–A14 evidence is complete in verification.md. Phase 1 remains in-memory,
  generated code retains BEAM privileges, and host networking is not a network
  sandbox; these are documented scope limits, not missing Phase 1 deliverables.
