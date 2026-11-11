# Runtime API version 1

The implemented MCP tools are `runtime_inspect`, `runtime_define`, `runtime_start`
and `runtime_stop`.
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
| `worker_id` | ASCII identifier `[a-zA-Z0-9_-]{1,64}`; selects a retained worker, or `WORKER_NOT_FOUND` |
| `detail` | `summary` (default) or `state`; state detail includes bounded committed state for a running worker |
| `limit` | Integer from 1 through configured page maximum (default maximum 100) |
| `cursor` | String schema reserved for inspection pagination; no cursor is valid until runtime-inspection adds pagination |

Unknown keys, invalid IDs, explicit null values, unsupported detail and malformed
cursors return `INVALID_ARGUMENT`. Schema type violations produce protocol errors.
Inspection is read-only and never executes generated behavior. It reports
`api_version: "1"`, current generation (zero on startup), health, sorted worker summaries, currently empty topology, configured
limits and ledger capacity/retention. State inspection does not invent workers.

The JSON envelope appears as text content and identical `structuredContent`,
which Hermes can serialize for clients supporting structured tool results. Older
clients can use the text representation. Errors include bounded `code`, `message`,
and `details` alongside version/generation. Entire encoding, including JSON-RPC ID
and escaped duplicate content, must fit the response limit. Response overrides
must allow at least 1,024 bytes for correlated fallback errors.

## Incremental implementation

Invocation, event and replacement tools are pending their feature tasks.
No successful placeholders are advertised. Each feature must extend real-HTTP
tests and this document in its own verified commit. Future mutations must preflight
complete wire outcomes before applying staged changes; definition preflights its
result before registry publication. Runtime generations and request replay rules
are described in
[CONTRIBUTING](../CONTRIBUTING.md) and the [Phase 1 plan](sdlc/phase01/plan.md).

## runtime_define

Definition compiles source; inspection and explicit start/stop are separate tools.
No workers start automatically. Definition takes four required string fields:

| Argument | Contract |
| --- | --- |
| `logical_name` | ASCII identifier `[a-zA-Z0-9_-]{1,64}` |
| `source` | At most 32 KiB raw UTF-8; one `defmodule Generated do ... end` template |
| `expected_behavior` | Exactly `elixir_mixir.behavior.v1` |
| `request_id` | Nonempty ASCII identifier, at most 64 characters; reuse for identical retries only |

For example, submit this source as the `source` string of a `runtime_define` call
with logical_name `counter`, expected_behavior `elixir_mixir.behavior.v1` and a new
request_id:

```elixir
defmodule Generated do
  @behaviour ElixirMixir.Behavior
  @impl true
  def init(config), do: {:ok, %{"count" => Map.get(config, "initial", 0)}}
  @impl true
  def handle_event(%{"increment" => amount}, state) do
    count = state["count"] + amount
    {:ok, count, %{"count" => count}, []}
  end
  @impl true
  def state_schema(), do: 1
  @impl true
  def migrate(state, _metadata), do: {:ok, state}
end
```

All four callbacks are mandatory. Config/event/state roots are JSON maps with
string keys. init/1 returns `{:ok, state}` or `{:error, reason}`. handle_event/2
returns `{:ok, reply, state, effects}` or `{:error, reason}`. migrate/2 returns
`{:ok, state}` or `{:error, reason}` and cannot return effects. state_schema/0
returns a positive integer. Define validates only the schema callback under its
200 ms callback deadline and 8 MiB task heap; it does not execute init, events or
migration. The later worker tasks own state transitions and effect support.

Successful results contain artifact_id, reserved module name, original source_hash
(SHA-256), logical revision, state_schema, compilation_status `compiled`, diagnostics
and callbacks_valid, together with the API/generation/request envelope. A new
successful definition of the same logical name gets a distinct module/artifact
and increments its logical revision. Replaying a request returns the exact recorded
outcome, including its original generation; different arguments under the same ID
return REQUEST_ID_CONFLICT. Errors replay too. Validation errors before a valid,
JSON-hashable request are not cached.

Before parsing, reserve one of 128 fixed `ElixirMixir.Generated.Slot001` through
`Slot128` module atoms for this BEAM lifetime. Rewrite only the outer module name;
use `__MODULE__` for self references inside the source. Reject other top-level
forms, nested modules, obvious Module.create/Code.compile_* calls, and compilation
output containing anything except the reserved module. Failed attempts consume
slots, including syntax errors, warnings, callback errors and timeouts. Source or
metadata validation rejected before reservation does not consume a slot. No slots
are reset or purged in a running BEAM, even after application stop/start.

