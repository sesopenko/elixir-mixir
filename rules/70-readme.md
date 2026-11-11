## Maintain the public README

- Treat `README.md` as the public entry point for someone who has never used
  elixir-mixir. Explain what the project does, why it is useful, and what a reader
  can try before describing internal components. Define unfamiliar project terms
  and acronyms on first use.
- Write natural, direct prose for a human reader. Use concrete examples and plain
  language. Avoid hype, robotic phrasing, unexplained jargon and internal task or
  checkpoint language. Make only claims supported by current behavior and evidence.
- When a change affects public capabilities, setup, commands, example prompts,
  requirements or limitations, update the README in the same verified commit.
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
