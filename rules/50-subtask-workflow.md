## Complete and commit each subtask

- Work in small subtasks that can each reach a working, independently reviewable state.
- Before continuing to another subtask, finish writing the current subtask's unit tests and ensure they pass. Incomplete or failing tests mean the subtask is not complete.
- Run the full `mix check` quality gate for the current subtask and resolve every failure before continuing. Passing only the focused tests is insufficient.
- Once the unit tests and all quality gates pass, commit the subtask in its working state before starting the next subtask. Keep these checkpoints focused so individual changes can be rolled back easily.
- Follow the commit-message rules and include relevant tests, documentation, and regenerated `AGENTS.md` with the subtask. Leave unrelated user changes out of the commit.
- Use the installed pre-commit hook to enforce the quality gates; do not bypass it to record a failing or unfinished checkpoint.