The compiler runs in an unlinked monitored task with a five-second deadline and
64 MiB task heap. Temporary compiler descendants are tracked and joined during
cleanup; bounded diagnostics include tracked helper counts on task failure. Code
warnings and errors are captured without changing global compiler options; schema
warnings also reject definition. Missing callbacks yield CALLBACK_MISSING; syntax,
warnings, invalid schema and deadlines yield COMPILE_FAILED. Limits yield
LIMIT_EXCEEDED. Diagnostics are at most ten records with 2 KiB UTF-8 text each,
without raw exception stack traces.

Compilation loads code before metadata publication. The registry retains original
source, hash, BEAM, schema/contract versions and immutable metadata only after all
checks and full-response preflight pass. Failed definitions do not alter existing
artifacts, active behavior or runtime generation. Compile success/failure records
go to the bounded EventLog ring; its MCP reader is pending runtime-inspection.

Generated macros, compile-time code and schema callbacks execute with VM privileges.
AST checks, task heap flags and deadlines are not a secure sandbox or a total VM
memory/atom budget. Compile-time side effects cannot be rolled back. Run experiments
only in a trusted disposable environment without secrets or valuable infrastructure.
Loss of Manager or artifact-registry authority shuts down the kernel; there is no
Phase 1 recovery. Stopping the BEAM loses all artifact metadata.


## runtime_start and runtime_stop

Start takes required worker_id, artifact_id, config and request_id. Worker/request
IDs use the same ASCII rules as define. Config is a JSON map limited to 16 KiB and
16 nested levels. The same depth limit applies to committed state; protocol and
result wrappers are accounted for separately and do not consume that allowance.
Unknown keys and malformed values are rejected without starting a host.

After artifact/capacity validation, a temporary DynamicSupervisor child runs init
in an unlinked supervised callback task with a 200 ms deadline and 8 MiB task heap.
Only a valid `{:ok, state}` publishes a running definition. Success reports worker_id,
diagnostic pid, artifact_id/implementation_version, worker_revision, state_revision
and running status. Both revisions start at one. Duplicate running IDs return
WORKER_EXISTS; unknown artifacts return ARTIFACT_NOT_FOUND. Explicit callback errors,
exceptions and invalid return shapes yield CALLBACK_FAILED, timeouts CALLBACK_TIMEOUT,
non-JSON state INVALID_TRANSITION, and config/state/capacity excess LIMIT_EXCEEDED.
Failed init leaves no live child/routing or half-created definition.

Stop takes worker_id and request_id and returns stopped status, definition_retained
and worker_revision. It terminates the host and retains config/artifact identity for
explicit reinitialization. A first stop advances worker revision and generation;
a repeated stop of the retained stopped definition succeeds without advancing either.
Unknown IDs return WORKER_NOT_FOUND. A new start of a stopped/failed ID may supply
new config/artifact, reinitializes state, and advances worker and state revisions.
Worker capacity includes stopped and failed definitions (default 32).

For example, after defining the counter artifact, call runtime_start with:

```json
{"worker_id":"counter","artifact_id":"<returned artifact_id>","config":{"initial":7},"request_id":"start-counter-1"}
```

Then inspect with `{"worker_id":"counter","detail":"state"}`, and stop with
`{"worker_id":"counter","request_id":"stop-counter-1"}`. Inspection reads only
host-owned committed state, never a generated callback. Summary reads omit state;
stopped/failed/unavailable hosts include explicit state omission metadata. Client
close/reinitialize preserves running worker PID and state.

Unexpected host death currently marks the retained definition failed, removes its
live PID, advances worker revision/generation and records a correlated crash event.
Peers, Manager and HTTP remain alive. **Recovery is manual at this checkpoint**:
call runtime_start with a fresh request_id to reinitialize the failed ID. Automatic
restart budgets belong to worker-recovery. Phase 1 does not preserve state across
crashes. No runtime_invoke tool or automatic recovery timer is advertised yet.

Request replay returns the original outcome and generation without another host or
stop, even if later operations have changed the worker. Inspect to obtain current
status. Callbacks use an independent kernel coordinator so killing their owner also
cancels and joins generated execution and tracked helpers; HTTP client disconnect
does not kill the host or Manager and therefore does not cancel accepted work.
