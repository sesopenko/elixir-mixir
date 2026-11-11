# Rename the initial architecture ADR

User instruction (verbatim):

> rename docs/adr/001-architecture.md to 001-architecture-initial-phases.md

## Work plan and single documentation subtask

Read governing agent rules and inspect Git status and references. Rename the ADR
without changing its content. Update active documentation and rule references to
the new path, regenerate AGENTS.md, and preserve immutable assignment snapshots.
Verify the rename, local links and generated instructions, run mix check, and
commit through the installed hook. Preserve unrelated scripts/codex.sh and running
runtime state. No push is requested. After context recovery, reread this snapshot,
its work plan and AGENTS.md before resuming.
