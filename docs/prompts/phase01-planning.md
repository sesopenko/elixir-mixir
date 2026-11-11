# Phase 1 planning assignment for the build agent

## Bootstrap and durable instructions

Before doing other work, save this complete assignment verbatim to `docs/prompts/phase01-planning.md`.

Read `AGENTS.md`, `CONTRIBUTING.md`, and `docs/adr/001-architecture.md`. Inspect the existing implementation and Git status. Preserve unrelated user changes.

Create an implementation plan for **Phase 1 — Live Genesis**, covering architecture milestones 1–4. This assignment produces planning documents and workflow rules; do not implement runtime features.

The repository already contains a Mix application, an empty supervisor, tests, and quality tooling. Plan from the actual baseline.

## Context recovery rules

Create `rules/60-context-recovery.md` containing these requirements:

- Before starting an assignment, save its complete instructions under `docs/prompts/` and identify the snapshot in its work plan.
- Before starting a subtask, read the assignment snapshot, governing plan, and subtask document.
- After every context compaction, reread those documents before resuming. A compaction summary does not replace these reads.
- Apply these requirements to both planning agents and implementation agents.
- If a planning or task document does not exist yet, read the available governing documents and partial drafts before continuing.
- Preserve assignment snapshots. Record subsequent approved amendments separately and reread them alongside the original snapshot.
- After a complete context clear or in a new session, determine progress from repository state and committed work before continuing.

Include this discoverable Phase 1 entry point in the rule:

> For Phase 1 planning or implementation, first read `docs/prompts/phase01-planning.md`, then `docs/sdlc/phase01/plan.md` if present, and the current task document. Inspect Git status and relevant commits before resuming. If the current task is unclear, use the plan’s execution order and verify completed prerequisites before selecting the next task.

Run `./scripts/build-agent-rules.sh`. Include regenerated `AGENTS.md` with the rule changes.

For this planning assignment, follow the recovery procedure yourself. Include the same procedure explicitly in the resulting plan and every task document.

## Required planning artifacts

Create `docs/sdlc/phase01/plan.md` with:

- Phase 1 objective, boundaries, existing capabilities, and completion criteria.
- A link to the assignment snapshot and instructions for starting and resuming work.
- A task index with stable short kebab-case IDs, descriptions, prerequisites, and links.
- A Mermaid `flowchart TD` representing the complete task dependency graph. Show every task exactly once, with arrows from prerequisite to dependent task.
- A deterministic execution order consistent with the graph.
- A mapping from every acceptance criterion in architecture section 9.4 to implementation tasks and verification.
- The mandatory task completion gate below.

Create one Markdown file per task at `docs/sdlc/phase01/tasks/<task-id>.md`. Each must contain:

1. Objective and observable outcome.
2. Prerequisite task IDs and outputs needed.
3. Concrete implementation steps and affected components.
4. Public interfaces, callback contracts, inputs, outputs, and relevant error behavior.
5. Focused unit tests, applicable integration checks, and failure scenarios.
6. Exact verification commands and measurable acceptance criteria.
7. Documentation updates and intended commit scope.
8. Startup and post-compaction reread instructions.
9. A completion checklist covering tests, verification, and commit creation.

Split work into small, independently reviewable tasks that can pass all checks using only completed prerequisites. Avoid intentionally failing tests and dependencies on unfinished downstream components.

## Required implementation coverage

Plan the smallest runtime satisfying Phase 1:

- Independently running localhost MCP server and centralized runtime manager.
- Generated behavior contract, bounded dynamic compilation, and immutable artifact registry.
- Stable supervised process hosts, logical IDs, lifecycle management, and invocation.
- Kernel-managed event delivery, delayed events, and structured logging effects.
- Runtime inspection, topology, bounded event history, and diagnostics.
- Versioned behavior replacement, explicit migration, revision checks, and failure handling.
- All seven MCP tools specified in architecture section 7.

Resolve interfaces and implementation choices sufficiently for an autonomous agent to proceed without architectural decisions. Verify dependency compatibility and transport APIs against official documentation before specifying versions or APIs; record sources and decisions.

Specify automated verification for:

- Generated worker creation, invocation, inspection, and worker-to-worker events.
- PID and state preservation during normal replacement.
- Invalid source, missing callbacks, failed migration, and revision conflicts.
- Worker failure isolation, bounded restarts, and event-processing timeouts.
- Request IDs, resource limits, and bounded responses.
- Client disconnect/reconnect while the runtime remains alive.

Include local isolation, startup and connection documentation, and a reproducible counter/aggregator demonstration driven by Codex through MCP. Distinguish automated integration checks from the actual Codex demonstration. During that demonstration, application behavior must be created and evolved through MCP.

Keep metadata in memory for Phase 1. Preserve Phase 2 seams without implementing persistence, restart recovery, or an autonomous controller.

## Mandatory completion gate

The required test-and-commit rule already exists in `rules/50-subtask-workflow.md`. Retain it rather than creating a duplicate.

Every implementation task must enforce this sequence:

1. Complete code changes and write focused unit tests, including relevant failure paths.
2. Pass those tests and all task-specific verification.
3. Pass the complete `mix check` gate and resolve every finding.
4. Commit the verified task using a Conventional Commit header and nonempty explanatory body, with the installed pre-commit hook enabled.
5. Only then begin another task.

A prerequisite is complete only after verification and commit. Apply this gate to every task, including tasks without dependents. For documentation-only tasks, use applicable document verification without inventing unrelated code tests.

Follow the repository’s root-cause investigation rule and stop for user direction after three unsuccessful attempts to fix a problem.

## Planning verification and delivery

Treat this planning assignment as one reviewable documentation-and-rules checkpoint.

Before committing:

- Verify that graph nodes, task documents, links, prerequisite lists, and execution order agree.
- Verify that the graph is acyclic and every prerequisite exists.
- Confirm coverage of every Phase 1 acceptance criterion.
- Resolve outstanding implementation decisions.
- Confirm the snapshot preserves this assignment and generated `AGENTS.md` contains the recovery rule.
- Run `mix check` and resolve every failure.

Commit only the assignment snapshot, planning documents, rule changes, and regenerated `AGENTS.md` through the normal pre-commit hook. Leave unrelated changes untouched, including `scripts/codex.sh` if present.

Report the artifact paths, verification result, and commit ID. Stop after delivering the committed plan; runtime implementation is a subsequent assignment.
