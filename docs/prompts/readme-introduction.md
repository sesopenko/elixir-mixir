# Public README assignment

User instructions (verbatim):

> update README.md with an introduction to the project with some example prompts.  Then create a rule that maintains the README.md.  It's forward facing, for the public, so don't assume the reader is familiar with the system when editing the README.md.  The README.md should help somebody understand why this project is valuable.

Subsequent user instruction (verbatim):

> and the README.md shouldn't have "robotic" prose, should be easy for a human to read.

## Work plan and single documentation subtask

Read AGENTS.md, README.md, CONTRIBUTING.md and the current public API before
editing. Rewrite the introduction for a newcomer, explain the value with concrete
examples, and add a sequence of prompts supported by the existing runtime. Keep
startup, readiness, connection and limitations accurate. Add a dedicated rule
under rules/ for maintaining the public README in clear, natural language, then
regenerate AGENTS.md. Verify local links, example contracts and generated rules;
run mix check and commit this documentation checkpoint through the installed hook.
Preserve unrelated scripts/codex.sh and the running user-created counter. This
assignment does not change runtime code or require a new live experiment.

After context recovery, reread this snapshot, its work plan and AGENTS.md before
resuming. Completion requires the README, rule, generated AGENTS.md, passing
verification and a focused commit; do not push without a new request.
