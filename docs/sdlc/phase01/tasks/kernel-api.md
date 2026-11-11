# kernel-api: Bounded kernel API and manager foundation

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

An empty runtime reports version, generation zero, health, and configured limits through a documented Manager API. Invalid values and duplicate operation IDs have predictable bounded outcomes.

## Prerequisites and required outputs

Prerequisite IDs: none

No runtime prerequisite; use the committed planning checkpoint and actual bootstrap baseline.

A prerequisite is complete only after its focused verification, full `mix check`,
and working commit through the installed hook. Read the plan's resolved contracts;
this task refines those contracts and does not authorize architectural alternatives.

## Concrete implementation steps and components

Create `Runtime.Values`, `Runtime.Limits`, `Runtime.Error`, `Runtime.RequestLedger`, and `Runtime.Manager` under `lib/elixir_mixir/runtime/`. Add focused structs/types only where useful; document every public API and struct. Start Manager under the existing supervisor without removing the greeting API.
Implement the JSON/depth/byte checks and ID validation in the plan. Canonicalize request hashes without atomizing client data. Implement ledger admission, same-operation replay, ID conflict, expiration, and saturation with an injectable monotonic clock. Implement the mutation wrapper and test it with a kernel-owned test operation; do not expose fabricated runtime tools or successful placeholders for future features.
Implement only `inspect_runtime/1` for empty status now. Manager provides internal sequencing/context helpers consumed by later operations; future public functions are introduced with their implementation. Configure defaults through application config and test overrides. Validate configurations at boot. Keep runtime generation changes explicit and testable.

## Interfaces, inputs, outputs and errors

`Manager.inspect_runtime(%{})` returns `{:ok, map}` with API version 1, generation 0, empty worker/topology lists, limits, and ledger retention. `Values.validate(value, kind, limits)` returns `:ok` or a stable error; kind selects root and byte constraints. Ledger reserves `{request_id, operation, canonical_hash}`, completes a result once, and exposes replay/conflict/busy outcomes. Internal API names may follow repository style, but behavior must match the governing plan.
No generated code or network transport exists in this task. Missing/malformed fields return `INVALID_ARGUMENT`; exceeded limits return `LIMIT_EXCEEDED`; full unexpired ledger returns `BUSY`. Clock expiry cannot evict an in-flight request.

Use the governing plan's exact limits, errors, callback contracts, revision semantics,
and Phase 1 in-memory boundaries. Document public APIs with accurate docs/specs and
struct types; do not lower Doctor/Credo/Dialyzer thresholds.

## Focused tests, integration checks and failure scenarios

Create `test/runtime/kernel_api_test.exs`: exact-limit and one-over-limit values, depth, invalid UTF-8, non-JSON terms, structs, IDs, canonical map-order equivalence, replayed success/error, different operation or payload conflict, in-flight duplication, expired entry removal, full-ledger refusal, generation invariants, and empty inspect. Verify all existing bootstrap tests still pass. Use controlled clocks, not ten-minute sleeps.

Tests added here must pass with completed prerequisites alone. Do not reference
unfinished downstream modules or add intentionally failing tests. For unexpected
results, investigate root cause and prove it with a test before fixing the system.
After three unsuccessful fix attempts, stop and ask the user for direction.

## Exact verification and measurable acceptance

Run from the repository root after implementing this task:

```sh
mix test test/runtime/kernel_api_test.exs --warnings-as-errors
mix check
git diff --check
git config --get core.hooksPath
```

All value and ledger boundaries pass; empty Manager status is observable with generation zero; no new HTTP or generated execution behavior.

The hook path must be `.githooks`; if absent, run
`./scripts/install-git-hooks.sh` before committing. All tests and the full quality
gate must pass, with no warnings or suppressed findings. Record actual verification
commands/results below when executing; do not mark this planned task complete now.

## Documentation and intended commit scope

Update `CONTRIBUTING.md` for in-memory Manager status and limit configuration. Commit kernel helpers, manager startup, config, tests, and documentation as `feat(runtime): give mutations bounded and repeatable outcomes`.

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
