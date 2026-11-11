## Maintaining agent rules

- Edit project agent instructions in `rules/*.md`; `AGENTS.md` is generated.
- Keep separate topics in separate Markdown files. Files are combined in bytewise filename order; use numeric prefixes to control their order.
- Run `./scripts/build-agent-rules.sh` after adding, changing, or removing a rule file.
- Include the regenerated `AGENTS.md` alongside rule changes.
