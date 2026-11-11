# Restart planning checkpoint verification

This records planning, not implementation of restart recovery. All implementation
tasks and their execution evidence remain pending. Governing [plan](plan.md),
[assignment snapshot](../../prompts/phase02-restart-planning.md), and separate
[implementation evidence template](verification.md).

## Snapshot and inspected baseline

The complete approved planning assignment was preserved verbatim, without the chat
renderer's wrapper tags, before drafting these artifacts. SHA-256:

`d9bde558f740cc71c4e1890cdd92690ce91f46d4508ba995b67890735164b639`

Inspected baseline `81830cb`; verified Phase 1 commits and their checked task/evidence
documents, including the committed actual Codex evidence at `8631dbd` (51 and 8 MCP
calls across two sessions) and verification reconciliation at `edaff7d`. Inspected
Manager, ProcessHost, Workers, transition/replacement staging, artifact compiler and
registry, request ledger, crash recovery, effects/dispatcher, HTTP readiness,
configuration, release files and independent-BEAM fixtures. Read project rules,
contributor guidance, ADR-001 durability/acceptance requirements and Phase 1's plan,
task and planning-verification pattern. Historical prompts were located under their
current archived paths without altering the user's relocation.

## Reproducible structural checks

From the repository root:

```sh
python3 docs/sdlc/phase02-restart/verify-plan.py
sha256sum docs/prompts/phase02-restart-planning.md
git diff --check
git config --get core.hooksPath
mix check
```

The [structural verifier](verify-plan.py) checks unique task IDs, exact document
and Mermaid node/edge sets, prerequisite agreement, topological execution order
(which proves acyclicity), task section/gate/recovery requirements, final sizes and
original-13 split records, all fourteen criterion owners, three milestone exits,
new-document relative links, generated recovery rules and the snapshot checksum.
Its checks of pending status allow future checked tasks while ensuring an explicitly
pending task cannot claim completed evidence.

## Contract and planning review

- Each runtime task owns focused tests and a real-HTTP increment; SIGKILL fixtures
  begin at store-foundation and generated-application restart checks begin at
  durable-artifacts. No final integration task exists.
- Durable workers and durable effects were the two initial size-13 groups. Their
  decompositions are reflected in every task, dependency edge, execution-order row
  and acceptance mapping. Final task sizes are at most 8; evidence-review anchors 1.
- Reviewed commit versus publication ordering, uncommitted admissions, uncertain
  responses, host death, store authority loss, durable state/effect atomicity,
  deduplication independent of request expiry, absolute timer deadlines, schema and
  artifact identity, bounded retention and quarantine. Explicitly resolved intermediate
  durable-mode gates so no checkpoint depends on downstream unfinished behavior.
- The plan uses explicit persistence opt-in to preserve existing disposable memory
  experiments. A retained data directory and volume are mandatory in the restart
  workflow. No automatic schema migration, LLM recovery, distribution or exactly-once
  external IO is promised. This planning checkpoint changes no runtime capability.
- All twelve task checklists and implementation-evidence sections are pending;
  no automated recovery test or actual Phase 2 Codex demonstration has been executed.
- README and CONTRIBUTING were reviewed: current behavior/setup do not change in
  this documentation-and-rules checkpoint, so public feature claims stay as they
  are. Each future feature task owns its relevant public guidance updates, including
  the existing Claude Code untested qualification.

Dependency checks performed on 2026-11-11 used the official
[Hex release](https://hex.pm/packages/cubdb/2.0.2),
[tagged Mix manifest](https://github.com/lucaong/cubdb/blob/v2.0.2/mix.exs),
[CubDB API](https://hexdocs.pm/cubdb/2.0.2/CubDB.html), and
[tagged source](https://github.com/lucaong/cubdb/blob/v2.0.2/lib/cubdb.ex).
Confirmed version, declared Elixir compatibility/no production dependencies, startup
options, transaction callback form and synced-write configuration. Actual dependency
resolution/compilation on the repository toolchain is store-foundation's work;
neither mix.exs nor mix.lock is changed by planning.

## Actual quality results

- `./scripts/build-agent-rules.sh`: passed; generated AGENTS.md contains the new
  Phase 2 entry point and preserves the prior rules.
- `mix check`: passed on Elixir 1.18.3 / OTP 27, 2 doctests and 151 tests with
  zero failures; formatter and warnings-as-errors compilation passed, strict Credo
  found no issues, Doctor documentation/typespec coverage remained 100%, and
  Dialyzer reported zero errors.
- The first sandboxed gate could not open the local Mix.PubSub TCP socket (`:eperm`).
  Rerunning through the required permission mechanism completed successfully;
  this was an environment restriction, not a runtime test failure.
- `python3 docs/sdlc/phase02-restart/verify-plan.py`: passed; 12 tasks, 12 graph
  nodes, 11 matching edges, acyclic deterministic order, fourteen criterion owners,
  three milestone exits, final sizes 1–8, and 84 valid relative links. Recovery and
  completion gates, generated rule inclusion and snapshot checksum also passed.
- `git diff --check`: passed; `git config --get core.hooksPath`: `.githooks`.
  The normal installed hook reruns the full quality gate for the planning commit;
  successful creation of that commit is the hook completion evidence.

Only the new assignment snapshot, this phase's planning artifacts/verifier, the
recovery-rule addition and regenerated AGENTS.md belong in the planning commit.
Historical prompt deletions/archived files, the empty user prompt and scripts/codex.sh
are unrelated and must remain unstaged. Runtime implementation is a later assignment.
