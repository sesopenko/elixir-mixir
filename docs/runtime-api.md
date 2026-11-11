# Runtime API version 1

The implemented MCP tools are `runtime_inspect`, `runtime_define`, `runtime_start`,
`runtime_stop`, `runtime_invoke`, `runtime_events` and `runtime_replace`.
Default runtime metadata is in memory; no generated application is seeded at startup.
Optional durable mode retains definitions, state, implementation selections, request
outcomes and pending work across abrupt restart, as described below.

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
on valid requests, including zero. They are separate from mutation
`request_id` values. Incoming bodies and complete encoded tool responses default
to 64 KiB. Invalid protocol data uses bounded JSON-RPC errors and appropriate 4xx
status; runtime failures use an HTTP 200 tool result with `isError: true`.

## runtime_inspect

Arguments are optional; omission is equivalent to an empty object:

| Argument | Contract |
| --- | --- |
| `worker_id` | ASCII identifier `[a-zA-Z0-9_-]{1,64}`; selects a retained worker, or `WORKER_NOT_FOUND` |
| `detail` | `summary` (default), `state`, or `recovery`; state includes bounded committed worker state; recovery paginates quarantine diagnostics |
| `limit` | Integer from 1 through configured page maximum (default maximum 100) |
| `cursor` | Opaque string from a previous runtime page; bound to this runtime, generation and detail |

Unknown keys, invalid IDs, explicit null values, unsupported detail and malformed
cursors return `INVALID_ARGUMENT`. Schema type violations produce protocol errors.
Inspection is read-only and never executes generated behavior. It reports
`api_version: "1"`, current generation (zero for an empty runtime), health, worker_count,
edge_count, sorted worker pages, topology, pending effects/timers/reservations,
configured limits and ledger capacity/retention. Worker summaries include diagnostic
PID, status, revisions, restart budgets and cached immutable artifact metadata
(ID/logical name/revision/schema/source hash/contract), excluding source and BEAM.
State detail reads the host's actual committed state with a finite timeout. Failed/
stopped workers in memory mode explicitly omit state; durable mode can report their
retained checkpoint. An unavailable host reports available false
and state_omitted. State inspection never invents workers or reruns init/schema.

Topology entries contain from/to logical IDs, successful delivery count and pending
count. Unknown targets do not create unbounded graph nodes. Workers and directed
edges each paginate in sorted order with independent positions inside next_cursor.
Use the returned cursor with the same detail until next_cursor is null; limit may
change. A mutation/lifecycle change invalidates earlier generation cursors; a cursor
from another runtime or detail is also invalid. INVALID_ARGUMENT includes a hint to
restart pagination without cursor. Worker-specific reads cannot take a cursor or use recovery detail.
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

## Verified capabilities

All seven tools support the documented memory and durable workflows. The
[Phase 1 demonstration](../examples/phase_1_demo.md) records live evolution and
client reconnection; the [Phase 2 demonstration](../examples/phase_2_recovery.md)
records actual Codex sessions around abrupt termination, automatic recovery and
further evolution. Automated tests cover interruption and failure paths separately.
Mutations preflight complete wire outcomes before publication. Durable operations
commit authoritative records before live publication and acknowledgement.

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
migration. Hosts and the dispatcher validate state transitions and effect admission.

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
go to the bounded EventLog ring, readable through `runtime_events`.

Generated macros, compile-time code and schema callbacks execute with VM privileges.
AST checks, task heap flags and deadlines are not a secure sandbox or a total VM
memory/atom budget. Compile-time side effects cannot be rolled back. Run experiments
only in a trusted disposable environment without secrets or valuable infrastructure.
Loss of Manager or artifact-registry authority shuts down the kernel. Memory mode
loses artifact metadata on BEAM exit; durable mode recompiles retained sources on
the next startup.


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
Unknown IDs return WORKER_NOT_FOUND. Explicit start of a failed ID must use its
retained artifact/config; changing either first requires runtime_stop, otherwise
INVALID_ARGUMENT includes a stop-first hint. A stopped ID may supply a new
config/artifact. Successful reinitialization advances worker and state revisions.
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

