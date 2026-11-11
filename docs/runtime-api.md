# Runtime API version 1

The currently implemented MCP surface contains one tool: `runtime_inspect`.
Runtime metadata is in memory; no generated application is seeded at startup.

## Connection

An independent BEAM serves Streamable HTTP at `http://127.0.0.1:4100/mcp`.
Initialize with protocol `2025-03-26`, send `notifications/initialized`, and retain
the `mcp-session-id` response header on subsequent requests. POST requires
`Content-Type: application/json` and `Accept: application/json, text/event-stream`.
Responses may contain JSON directly or arrive on a session-associated GET SSE
stream. Accepted notifications and SSE-routed responses return empty HTTP 202.
DELETE closes the session's SSE stream; it does not stop the runtime.

GET `/health` returns API version, readiness and diagnostic OS runtime ID. Only
exact `/health` and `/mcp` paths are served. The listener binds IPv4 loopback.
Host must be `127.0.0.1:<port>` or `localhost:<port>`; a supplied Origin must be
`http://` followed by one of those authorities. CLI requests may omit Origin.
Unexpected or repeated Host/Origin headers are rejected.

JSON-RPC IDs are strings or integers with at most 128 encoded bytes and are echoed
on valid requests, including zero. They are separate from future mutation
`request_id` values. Incoming bodies and complete encoded tool responses default
to 64 KiB. Invalid protocol data uses bounded JSON-RPC errors and appropriate 4xx
status; runtime failures use an HTTP 200 tool result with `isError: true`.

## runtime_inspect

Arguments are optional; omission is equivalent to an empty object:

| Argument | Contract |
| --- | --- |
| `worker_id` | ASCII identifier `[a-zA-Z0-9_-]{1,64}`; currently every valid worker ID returns `WORKER_NOT_FOUND` |
| `detail` | `summary` (default) or `state`; both report the empty runtime at this checkpoint |
| `limit` | Integer from 1 through configured page maximum (default maximum 100) |
| `cursor` | String schema reserved for inspection pagination; no cursor is valid in the empty runtime |

Unknown keys, invalid IDs, explicit null values, unsupported detail and malformed
cursors return `INVALID_ARGUMENT`. Schema type violations produce protocol errors.
Inspection is read-only and never executes generated behavior. It reports
`api_version: "1"`, `generation: 0`, health, empty workers/topology, configured
limits and ledger capacity/retention. State inspection does not invent workers.

The JSON envelope appears as text content and identical `structuredContent`,
which Hermes can serialize for clients supporting structured tool results. Older
clients can use the text representation. Errors include bounded `code`, `message`,
and `details` alongside version/generation. Entire encoding, including JSON-RPC ID
and escaped duplicate content, must fit the response limit. Response overrides
must allow at least 1,024 bytes for correlated fallback errors.

## Incremental implementation

Worker, compiler, event and replacement tools are pending their feature tasks.
No successful placeholders are advertised. Each feature must extend real-HTTP
tests and this document in its own verified commit. Future mutations must preflight
complete wire outcomes before applying staged changes; the current exposed tool
is read-only. Runtime generations and request replay rules are described in
[CONTRIBUTING](../CONTRIBUTING.md) and the [Phase 1 plan](sdlc/phase01/plan.md).
