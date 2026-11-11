# Build-agent assignment: Plan Phase 2 restart recovery

## Assignment and context recovery

Produce the **restart feature plan** under `docs/sdlc/phase02-restart/`, following the successful planning and progress-management pattern in `docs/sdlc/phase01/`. This assignment produces planning documents and necessary recovery-rule updates; runtime implementation is a subsequent assignment.

Before other work, copy this complete assignment verbatim into `docs/prompts/phase02-restart-planning.md`. Preserve that snapshot; record subsequent approved amendments separately.

Before each planning subtask and after every context compaction, reread:

- The assignment snapshot and approved amendments.
- `AGENTS.md`, the governing restart plan, and the current task document.
- Available drafts when the plan or task document does not exist yet.

A compaction summary does not replace these reads. After a new session or complete context clear, inspect Git status, relevant commits, and recorded evidence before determining progress.

Read `CONTRIBUTING.md`, `docs/adr/001-architecture-initial-phases.md`, and the Phase 1 plan, representative task documents, and verification documents. Locate historical prompts in their current repository locations; some have moved into `docs/prompts/archived/`. Preserve unrelated changes and do not reorganize historical documents.

Extend `rules/60-context-recovery.md` with the Phase 2 snapshot and plan entry points. Retain existing requirements, run `./scripts/build-agent-rules.sh`, and include regenerated `AGENTS.md`.

## Planning method and required coverage

Inspect the actual Phase 1 implementation, tests, configuration, release setup, and demonstration evidence. Record the current baseline and verify Phase 1 completion from committed evidence. Do not copy Phase 1’s original empty-runtime baseline or its completed checklists into the new plan.

Plan ADR-001 section 10 and milestones 5–7. Keep the permanent kernel small, use CubDB behind an application-level interface, and exclude autonomous-controller work and unrelated developer-experience roadmap features.

Resolve implementation choices sufficiently that another agent can execute the plan without making architectural decisions. Verify proposed dependency versions and APIs against official documentation and record sources.

The resulting plan must specify:

- Durable artifacts, desired topology, active implementations, configuration, committed worker state, revisions, operation outcomes, idempotency records, pending effects, and timers.
- Transaction boundaries for definition, start, stop, invocation, replacement, and effect delivery. Persist accepted transitions before acknowledging success; commit originating state and effects together.
- Ordering between durable commits, live-host updates, effect dispatch, and responses, including reconciliation after interruption at each boundary.
- Serializable state and schema handling, source/hash validation, deterministic recompilation, state restoration, and logical routing.
- Retry and deduplication semantics across restart, including retention limits and their consequences.
- Timer deadlines across VM lifetimes, overdue timers, pending-delivery retries, and duplicate suppression. Preserve the ADR’s external-effect delivery limits.
- Recovery supervision and readiness, store failure behavior, worker quarantine, diagnostics, and inspection of broken retained definitions.
- Storage configuration, format/version compatibility, retained volumes, test-store isolation, and changes to existing in-memory behavior.
- Public API, callback, configuration, and inspection changes needed for these capabilities. Explain compatibility with existing clients and bounded runtime limits.

Do not serialize PIDs, references, native mailboxes, or live timers. Restore logical identities and committed state into newly created processes. The latest committed manifest and state are authoritative; full event sourcing and exactly-once external effects are outside this phase.

## Required planning artifacts and implementation workflow

Create these artifacts:

- `plan.md`: objective, current baseline, boundaries, completion criteria, snapshot links, resolved contracts, task index, deterministic execution order, and progress conventions.
- `tasks/<task-id>.md`: one document per small, independently reviewable implementation task, using stable kebab-case IDs.
- `planning-verification.md`: reproducible structural checks, decision and source verification, and actual planning-check results.
- `verification.md`: an evidence-recording structure for later implementation, initially marked pending.

The plan must include a Mermaid `flowchart TD` with every task declared once and arrows from prerequisites to dependents. Task documents, graph edges, prerequisite lists, and execution order must agree.

