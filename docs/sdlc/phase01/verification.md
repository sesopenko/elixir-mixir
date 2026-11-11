# Phase 1 implementation verification

This records incremental implementation evidence. The actual Codex-created
counter/aggregator demonstration is pending; automated HTTP tests do not establish
that demonstration. Checkpoint commits are identified by their checked task documents.

## kernel-api

Committed as `14f8d10`. Its task document records focused tests and the full gate.
The MCP checkpoint raises the minimum configurable response ceiling from 256 to
1,024 bytes so correlated, duplicated MCP errors fit; the default remains 64 KiB.

## mcp-bootstrap

Verified 2026-11-10 on Elixir 1.18.3 / OTP 27. Pre-commit reruns the full gate;
the commit containing the checked mcp-bootstrap task document is this checkpoint.

- `mix test test/mcp/bootstrap_test.exs test/integration/mcp_bootstrap_test.exs --warnings-as-errors`:
  20 focused/bootstrap tests, zero failures.
- `mix deps.tree`: resolved Hermes 0.14.1, Bandit 1.14.1, Plug 1.20.3 and Jason
  1.4.5 with compatible transitive dependencies. The lockfile records resolution.
  [Correction 03](../../prompts/phase01-dependency-amendment-03.md) explains the
  length-cap defect in the original HTTP pin and verified transport API details.
- `mix check`: passed; 1 doctest, 46 tests, zero failures, strict Credo clean,
  Doctor module/function documentation and typespec coverage 100%, Dialyzer zero errors.
- `git diff --check`: passed; `core.hooksPath` is `.githooks`.
- Smoke-tested documented `mix run --no-halt` outside the test environment:
  `curl --fail http://127.0.0.1:4100/health` returned API version 1 and ready status.
  Stopped that smoke-test runtime afterward.

The real-TCP suite starts a new independent BEAM on an ephemeral loopback port for
each case. It verifies protocol 2025-03-26 negotiation, empty initialized notification,
returned session header, discovery of exactly `runtime_inspect`, strict schema,
matching JSON text/structured results, unknown-worker and unknown-key errors,
JSON-RPC ID correlation including zero, omitted tool arguments, rejection of null
and other non-object arguments, and successful inspection after those rejections.

SSE coverage opens a GET stream using the session header, receives a correlated
POST result on that stream, and checks the empty HTTP 202 response. Reconnect
coverage closes the HTTP client, creates and initializes a fresh one, then confirms
the same OS runtime ID and unchanged generation/status. Fixed-length and chunked
bodies over 64 KiB are rejected; an exactly 64 KiB valid request is accepted. The
endpoint remains ready after rejection. Actual socket tests reject invalid Host
and Origin. An explicit cleanup test proves the fixture OS process terminates.

Focused Plug/Manager tests additionally check missing-readiness behavior, occupied
port startup failure, disabled listener in ordinary tests, non-loopback/invalid
configuration, exact routing/methods, missing Accept, malformed JSON, batch input,
invalid UTF-8/depth/IDs, inspection argument validation, duplicate/escaped result
size accounting and representable correlated error envelopes at the minimum ceiling.

## Acceptance status

| Criteria | Current evidence | Remaining |
| --- | --- | --- |
| A01 | Automated initialize/list/inspect against independent BEAM | Actual Codex connection transcript |
| A13 | Automated close/reinitialize and same OS runtime identity | Worker continuity in later features; actual Codex reconnect |
| A14 | Loopback binding, configuration/header checks, local smoke startup | Isolated local deployment and actual demonstration |
| A02–A12 | Kernel and transport foundations only | Owning feature tasks and demonstration |

Compiler, workers, effects, history/topology, replacement, isolated container/release
setup and the actual Codex transcript remain pending. No worker/domain behavior is
seeded in the production kernel or claimed by this checkpoint.
