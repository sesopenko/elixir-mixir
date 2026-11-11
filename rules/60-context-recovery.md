## Preserve assignments and recover context

- Before starting an assignment, save its complete instructions under `docs/prompts/` and identify the snapshot in its work plan.
- Before starting a subtask, read the assignment snapshot, governing plan, and subtask document.
- After every context compaction, reread those documents before resuming. A compaction summary does not replace these reads.
- These requirements apply to both planning agents and implementation agents.
- If a planning or task document does not exist yet, read the available governing documents and partial drafts before continuing.
- Preserve assignment snapshots. Record subsequent approved amendments separately and reread them alongside the original snapshot.
- After a complete context clear or in a new session, determine progress from repository state and committed work before continuing.

For Phase 1 planning or implementation, first read `docs/prompts/phase01-planning.md`, then `docs/sdlc/phase01/plan.md` if present, and the current task document. Inspect Git status and relevant commits before resuming. If the current task is unclear, use the plan’s execution order and verify completed prerequisites before selecting the next task.

For Phase 2 restart planning or implementation, first read `docs/prompts/phase02-restart-planning.md`, then `docs/sdlc/phase02-restart/plan.md` if present, and the current task document. Reread these documents and separately recorded approved amendments before each subtask and after every compaction. If historical prompts have moved, locate their preserved snapshots rather than recreating or overwriting them. Inspect Git status, relevant commits, and verification evidence before resuming; use the plan's execution order and verify completed prerequisites when selecting the next task.
