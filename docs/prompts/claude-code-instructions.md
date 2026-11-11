# Claude Code connection documentation

User instructions (verbatim):

> update the README.md to include claude code instructions, as well is in CONTRIBUTING.md, but note in both that claude is untested but it should theoretically work as well.

Subsequent user instruction (verbatim):

> and update the rule around readme and contributing.md maintenance to maintain the claude instructions.

## Work plan and single documentation subtask

Read AGENTS.md, README.md and CONTRIBUTING.md. Verify Claude Code's HTTP MCP
registration syntax against its official documentation. Add connection commands
and a first inspection prompt to both public documents, explicitly stating that
Claude Code is untested with this project but should theoretically work through
MCP. Extend the existing README maintenance rule to cover CONTRIBUTING.md and
ongoing Claude Code instruction accuracy, and regenerate AGENTS.md. Reuse the
existing independent runtime, readiness and example prompts. Do not
register a client or change the running application. Verify links and shell syntax,
run mix check, and commit this documentation checkpoint through the installed hook.
Preserve unrelated scripts/codex.sh; no push is requested.

After context recovery, reread this snapshot, its work plan and governing agent
instructions before resuming. Completion requires updated README.md and
CONTRIBUTING.md, the updated maintenance rule and regenerated AGENTS.md, passing
checks and a focused commit.