Unexpected host death removes its
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
the originating request. This automatic init-based restart describes memory mode.
Durable mode restores committed state and persisted restart budgets as described below.

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

The delivery behavior in this section describes default memory mode. Durable mode
accepts the same intent shapes and resumes committed work as described under
[durable pending effects](#durable-pending-effects-and-delivery).

A successful event may return up to 16 effects, with exact string-key shapes:

```json
[
  {"type":"emit","to":"aggregate","event":{"amount":5}},
  {"type":"schedule","to":"aggregate","delay_ms":100,"event":{"amount":5}},
  {"type":"log","level":"info","message":"incremented","metadata":{"amount":5}}
]
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
Durable mode retains and resumes committed intents across restart as described below.

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

## runtime_replace

Required arguments are worker_id, artifact_id, expected_revision (positive integer)
and request_id. The artifact must already be defined; defining never activates it.
expected_revision refers to the current **worker_revision**, distinct from artifact
revision and runtime generation. Unknown artifacts/workers yield ARTIFACT_NOT_FOUND/
WORKER_NOT_FOUND; stopped, failed or restarting workers yield WORKER_NOT_RUNNING.
Unknown keys and invalid values yield INVALID_ARGUMENT or schema errors.

The existing host checks expected_revision within its serialized transition. A
stale competitor yields REVISION_CONFLICT and cannot overwrite newer work. For a
matching schema, replace preserves state and state_revision exactly and does not
call migrate or init. A schema change calls the candidate migrate/2 under the
200 ms/8 MiB callback controls with string-key metadata:

```text
worker_id, old_artifact_id, new_artifact_id, old_state_schema, new_state_schema,
worker_revision, state_revision, request_id
```

Only `{:ok, new_state}` with a valid bounded JSON map may migrate. Errors,
exceptions, exits, timeout/heap failures, malformed tuples, non-JSON or oversized
migration state yield MIGRATION_FAILED with a bounded details.cause and optional
reason; no raw stack traces. Migration cannot emit effects. Every failed migration
retains the old artifact, state, PID and revisions. Complete response overflow
returns LIMIT_EXCEEDED before commit. Rejected source/missing callbacks fail during
define and leave active workers unchanged.

Successful replacement atomically updates the same host's artifact/data/revisions.
worker_revision and generation advance once; state_revision advances only for an
explicit schema migration. Results contain artifact_id, previous_revision and
new_revision (artifact revisions), worker_revision, state_revision, migration_result
(preserved or migrated), and equal pid_before/pid_after. Manager acknowledges only
after confirming the candidate/revisions in the same live host. Host death observed
during staging/confirmation in memory mode yields CALLBACK_FAILED and ordinary
lifecycle recovery, rather than replacement success. Memory-mode recovery reruns
retained config with the last Manager-confirmed artifact and loses volatile state.
Durable commit/publication failures follow the fail-closed recovery rule below; a
known committed success is never overwritten by a publication failure.

Accepted operations are serialized; queued events run entirely before replacement
with the old callback/state or afterward with the new callback/state. No event mixes
the candidate callback with the prior schema. Old artifacts stay immutable and
loaded. Same request retries replay the original replacement outcome; different
arguments under that ID yield REQUEST_ID_CONFLICT. Disconnect does not cancel
accepted migration. A fresh client can replay and then inspect current live state.

Rollback is another explicit replace using the current worker_revision. Crossing
back to an old schema requires a valid reverse migrate callback in that artifact;
there is no automatic reverse migration or state rollback after later events.
History records implementation_replaced, migration_failed, replacement_failed and
host lifecycle outcomes with bounded diagnostic context.

## Tool argument examples

These are arguments to the named MCP tools. Substitute returned artifact IDs and
the latest inspected worker_revision. Each new mutation needs a fresh request_id;
reuse a request_id only for an identical retry. The counter below is runtime source,
not code seeded in the kernel.

runtime_define:

```json
{"logical_name":"counter","source":"defmodule Generated do\n  @behaviour ElixirMixir.Behavior\n  @impl true\n  def init(config), do: {:ok, %{\"count\" => Map.get(config, \"initial\", 0)}}\n  @impl true\n  def handle_event(%{\"increment\" => amount}, state), do: {:ok, state[\"count\"] + amount, %{\"count\" => state[\"count\"] + amount}, []}\n  @impl true\n  def state_schema(), do: 1\n  @impl true\n  def migrate(state, _metadata), do: {:ok, state}\nend","expected_behavior":"elixir_mixir.behavior.v1","request_id":"define-counter-1"}
```

runtime_start:

```json
{"worker_id":"counter","artifact_id":"<artifact_id_from_define>","config":{"initial":0},"request_id":"counter-start-1"}
```

runtime_invoke:

```json
{"worker_id":"counter","event":{"increment":1},"request_id":"counter-increment-1"}
```

runtime_inspect:

```json
{"worker_id":"counter","detail":"state"}
```

runtime_events:

```json
{"after":0,"limit":25,"worker_id":"counter"}
```

runtime_replace (first define an updated template with a new request ID):

```json
{"worker_id":"counter","artifact_id":"<candidate_artifact_id>","expected_revision":1,"request_id":"counter-replace-1"}
```

runtime_stop:

```json
{"worker_id":"counter","request_id":"counter-stop-1"}
```

## Experimental durable storage

Memory mode remains the default. `ELIXIR_MIXIR_DATA_DIR` opts into an exclusive,
expanded absolute local data directory; programmatic configuration uses `:storage`
with `mode: :durable` and `data_dir:`. Invalid configuration or unsupported format
fails startup, and store loss shuts down runtime authority. Retain the directory
across BEAM lifetimes and never share it between running VMs.

Runtime summary inspection adds `storage.mode` (`memory` or `durable`) and
`storage.format_version` (null in memory, currently 1 in durable mode). Absolute
host paths are omitted. Durable mode supports source definitions and retained
outcomes, start/stop, event state recovery and implementation replacement.
Complete outgoing effect batches commit with state; durable delivery resumes after recovery. Memory tools keep their existing
behavior. The [Phase 2 verification record](sdlc/phase02-restart/verification.md)
links the automated tests and actual-client evidence for these contracts.

### Preparing worker changes

In memory mode, the coordinator prepares invocation and replacement results inside
the existing host, validates the complete response and reserves effect capacity,
then publishes the candidate and releases the batch for dispatch. Reads of a host
continue to return its committed state while a candidate is prepared. Aborting or
expiring a candidate leaves the old implementation, state and revisions intact.
Only the owning Manager may prepare, publish or abort; publication tickets bind
an operation to base revisions and a particular host incarnation. Repeating the
last publication does not rerun generated callbacks.

Candidate startup has no logical route. Manager registers the live host PID as
the Registry value after init and response preflight, and removes that route on
stop or host death. The Registry registrant is the Manager, so kernel lookups must
use the explicit value. Owner death terminates candidates and releases reserved
capacity. Durable lifecycle operations use the same unrouted candidate boundary;
durable replacement uses that same commit boundary. Pending batches commit with
originating state before publication.

### Durable source definitions and request replay

Durable mode now supports `runtime_define`. It first persists a request admission
with a unique operation ID, compiles without publishing the registry entry, then
atomically stores the source, hash, logical revision, exact response and bounded
audit record. Registry publication follows that commit. Source artifacts and
completed definition errors survive abrupt BEAM termination. Start/stop and initial
state recovery, event invocation and replacement are integrated.

Boot validates retained hashes/contracts and recompiles valid definitions in
artifact-ID order using fresh slots from the fixed module pool. Artifact IDs are
opaque random strings; clients must not infer a slot or revision from them.
Logical revision high-water marks survive even an invalid retained definition.
Source/hash/contract/schema failures retain their evidence and appear as bounded
artifact diagnostics under `recovery` in summary inspection; other valid artifacts
recover independently. Retained capacity beyond configured or remaining lifetime
slots fails readiness rather than silently recovering a subset.

`GET /health` returns 503 until recovery finishes, then 200. During recovery, tools
return `RUNTIME_RECOVERING` before admitting mutations. Summary inspection includes
`recovery.status`, artifact counts, `degraded`, bounded diagnostics, `boot_id` and `lineage_id`.
The lineage stays with the store; each Manager boot gets a new boot ID. Absolute
storage paths and source text remain omitted from public inspection. Desired worker
definitions, selected implementations and committed state restore as described
below; pending effect intents survive and resume after healthy routes are restored.

An admitted definition or lifecycle operation with no committed outcome becomes a retained
`OPERATION_INTERRUPTED` error on restart without changing generation. A new request
ID may retry it. A completed request replays its exact historical response, even
if the original response or registry publication was interrupted. Changing its
arguments returns `REQUEST_ID_CONFLICT`. Module/PID strings in historical responses
are diagnostics from that operation; they are not current handles. Current
inspection is authoritative, and a new VM may reuse a printed PID or module slot.

Completed results expire on admission after the configured retention interval
(default 10 minutes, maximum 1,024 retained requests), including downtime. A
backward wall-clock change delays expiry. An expired request ID may execute again
and create a new artifact/revision; this is bounded replay, not indefinite
idempotency. A full retained ledger returns `BUSY` without evicting outcomes.
An uncertain store write or failed publication closes availability; restart reads
the actual committed result. Direct compile-time IO by trusted generated code is
outside this transaction boundary and may repeat on recompilation.


### Durable worker lifecycle

`runtime_start` runs bounded init in a supervised but unrouted candidate. It commits
worker/config/desired status, selected artifact, initial schema/state/revisions,
exact outcome and audit together before publishing its logical route. A failed init
or response preflight leaves no definition or live candidate. `runtime_stop` commits
the stopped definition and outcome before removing routing and terminating the
host. Repeated stop retains its no-op generation and revision semantics. Source
pending effects are deleted in that same stop transaction.

Boot recreates desired-running hosts in sorted logical-ID order and injects the
validated committed checkpoint. It never calls generated init or migrate. Worker
IDs, configuration, selected artifacts and committed revisions survive; PIDs,
monitors and retry tokens are new. Stopped workers remain stopped and their last
committed state remains inspectable. Explicit start initializes from supplied
config again and advances the state revision. Worker detail inspection adds config;
durable worker summaries add `desired_status`. Existing bounded omission applies.

Unexpected durable host death also restores its latest committed event state. A crash
and each retry persist lifecycle revisions and generation, but restoration does
not advance the committed state revision. The three-attempt/ten-second rolling
budget uses persisted UTC timestamps. Exhaustion remains failed across VM restart;
manual start resets it. Stop before changing a failed or quarantined artifact/config.
Stale monitor and retry tokens cannot change a newer incarnation.

Missing/unusable artifacts and mismatched schema/state quarantine the affected
worker while healthy workers recover. Recovery summary adds `workers`,
`workers_restored`, `workers_quarantined` and bounded `worker_diagnostics`.
Original records remain available for diagnosis. Stop and start a valid definition
to repair one; recovery never silently migrates stored state.

Readiness stays closed through worker validation, reconstruction and routing.
Reads and mutations return `RUNTIME_RECOVERING` before admission even if Manager
is occupied reconstructing hosts. Wait for health 200, then initialize a new MCP
session. No client is needed to perform reconstruction. Durable replacement is
integrated; committed durable effects resume after recovery.


### Durable event transitions

`runtime_invoke` accepts durable events and complete effect batches. The host runs its bounded
callback once while keeping the old state public. Manager reads the validated
prepared checkpoint, then atomically commits state/schema/revision, exact request
result, generation and audit. It publishes the matching host candidate only after
the durable commit, then acknowledges. The request operation ID and checkpoint's
last operation ID identify that same transaction. Replays and callback failures
never advance committed state or generation.

A valid emit/schedule/log batch is retained atomically with its originating state
and exact outcome. Delivery follows commit and resumes after recovery. Invalid
state/reply/effects, callback failure or timeout, and
response-size rejection similarly preserve the prior checkpoint. Memory mode
retains its complete existing effect behavior.

If a Store commit raises, times out or has an uncertain result, runtime authority
and readiness close. A failed publication after a known commit follows that same
shutdown path; it never replaces durable success with `CALLBACK_FAILED` or continues
from old volatile state. Restart reads actual disk authority. Before-commit
interruption replays `OPERATION_INTERRUPTED` with old state; an already committed
request replays its exact historical reply and generation with new state. Use the
same request ID and arguments after an uncertain response. Expired replay records
may execute again, including after downtime.

Unexpected host death and VM reconstruction inject the latest committed event
state without init/migration or a new state revision. Lifecycle crash/retry revisions
and budget changes remain durable. Generated direct IO is outside this boundary:
callbacks retain trusted VM privileges and their external effects cannot be rolled
back or made exactly-once by committing kernel state.


### Durable implementation replacement

`runtime_replace` now commits the selected artifact, state/schema/revisions, exact
outcome, generation and audit atomically. Expected revision is the inspected
`worker_revision`. Migration runs only when schemas differ, under the existing
callback heap/deadline and result limits. A matching schema preserves state and its
state revision. The prepared candidate stays hidden until its durable commit, then
publishes inside the same host; uninterrupted live replacement retains that PID.

After a VM restart, the selected artifact recompiles and the committed schema/state
inject directly into a fresh host, with no migration callback. Retained replacement
requests replay their exact historical result, including old PID diagnostics.
Current inspection and boot identity describe the new process lifetime.

Bad source/contract, missing artifacts, stale revisions, invalid or failing migration,
timeout and response-budget failure leave prior selection/state/revisions intact.
The same Store-uncertainty/publication-failure shutdown protocol applies. Before-
commit interruption restores the old selection/state; after commit it restores the
new pair even if publication or response was interrupted. Direct migration IO may
already have happened before an uncommitted interruption and cannot be undone by
kernel transactions. Replacement preserves pending work.


### Durable pending effects and delivery

An accepted invocation stores every validated intent with its originating state,
revisions, exact outcome and audit in one transaction. A batch with an invalid
member or insufficient capacity is rejected as a whole. State/reply validation and
response preflight release reservations without committing a partial batch.

Effect IDs derive from the persisted unique operation ID and effect path. Caller
request correlation remains separate: retained replay returns the same IDs, while
an expired caller key executing again creates distinct IDs and preserves old work.
Only bounded JSON context is retained: source/target, artifact revision, path/hops,
effect payload, operation/correlation IDs, pending status and absolute UTC `due_at`
in milliseconds. Deadlines are computed once during preparation and survive
reopening unchanged. PIDs, reservation tokens and VM timer handles are transient.

Pending records and all transient reservations share the pending-effect ceiling.
Boot reconstructs pending/timer counts without recreating reservations, and a
lowered capacity below the retained queue prevents readiness. Summary inspection
adds `effects.dispatch: "enabled"`; pending counts include logs and timer counts
include retained schedules even after their deadlines pass. Healthy routes and
queue accounting restore before readiness opens and delivery starts.

Explicit source stop deletes its still-pending intents in the same transaction as
the stopped definition and outcome. Host crash and replacement preserve them.
Direct callback IO remains outside kernel transactions and may already have run.


Manager processes one eligible intent at a time in `(due_at, effect_id)` order.
A fresh OTP timer waits for `max(0, due_at - utc_now)` milliseconds, and wakeup
rechecks both disk existence and UTC eligibility. Overdue work is immediately
eligible; a backward clock move rearms the timer. Clock changes can advance or
delay work; there is no scheduling precision guarantee beyond that wall-clock rule.

An internal emit/schedule transition atomically deletes its parent ID and commits
target state/revision, a bounded outcome audit, observed topology increment and
all child intents. The consumed parent contributes one slot to child capacity in
that same transaction. Children retain root operation/correlation and extended
paths with reduced hop budgets. Internal deduplication uses durable pending
existence rather than the expiring external request ledger. Even duplicate
wakeups after ledger expiry cannot repeat a consumed transition. Queue completion
advances generation once; a timer wakeup/claim or transient retry does not.

Restarting or `BUSY` targets retain their intent and retry after 100 ms with a fresh
volatile timer. Unknown, stopped, failed or quarantined targets, hop exhaustion,
invalid callbacks, timeout and permanent limit failures terminally consume it with
an audit. Store uncertainty instead closes runtime availability, and recovery
reads the actual committed result. A crash before target commit retains the parent;
a crash after it restores target/children without repeating the parent transition.

Logs execute after their intent commits, then record completion and remove the
intent in a separate transaction. A crash between output and completion repeats
the output. Logger metadata includes effect ID and request correlation for recipient
deduplication. This is at-least-once external IO; direct generated callback IO also
remains outside kernel state transactions. Internal state deduplication does not
make arbitrary external systems exactly-once.


### Recovery diagnostics and repair

Boot validates retained artifacts, worker/checkpoint metadata and complete effect
records before scheduling work. Invalid source/hash/contract/compilation, unavailable
references, mismatched schema and invalid state quarantine affected workers while
healthy routes recover. Invalid or orphaned intent records remain retained, count
toward queue capacity and never dispatch. Quarantined hosts are not automatically
restarted. Failed workers with an exhausted persisted restart budget retain that
status instead of gaining another budget on boot.

After reconstruction, `/health` returns 200 and summary inspection reports
`health: "degraded"` when quarantines exist. `recovery` includes `degraded`,
`quarantine_count`, artifact `quarantined`, `workers_quarantined`, `workers_failed`,
`effects_quarantined`, bounded diagnostic samples, lineage and boot identity.
The separate `storage` object reports format and mode. Worker summaries may include
`quarantine_reason`, for example `ARTIFACT_UNAVAILABLE`, `INVALID_STATE`,
`STATE_SCHEMA_MISMATCH` or `INVALID_WORKER_RECORD`. Invalid IDs are omitted; no
arbitrary disk text, original source, store path or raw exception stack is returned.

Use `runtime_inspect` with `{"detail":"recovery","limit":100}` for all diagnostic
rows. Results contain `quarantines`, `quarantine_count`, `next_cursor` and `truncated`.
Each row has `kind` (`artifact`, `worker` or `effect`), `id`, stable error `code` and
optional bounded `reason`. `id_omitted` or `reason_omitted` explicitly marks an
omission. Pages fit the complete MCP encoding even at the minimum 1,024-byte
response ceiling; follow the returned cursor with the same recovery detail until
null. These cursors bind to boot and generation, independently of worker/edge page
cursors. A stale or cross-view cursor returns `INVALID_ARGUMENT`. Last-boot counts
and rows remain a recovery snapshot; inspect individual workers for later repairs.

Compact `recovery_quarantined` audits preserve diagnostic evidence under the
existing history bound. Worker diagnostics also appear in worker-filtered
`runtime_events`. Recovery never copies full source/state into audits, rewrites
quarantined originals or increments application generation merely to record a
boot result. Readiness stays closed until validation, healthy routing, queue
accounting and wakeup reconstruction finish; tools return `RUNTIME_RECOVERING`
before mutation admission during that interval.

Repair requires explicit intent: stop the affected worker, define/select a valid
artifact and start under the same logical ID with supplied configuration. Stop
preserves its checkpoint and cancels source intents; explicit start initializes
and replaces the checkpoint. Original source artifacts remain retained. Copy the
store with the runtime stopped before repair if the damaged checkpoint itself
must be retained for investigation. No automatic boot migration occurs. A failed
explicit migration still leaves the old committed selection/state intact.

Unsupported global format/lineage, unavailable storage or any retained table above
configured capacity prevents readiness without rewriting records or falling back
to memory. Capacity validation precedes recompilation and interrupted-request
reconciliation. Store authority death closes availability. A far-future deadline
after a large backward clock jump uses bounded wakeup intervals and repeated UTC
checks; the stored absolute deadline remains unchanged.
