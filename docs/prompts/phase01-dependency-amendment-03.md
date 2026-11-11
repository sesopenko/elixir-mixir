# Phase 1 dependency and transport correction 03

Recorded during mcp-bootstrap implementation from executable resolution and published
upstream source. Read alongside the implementation assignment, original planning
snapshot, amendments 01/02, governing plan and current task.

The originally planned Bandit 1.8.0 does not honor `read_body` length limits for
HTTP/1 chunked requests. Hex resolution reports this and other HTTP advisories.
The [upstream advisory](https://github.com/mtrudel/bandit/security/advisories/GHSA-9q9q-324x-93r2)
identifies the broken length cap and the first fix in 1.11.1. Retaining 1.8.0 would
contradict the mandatory bounded-ingress contract.

Use exact Bandit **1.14.1** and Plug **1.20.3**, retaining Hermes **0.14.1** and
Jason **1.4.5**. Official [Bandit metadata](https://hex.pm/api/packages/bandit/releases/1.14.1)
and [Plug metadata](https://hex.pm/api/packages/plug/releases/1.20.3) report no
advisories and require Elixir ~> 1.13 / ~> 1.15 respectively. Bandit and Hermes both
accept Plug ~> 1.18, which includes 1.20.3. Installed published `mix.exs` files and
successful resolution/compilation confirm compatibility on Elixir 1.18.3 / OTP 27.
Real-TCP regression tests cover chunked and fixed-length over-limit requests.
The lockfile records all resolved transitive dependencies.

Installed source also establishes these adapter details:

- Bandit forwards `thousand_island_options: [supervisor_options: [name: ...]]`;
  a bare `name` inside `thousand_island_options` is rejected.
- Hermes requires Plug initialization after its registry exists. Its notification
  response contains `{}`; the wrapper normalizes accepted notifications to empty 202.
- Hermes initialization has no `instructions` hook, so the wrapper adds read-only
  instructions to the initialization JSON result before sending it.
- Peri may discard unknown keys; tool execution reads original protocol arguments
  from `frame.request.params`, then Manager independently validates them.
- MCP permits omitted tools/call arguments. The wrapper defaults omission to `%{}`
  and rejects explicit non-object arguments before Hermes' map-only handler.

Full JSON-RPC encoding with escaped text, structured content and correlation IDs
needs more space than a raw kernel error. Set the minimum configurable response
ceiling to **1,024 bytes** (previously 256). Keep the default at 65,536 bytes. Bound
JSON-RPC IDs to **128 encoded bytes**, distinct from 64-character mutation IDs.
These refinements make even fallback errors representable within the configured
wire limit. Tests cover escaped/duplicated content and correlated errors. Runtime
limits and production tool behavior otherwise remain as specified in the plan.
