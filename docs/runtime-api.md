# Runtime API version 1

The implemented MCP tools are `runtime_inspect`, `runtime_define`, `runtime_start`,
`runtime_stop`, `runtime_invoke` and `runtime_events`.
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
| `cursor` | Opaque string from a previous runtime page; bound to this runtime, generation and detail |

Unknown keys, invalid IDs, explicit null values, unsupported detail and malformed
cursors return `INVALID_ARGUMENT`. Schema type violations produce protocol errors.
Inspection is read-only and never executes generated behavior. It reports
`api_version: "1"`, current generation (zero on startup), health, worker_count,
edge_count, sorted worker pages, topology, pending effects/timers/reservations,
configured limits and ledger capacity/retention. Worker summaries include diagnostic
PID, status, revisions, restart budgets and cached immutable artifact metadata
(ID/logical name/revision/schema/source hash/contract), excluding source and BEAM.
State detail reads the host's actual committed state with a finite timeout. Failed/
stopped workers explicitly omit state; an unavailable host reports available false
and state_omitted. State inspection never invents workers or reruns init/schema.

Topology entries contain from/to logical IDs, successful delivery count and pending
count. Unknown targets do not create unbounded graph nodes. Workers and directed
edges each paginate in sorted order with independent positions inside next_cursor.
Use the returned cursor with the same detail until next_cursor is null; limit may
change. A mutation/lifecycle change invalidates earlier generation cursors; a cursor
from another runtime or detail is also invalid. INVALID_ARGUMENT includes a hint to
restart pagination without cursor. Worker-specific reads cannot take a cursor.
Client reconnect alone does not invalidate cursors or advance generation.

Large read payloads may omit limits, artifact metadata or state with explicit
limits_omitted/artifact_omitted/state_omitted and truncated markers, then shrink the
returned worker/edge page while retaining progress in next_cursor. Pagination also
sets truncated when more items remain. Nested omission markers describe omitted
worker fields. Stored state and mutation inputs are never truncated. If even a
minimal snapshot cannot fit the configured ceiling, return bounded LIMIT_EXCEEDED;
the minimum 1 KiB ceiling does not promise every snapshot will fit.

The JSON envelope appears as text content and identical `structuredContent`,
which Hermes can serialize for clients supporting structured tool results. Older
clients can use the text representation. Errors include bounded `code`, `message`,
and `details` alongside version/generation. Entire encoding, including JSON-RPC ID
and escaped duplicate content, must fit the response limit. Response overrides
must allow at least 1,024 bytes for correlated fallback errors.

## Incremental implementation

Replacement remains pending its feature task.
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
Peers, Manager and HTTP remain alive. Manager marks the worker `restarting` and
schedules a bounded init attempt after 100 ms using its retained active artifact and
config. A successful restart has a new diagnostic PID and Registry mapping; logical
worker ID stays fixed. **Phase 1 loses volatile state across crashes**: init reruns,
rather than restoring the last event's state. Worker revision advances on host death
and on each restart attempt; state revision advances only on successful reinitialization.
Generation advances once per crash or attempt, including a failed attempt.

Each worker allows three automatic attempts per rolling 10,000 ms. Failed init
counts toward the same budget as successful reinitialization. Exhaustion retains
status `failed`, omits unavailable state/PID and requires a fresh explicit start;
no fourth retry is scheduled inside the window. Starting a stopped/failed worker
explicitly resets its budget. Starting a running/restarting ID yields WORKER_EXISTS.
Invoke during restart or after exhaustion yields WORKER_NOT_RUNNING. Callback task
failure/timeout retains its live host and does not consume restart budget.

Inspection/start results include restart_count (attempts retained at the latest
lifecycle change), restart_limit 3 and restart_window_ms 10000. Stopping a worker
cancels its retry timer and invalidates the incarnation token; old monitor and retry
messages cannot resurrect it or affect a newer explicit start. Lifecycle history
correlates crashes, attempts, successful restarts, init failure and exhaustion to
the originating request. Recovery is in-memory only and does not recover a failed
Manager, artifact registry or BEAM.

Request replay returns the original outcome and generation without another host or
stop, even if later operations have changed the worker. Inspect to obtain current
status. Callbacks use an independent kernel coordinator so killing their owner also
cancels and joins generated execution and tracked helpers; HTTP client disconnect
does not kill the host or Manager and therefore does not cancel accepted work.


## runtime_invoke

Invoke takes required worker_id, event (a JSON map) and request_id. It calls
handle_event/2 in an unlinked monitored callback task, bounded by the same 200 ms
and 8 MiB controls as init. Manager serializes requests; the host stages the full
callback outcome before publishing a new committed state.

A valid `{:ok, reply, new_state, effects}` returns reply, worker_revision, state_revision
and accepted effect IDs. Reply may be any JSON value; event, reply and state each have
16 KiB encoded/16-level application bounds. Success advances state_revision and
global generation once, retaining host PID and worker_revision. Both semantic
limits and complete duplicated/escaped MCP response size are checked before commit.

Malformed tuples, non-JSON reply/state and unsupported or malformed effects yield INVALID_TRANSITION;
size/depth/wire excess yields LIMIT_EXCEEDED. Explicit callback errors, exceptions
and exits yield CALLBACK_FAILED with a bounded reason (at most 2 KiB UTF-8), without
raw exception stack traces. A deadline yields CALLBACK_TIMEOUT. Every rejected
transition preserves the last state, revisions and PID; killed/late callback tasks
cannot commit. Unknown workers yield WORKER_NOT_FOUND; stopped/failed workers yield
WORKER_NOT_RUNNING. A healthy peer remains usable after a callback timeout.

