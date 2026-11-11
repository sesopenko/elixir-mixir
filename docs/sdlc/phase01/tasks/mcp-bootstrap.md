# mcp-bootstrap: Independent localhost MCP status server

## Startup and context recovery

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

A separately launched Mix process exposes Streamable HTTP at 127.0.0.1:4100/mcp and one working runtime_inspect tool; disconnecting a client leaves the application alive.

## Prerequisites and required outputs

Prerequisite IDs: kernel-api

- [kernel-api](kernel-api.md): bounded values/errors, request ledger, Manager sequencing/status.

A prerequisite is complete only after its focused verification, full `mix check`,
and working commit through the installed hook. Read the plan's resolved contracts;
this task refines those contracts and does not authorize architectural alternatives.

## Concrete implementation steps and components

Add exactly pinned Hermes, Plug and Bandit dependencies from the plan; retain Jason and :crypto from kernel-api. Fetch and lock compatible transitive dependencies. Check `mix deps.tree` and compiled APIs against the official published source references; do not adopt conflicting unversioned README examples. Keep quality dependencies development-only.
Create `MCP.Server`, `MCP.Router`, a bounded ingress/Origin/Host wrapper, and `MCP.Tools.RuntimeInspect`. Register only the implemented tool. Start Hermes registry/server before Bandit as specified in the plan; initialize the forwarding plug after registry startup. Use runtime port config, loopback-only address, and no listener in ordinary unit tests; explicitly start ephemeral-port HTTP fixtures in integration tests.
Implement GET /health returning readiness/API version, exact /mcp routing, input validation, bounded JSON errors/results, and empty 202 notification normalization if the package needs it. Reject unexpected Host/Origin, overlarge bodies, malformed JSON, and non-loopback normal configuration. Disable verbose Hermes request/source logging. Document independent `mix run --no-halt` startup and connection commands. Do not add downstream tool stubs.

Build the shared MCP test client now under test/support using OTP :httpc/:inets (test only), with required Accept headers, JSON/SSE framing, session propagation, finite deadlines and explicit close/reinitialize. Build a reusable independent BEAM fixture now: launch via an OS port with ephemeral configured loopback listener, wait for readiness, keep runtime lifetime independent of client sessions, and always clean up OS processes/sockets on failure. A test-only controller loaded in the fixture BEAM may signal barriers or kill hosts through the harness; it must never become a production HTTP tool or be included in production startup. Later feature tasks extend this fixture and existing HTTP suite, rather than building a new harness at the end.
Establish common adapter validation and response helpers now: unknown-key/type rejection, API/protocol versioning, stable bounded isError envelopes, JSON text plus structured content as supported, and full wire-size preflight including duplicated/escaped content. Add read-only server instructions that describe the currently available tool; feature tasks extend them with request/revision/effect contracts. Keep helper APIs documented/typed and quality tooling unchanged.

## Interfaces, inputs, outputs and errors

Use the exact Hermes child/component/response APIs in the plan. `runtime_inspect` accepts optional detail/worker_id/limit/cursor but only empty runtime inspection is currently meaningful; unknown worker returns WORKER_NOT_FOUND. Successful initialize negotiates protocol 2025-03-26, then notifications/initialized and tools/list expose runtime_inspect with its schema. JSON-RPC IDs echo correctly; they are separate from later mutation request IDs.
GET /mcp supports SSE as Hermes implements it; POST accepts the required Accept header and handles JSON or SSE responses. HTTP invalid input returns appropriate bounded 4xx/protocol errors; runtime errors use isError tool results. GET /health succeeds only when Manager and server are ready. Bind failure must fail startup clearly.

Use the governing plan's exact limits, errors, callback contracts, revision semantics,
and Phase 1 in-memory boundaries. Document public APIs with accurate docs/specs and
struct types; do not lower Doctor/Credo/Dialyzer thresholds.

## Focused tests, integration checks and failure scenarios

Create `test/mcp/bootstrap_test.exs` for schemas, serialization, ingress bounds, header validation, readiness, invalid paths/methods/config, and runtime_inspect errors. Create `test/integration/mcp_bootstrap_test.exs` using the shared independent BEAM fixture and real TCP on an ephemeral loopback port: initialize, initialized notification, tools/list, inspect, close client, new client inspect. Capture the runtime OS/process identity and assert it survives reconnect. Test JSON and SSE decoding, session header propagation, and notification framing. Use :httpc with bounded timeouts, no external MCP client dependency.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root after implementing this task:

```sh
mix test test/mcp/bootstrap_test.exs test/integration/mcp_bootstrap_test.exs --warnings-as-errors
mix deps.tree
mix check
git diff --check
git config --get core.hooksPath
```

Dependency resolution/compilation succeeds on Elixir 1.18.3 / OTP 27; real HTTP handshake and inspect pass; advertised tool count is one at this checkpoint (update exact discovery assertions with each later feature); listener is loopback-only and independent of client.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Update README and CONTRIBUTING with current endpoint, startup, readiness, independent client lifetime, and trusted disposable execution requirement. Create docs/sdlc/phase01/verification.md now with actual automated evidence and clearly pending Codex evidence; update it in each feature task. Commit mix.exs/mix.lock, config, transport, shared adapter/test helpers, inspect adapter, tests, and docs as `feat(mcp): expose the independent runtime over localhost HTTP`.

Use a Conventional Commit header, blank line, and nonempty explanatory body stating
why this capability was needed and why the approach fits. Stage only this task's
verified changes. The commit containing the completed checklist identifies the
checkpoint; no self-referential commit hash is needed inside the commit.

## Mandatory completion checklist

- [ ] Reread snapshot, governing plan, current task and approved amendments; verify prerequisite commits.
- [ ] Finish scoped implementation/documentation and focused unit tests, including relevant failure paths (document-only work uses applicable document checks).
- [ ] Pass focused tests and the growing real-HTTP integration suite for currently implemented capabilities; record commands, results and evidence here.
- [ ] Pass full `mix check` and resolve every finding; keep the installed pre-commit hook enabled.
- [ ] Review diff and stage only the intended task changes, tests and documentation.
- [ ] Commit the verified task through the normal hook with Conventional Commit header and explanatory body.
- [ ] Only after that working commit exists, select the next task in the plan; this gate also applies to tasks without dependents.

Execution evidence: pending implementation.
