# runtime-integration: Automated end-to-end lifecycle and failure verification

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

A reproducible real-HTTP suite proves Phase 1 runtime behavior and failure boundaries independently of an LLM client.

## Prerequisites and required outputs

Prerequisite IDs: mcp-tools

- [mcp-tools](mcp-tools.md): seven working MCP adapters and schemas.

A prerequisite is complete only after its focused verification, full `mix check`,
and working commit through the installed hook. Read the plan's resolved contracts;
this task refines those contracts and does not authorize architectural alternatives.

## Concrete implementation steps and components

Create test/support HTTP MCP client using OTP :httpc/:inets in test only, correct Accept/session headers, JSON/SSE response framing, finite deadlines and explicit close/reinitialize. Add dedicated independent BEAM fixture launched with an OS port and ephemeral configured loopback port; tests own cleanup, but the MCP client does not own runtime startup. Assert OS process identity across disconnect/reconnect.
Create `test/integration/phase01_runtime_test.exs` to drive all application behavior through seven MCP tools: define/start/invoke counter, aggregator, effects, replace and migrate. Keep generated fixture strings under test/support, never in lib/. Exercise resource boundaries at reduced configuration then maximum response payload tests. Use bounded eventual assertions and process monitors, not unbounded sleeps. Maintain tests inside mix check without requiring Codex credentials or Docker.
Inject a real host kill from kernel test control (not a new MCP tool), prove healthy peer and HTTP remain responsive and restart budget terminates. Close client during a mutation, reconnect with same request_id and assert one commit. Record A01–A14 automated coverage separately from pending actual-Codex evidence. Add standalone invocation docs for this suite.

## Interfaces, inputs, outputs and errors

This task adds no production tools or new runtime semantics. Existing public interfaces must suffice for observable behavior; test-only kill/control hooks must not be shipped in production API. New session means initialize again, not assuming prior transport session survives. Runtime identity includes OS/BEAM identity and generation continuity, host PIDs/state. HTTP disconnect must not implicitly cancel accepted mutation. Retry result must correspond to actual state/effect count.

Use the governing plan's exact limits, errors, callback contracts, revision semantics,
and Phase 1 in-memory boundaries. Document public APIs with accurate docs/specs and
struct types; do not lower Doctor/Credo/Dialyzer thresholds.

## Focused tests, integration checks and failure scenarios

Test complete counter/aggregator lifecycle, two successive normal replacements, same-schema retention and explicit schema migration; compare PID before/after. Test invalid source/missing callbacks, failed migration variants and revision races while asserting actual active state. Test host failure isolation, failed init restart exhaustion, callback timeout and healthy peer service. Test missing/conflicting/replayed request IDs, source/module/worker/state/event/effect/timer/hop/history/response limits, and ingress body bounds. Test client socket/SSE close and fresh HTTP session while BEAM remains alive; retry an interrupted invoke produces one increment and one aggregate delivery. Each scenario cleans workers/timers/OS processes on failure.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root after implementing this task:

```sh
mix test test/integration/phase01_runtime_test.exs --warnings-as-errors
mix test test/runtime test/mcp test/integration --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

All automated scenarios pass without LLM/network credentials; no worker error terminates HTTP; reconnect preserves BEAM/host/state; actual state assertions substantiate every response and bounded-resource claim.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Update docs/runtime-api.md and `docs/sdlc/phase01/verification.md` with commands, test coverage, limitations, and clearly pending Codex evidence. Commit integration fixtures/tests/docs as `test(runtime): prove live evolution and fault isolation over MCP`.

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