Request replay returns the original successful or failed outcome, without another
callback, increment or effect. Changing payload/operation under the same request_id
returns REQUEST_ID_CONFLICT.

For the documented counter template, call runtime_invoke with:

```json
{"worker_id":"counter","event":{"increment":1},"request_id":"counter-increment-1"}
```

Then inspect the worker's committed state. A lost HTTP connection does not cancel
accepted Manager work: reinitialize a fresh client and retry the identical request
with the same request_id to obtain its recorded outcome. JSON-RPC IDs remain a
separate transport correlation mechanism. Actual HTTP tests close the physical
connection at a test-only callback barrier, release accepted work, and prove a
fresh client observes exactly one increment in the same host.

## Kernel-managed effects

A successful event may return up to 16 effects, with exact string-key shapes:

```json
{"type":"emit","to":"aggregate","event":{"amount":5}}
{"type":"schedule","to":"aggregate","delay_ms":100,"event":{"amount":5}}
{"type":"log","level":"info","message":"incremented","metadata":{"amount":5}}
```

Events must be JSON maps within 16 KiB/depth 16. Schedule delay is an integer from
0 through 60,000 milliseconds. Log levels are debug, info, warning or error;
message is valid UTF-8 within 2 KiB and metadata is a JSON map within 2 KiB/depth 16.
Unknown keys/types and malformed fields yield INVALID_TRANSITION; excess count,
bytes, depth, delay or pending capacity yields LIMIT_EXCEEDED. The entire batch,
reply, next state and full encoded response must pass before state changes. Rejected
callbacks/transitions produce no logs, timers or downstream events.

Dispatcher reserves batch capacity before host commit. Reservations count against
256 total pending deliveries/timers, including active deliveries. Uncommitted
reservations release on host death, validation failure, explicit cleanup or a
seven-second expiry. Empty batches need no reservation. After the host confirms
its committed revision, Manager publishes the batch once. A result such as
`{"effect_id":"<64 lowercase hex characters>","status":"accepted"}` acknowledges
admission; downstream delivery may still fail. The SHA-256 identity derives from
the originating request ID and bounded effect path. Internal delivery operations
have their own request ledger IDs while inheriting originating correlation and
remaining hop budget. Identical source retries replay their original accepted IDs.

Emit and due timers queue asynchronous messages to Manager, which uses the same
bounded host transition/ledger path as client invokes. Workers never call each
other synchronously. Each originating invoke permits 16 deliveries along any
chain; further effects record HOP_LIMIT without another delivery. Missing/stopped
or restarting destinations and callback/ledger/deadline failures record effect_failed
without rolling back the accepted source. The dispatcher does not retry failed
emissions. Unclaimed delivery messages expire after the operation deadline.

Explicit stop cancels pending effects/timers owned by that source and synchronously
releases its logical registration before acknowledging completion. Incarnation
tokens discard already-fired stale timer messages; a delayed destination resolves
by logical ID at delivery, so a recovered host receives it when running. Source
crashes do not cancel already committed timers; their eventual delivery or failure
is recorded. Stop cancels them even if the source has since restarted. Relationship
counts aggregate successful deliveries only, bounded by retained worker IDs.

Structured logs enter Logger with bounded mixir_metadata plus effect/request IDs,
and a correlated effect_log history record. Lifecycle history also records effect
acceptance, scheduling, delivery and failure. Use runtime_events for history and runtime_inspect for bounded relationship pages.

All admission, timers and delivery state are in memory. Dispatch is best effort
once per committed batch, without an exactly-once crash guarantee. A crash between
host state commit and batch publication can lose effects in Phase 1. Dispatcher
loss is fatal to the kernel rather than restarting empty admission authority;
BEAM/kernel recovery and durable outboxes remain later-phase work.

## runtime_events

All arguments are optional: after is an exclusive nonnegative sequence cursor
(default 0), limit is 1 through the configured page maximum (default 25, maximum
100), and worker_id filters a retained logical worker. Unknown worker IDs yield
WORKER_NOT_FOUND; unknown keys, invalid IDs/cursors/page sizes yield INVALID_ARGUMENT
(or a JSON-RPC schema error for type/range violations). Reads carry API version and
current generation and do not change generation or call generated callbacks.

Results contain events, next_cursor, oldest_sequence, gap, dropped and truncated.
Each event has a monotonic sequence, UTC timestamp, type, worker/logical ID where
applicable, artifact revision, request/correlation ID, outcome and bounded metadata.
Effect records also include deterministic effect_id. The ring holds at most 1,000
records with metadata at most 2 KiB/depth 16; oversized metadata is omitted with a
record-level truncated flag. dropped counts evictions; page-level truncated counts
metadata truncations in the ring's lifetime. gap is true if after precedes the
oldest retained sequence. No Phase 2 recovery history is fabricated.

Continue using next_cursor. Filtered empty pages advance to the scanned history
head, so a client does not repeat old unmatched records. Sequence cursors work
across client sessions in the same BEAM and are independent of inspection's opaque
generation cursors. A BEAM restart loses history and resets sequence numbering.

Whole-response preflight includes duplicated escaped text/structured content and
maximum JSON-RPC correlation ID. Oversized event pages shrink to a safe prefix,
set page_truncated true and return the last included sequence as next_cursor. A
single oversized record may omit metadata explicitly; the event and cursor are
retained. If even that record cannot fit, return bounded LIMIT_EXCEEDED instead of
silently skipping it. History is read-only; response omissions do not edit records.

Examples of tool arguments:

```json
{"after":0,"limit":25,"worker_id":"counter"}
```

Read the next page with the returned next_cursor as after. Inspecting the runtime
or reading history from a fresh client leaves workers, revisions and generation
unchanged.
