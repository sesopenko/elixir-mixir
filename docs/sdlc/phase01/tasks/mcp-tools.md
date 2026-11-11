# mcp-tools: Complete seven-tool MCP control surface

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

All seven architecture tools are discoverable through the existing HTTP server and delegate to verified Manager operations with consistent bounded results.

## Prerequisites and required outputs

Prerequisite IDs: mcp-bootstrap, live-replacement

- [mcp-bootstrap](mcp-bootstrap.md): independent Hermes/Bandit server and real HTTP test fixture.
- [live-replacement](live-replacement.md): verified replacement/migration/revision APIs.

A prerequisite is complete only after its focused verification, full `mix check`,
and working commit through the installed hook. Read the plan's resolved contracts;
this task refines those contracts and does not authorize architectural alternatives.

## Concrete implementation steps and components

Add MCP tool components for define/start/replace/invoke/stop/events and retain inspect. Use explicit exact runtime_* names and documented schemas with required/optional fields, no unknown keys. Reuse kernel validation, request ledger, response preflight and errors; never compile or call generated behavior in a Hermes frame/process.
Implement the common envelope and tool-error mapping with Hermes Response APIs verified in the plan. Include JSON text and structured data as negotiated/supported; preflight entire response including duplicate content, escaping, protocol fields. Preserve incoming mutation request ID across compiler/host/effects/history and across HTTP sessions. Add server instructions describing inspect-before-mutate, revision checks, request retention and local trusted execution.
Update API reference with copyable valid template and seven request/response examples, including failures. Do not change callback or transport architecture while writing adapters.

## Interfaces, inputs, outputs and errors

All tool inputs/outputs, error codes, protocol/API versions and MCP isError semantics are fixed in the plan. runtime_stop requires request_id despite ADR section 7.6 omitting an explicit field list. runtime_inspect/runtime_events are read-only and need no mutation ID. Schema violations are reported before Manager mutation; valid request-level runtime failures are tool errors rather than unstructured exceptions. Oversized mutations are rejected before state commit. Never expose BEAM/module internals except documented bounded diagnostics.

Use the governing plan's exact limits, errors, callback contracts, revision semantics,
and Phase 1 in-memory boundaries. Document public APIs with accurate docs/specs and
struct types; do not lower Doctor/Credo/Dialyzer thresholds.

## Focused tests, integration checks and failure scenarios

Create `test/mcp/tools_test.exs`: tools/list contains exactly seven distinct names with correct schemas; each adapter success and stable error envelope; malformed types/unknown fields/missing request IDs; ID replay/conflict across sessions; revision conflict; absent callbacks; compiler/migration failures; unicode/escaping and maximum-size response preflight. Assert adapters reach Manager (e.g. worker/registry state) and no tool retains separate authoritative state. Update the bootstrap test tool-list expectation from its initial single tool to the complete seven-tool set. Extend HTTP tests to invoke all seven tools with actual handshake/session headers and parse JSON/SSE responses.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root after implementing this task:

```sh
mix test test/mcp/tools_test.exs test/integration/mcp_bootstrap_test.exs --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

Exactly seven tools execute over Streamable HTTP; runtime errors preserve stable codes/correlation and bounded wire size; request replay cannot duplicate an increment/effect.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Update docs/runtime-api.md and README tool table/versions/examples. Commit components/server instructions/response adapter/tests as `feat(mcp): expose the complete live runtime control contract`.

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
