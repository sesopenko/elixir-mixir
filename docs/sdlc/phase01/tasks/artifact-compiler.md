# artifact-compiler: Generated contract and immutable artifact compilation

## Startup and context recovery

Implementation assignment: [resume Phase 1](../../../prompts/phase01-implementation.md).
Continuation: [amendment 04](../../../prompts/phase01-implementation-amendment-04.md).
Transport/lifetime: [amendment 05](../../../prompts/phase01-transport-amendment-05.md).
Dependency corrections: [02](../../../prompts/phase01-dependency-amendment-02.md),
[03](../../../prompts/phase01-dependency-amendment-03.md).
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

Valid template source becomes a uniquely addressed inactive immutable artifact with verified callbacks and schema; rejected definitions cannot change existing artifacts.

## Prerequisites and required outputs

Prerequisite IDs: mcp-bootstrap

- [mcp-bootstrap](mcp-bootstrap.md): Manager foundation, common MCP schemas/envelopes, independent BEAM fixture and reusable HTTP client.

A prerequisite is complete only after its focused verification, full `mix check`,
and working commit through the installed hook. Read the plan's resolved contracts;
this task refines those contracts and does not authorize architectural alternatives.

## Concrete implementation steps and components

Create `ElixirMixir.Behavior` and runtime Compiler/ArtifactRegistry. Implement all four callback signatures from the plan, including mandatory migrate and state_schema, with executable examples and documented JSON constraints. Start compiler Task.Supervisor and registry before Manager.
Add Manager.define/1 with request-ledger semantics. Reserve a non-reusable lifetime slot before parsing; preallocate the 128 fixed generated module names. Validate one outer Generated template, rewrite its alias, reject nested/dynamic module construction, compile quoted AST in an unlinked monitored task with a synthetic filename and Code.with_diagnostics. Bound source, attempts, duration, diagnostics, and compiler-task heap (64 MiB compiler, 8 MiB callback; convert bytes to VM words for max_heap_size before user work). Validate exactly one output module, exported callbacks, and bounded positive schema callback.
Registry is append-only: store source/hash/BEAM/module/logical name/revision/contract/schema and diagnostics only on success. Consume failed slots and never reuse or purge artifacts in Phase 1. Compilation failure must neither activate code nor advance generation. Do not add dynamic dependency resolution or write generated source into lib/. Record compile events through a minimal bounded EventLog introduced here, reused in runtime-inspection.

Add MCP.Tools.RuntimeDefine in this same checkpoint, delegating only to Manager.define/1 with the plan's exact schema, request ID and stable error envelope. Extend tools/list to exactly inspect/define and add tests in test/mcp/tools_test.exs using the shared validation/response helpers. Extend server instructions and docs with the currently supported contract; no downstream worker tool stubs.
Start test/integration/phase01_runtime_test.exs with the first generated-source journey through real HTTP: valid define, invalid source, absent callbacks, warning/timeout/bounds failures, same request replay and different-payload conflict, artifact/revision/hash identity, and bounded text/structured errors. Confirm a new HTTP session sees the same artifact registry/generation and replays define without a second compile. Inspect immutable registry state through test controls where no artifact-specific public query exists; do not add a testing tool.

## Interfaces, inputs, outputs and errors

Manager.define/1 inputs and outputs match the runtime_define row in the plan; expected_behavior is exactly elixir_mixir.behavior.v1. ArtifactRegistry.fetch/1 returns {:ok, artifact} or ARTIFACT_NOT_FOUND. Revision increments per logical name on successful registration; reserved module slot is independent of logical revision. Define replay returns the same artifact. Compilation syntax/errors/warnings return COMPILE_FAILED with capped diagnostics; missing exports return CALLBACK_MISSING. Limits return LIMIT_EXCEEDED; timed-out compiler returns COMPILE_FAILED with a timeout diagnostic. All failed attempts consume slots, including parsing failures; limit validation before reservation does not compile.
Schema callback errors/non-positive return fail validation; compilation alone must not call init or handle_event. Side effects at compile time are outside kernel transactional guarantees and require isolation.

Use the governing plan's exact limits, errors, callback contracts, revision semantics,
and Phase 1 in-memory boundaries. Document public APIs with accurate docs/specs and
struct types; do not lower Doctor/Credo/Dialyzer thresholds.

## Focused tests, integration checks and failure scenarios

Create `test/runtime/artifact_compiler_test.exs`, serial: valid counter artifact and exports; original SHA-256; unique slot/revision; inactive compile; malformed source; absent/wrong callback arity; invalid schema/error/timeout; warning capture; extra/nested module rejection; source-byte/capacity boundary; compile timeout via trusted fixture; same request replay/conflict; diagnostics bounded. Compare registry and previous artifact before/after every failed definition. Use separate child BEAMs for slot-exhaustion tests, and share immutable generated fixtures where practical so the ordinary full suite stays within its 128 lifetime attempts. Never reset consumed slots or reuse module names in a live BEAM. Test EventLog ring append/cursor basics here so later readers require no unfinished module.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root after implementing this task:

```sh
mix test test/runtime/artifact_compiler_test.exs --warnings-as-errors
mix test test/mcp test/integration --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

Exactly two tools work over HTTP, including real define/replay/error cases. Valid artifacts load once and remain immutable/inactive; every invalid definition leaves prior artifacts intact; attempts, module slots, deadline and diagnostics remain bounded.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Document template source, callback behavior, source rewriting, failure slot consumption, and in-VM isolation limitations in `docs/runtime-api.md`. Update README/tool examples and docs/sdlc/phase01/verification.md with this task's HTTP results. Commit contract/compiler/registry/minimal EventLog, define adapter and unit/HTTP tests as `feat(runtime): bound generated code and retain immutable artifacts`.

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

Execution evidence (2026-11-10):

- Verified committed prerequisites `14f8d10` / `84edf6e`, reread assignment/plan/task
  and amendments, and preserved unrelated `scripts/codex.sh`.
- `mix test test/runtime/artifact_compiler_test.exs --warnings-as-errors`: 1 doctest,
  12 tests, zero failures. Valid/inactive artifacts, failure preservation, schema,
  warning/deadline/heap/diagnostic/response bounds, replay/conflicts and ring basics pass.
- `mix test test/mcp test/integration --warnings-as-errors`: 29 tests, zero failures,
  including new define/replay/reconnect journeys, default five-second deadline,
  separate-BEAM lifetime exhaustion and authoritative metadata failure.
- `mix check`: passed; 2 doctests, 67 tests, zero failures; strict Credo clean,
  Doctor coverage 100%, Dialyzer zero errors. No thresholds or warnings suppressed.
- `git diff --check`: passed. Hook path `.githooks`. Reviewed task-only scope.
- Amendment 05 records the proven Hermes five-second public-wrapper mismatch and
  explicit POST wait, fatal-authority supervision and VM-lifetime slot counter.
- Full evidence is recorded in [verification.md](../verification.md). This checked
  task's containing commit is the checkpoint; its normal hook reruns the full gate.
- Next task only after that verified commit exists: `worker-start`.
