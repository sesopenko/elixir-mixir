## Maintain README and contributor documentation

- Treat `README.md` as the public entry point for someone who has never used
  elixir-mixir. Explain what the project does, why it is useful, and what a reader
  can try before describing internal components. Define unfamiliar project terms
  and acronyms on first use.
- Write natural, direct prose for a human reader. Use concrete examples and plain
  language. Avoid hype, robotic phrasing, unexplained jargon and internal task or
  checkpoint language. Make only claims supported by current behavior and evidence.
- When a change affects public capabilities, setup, commands, example prompts,
  requirements or limitations, update the README and affected CONTRIBUTING.md
  guidance in the same verified commit.
  Check whether an update is needed; unrelated internal changes do not require
  README churn. Keep current features distinct from future plans.
- Keep a short, usable path from setup to a first successful experiment. Startup
  instructions must include a readiness wait before connecting the client. Explain
  where commands run, required tools and platform assumptions. Keep example prompts
  concrete, consistent with supported MCP behavior, and clear about expected results
  and existing-worker conflicts when they form a sequence.
- Preserve clear explanations of in-memory state, client versus runtime lifetime,
  and generated-code isolation limits. Link to detailed API, architecture,
  contribution and demonstration documents instead of copying their internals into
  the introduction. Verify local links and affected examples when editing.
- Maintain Codex and Claude Code connection instructions in README.md and
  CONTRIBUTING.md. Keep endpoint, transport, readiness, port overrides and example
  prompts consistent across both documents. Verify changed client command syntax
  against the client's official documentation and link the source.
- State in both documents that Claude Code is untested with this project but
  should theoretically work through HTTP MCP. Keep that qualification until an
  actual Claude Code session verifies the documented workflow and its evidence is
  recorded. Official client documentation or passing runtime tests alone do not
  establish that a client has been tested here. Preserve the distinction between
  actual Codex evidence and expected Claude Code compatibility.