Map all fourteen acceptance criteria in ADR section 10.9 to owning tasks and concrete verification. Map milestone exit conditions as well.

Each task document must contain:

1. Objective and observable outcome.
2. Prerequisite IDs and required verified outputs.
3. Concrete changes, affected components, and relevant interfaces and failure behavior.
4. Focused tests, integration increments, and interruption scenarios.
5. Exact verification commands and measurable acceptance criteria.
6. Required documentation and intended commit scope.
7. Startup and compaction-recovery instructions.
8. Completion checklist and pending execution-evidence section.
9. Final relative size and brief rationale.

**Integrate and test throughout implementation.** Reuse the existing independent-BEAM and real-HTTP MCP fixtures. Extend them for retained stores and abrupt termination as early as the first durable behavior permits. Every runtime task must add applicable integration coverage and rerun the growing suite using completed prerequisites alone.

Avoid a final task that connects previously isolated subsystems or introduces all restart testing. Early checkpoints may provide narrower recovery guarantees, but must document and test those boundaries. A final demonstration validates already integrated behavior.

Every implementation task must require this sequence:

1. Complete scoped changes and focused tests, including relevant failure paths.
2. Pass focused checks and the growing integration suite.
3. Pass full `mix check` and resolve all findings.
4. Record evidence and commit through the installed pre-commit hook using a Conventional Commit header and nonempty explanatory body.
5. Only then begin the next task.

Apply the same gate to tasks without dependents. Documentation-only tasks use meaningful document checks rather than invented code tests. Follow the root-cause rule and stop for user direction after three unsuccessful fix attempts.

Plan README, contributor, API, and demonstration updates alongside the behavior they describe. Preserve the distinction between verified Codex behavior and untested Claude Code compatibility.

## Verification scenarios and late sizing pass

Require automated scenarios for:

- Abrupt OS-level termination and restart using the same store, without an LLM connection.
- Restored source, topology, logical identities, implementation selections, revisions, and committed state; fresh process creation.
- Interruption before and after durable commits, including uncertain responses and request replay.
- Atomic replacement and failed migration without partial activation.
- Recovered timers and pending effects, including repeated delivery without duplicate committed transitions.
- Invalid artifacts or state quarantined while unrelated workers recover.
- Store failures, readiness gating, and retained diagnostics.
- Continued invocation, replacement, and client reconnection after recovery.

Assert actual persisted and live state, not response codes alone. Use controlled barriers and clocks where appropriate; real abrupt-termination tests remain mandatory.

Include a separate actual Codex demonstration following ADR section 10.8: create and evolve the counter/aggregator application through MCP, disconnect, abruptly terminate the BEAM, recover without Codex, verify state and pending work, then reconnect and continue evolving it. Automated tests do not count as that client demonstration.

**Near the end of planning**, after drafting tasks and dependencies, assign relative sizes from **1, 3, 5, 8, 13**, considering complexity, effort, and uncertainty. Use the simplest task as the 1 anchor and the largest initial task as the 13 anchor.

Split every task rated 13 into independently verifiable tasks rated 8 or smaller. Reassess children and repeat if necessary. Preserve a brief sizing record showing original 13s and their replacements. Update the graph, order, coverage mappings, and task documents after splitting. No executable task may retain size 13.

## Planning completion and delivery

Before committing the planning checkpoint:

- Verify unique task IDs, exact graph/document agreement, valid prerequisites, acyclicity, deterministic order, and local links in new or changed documents.
- Confirm all fourteen acceptance criteria and milestone exits have owners and verification.
- Confirm continuous integration and testing are explicit, all final sizes are at most 8, and implementation decisions are resolved.
- Confirm the verbatim snapshot, recovery instructions, generated rules, and pending evidence markers are correct.
- Run `git diff --check` and full `mix check`; record actual results.
- Commit only this assignment’s verified snapshot, planning artifacts, and necessary rule changes through the normal hook.

Report artifact paths, verification results, and commit ID. Stop after delivering the committed restart feature plan; do not implement runtime features.
