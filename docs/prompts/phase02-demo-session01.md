# Phase 2 actual Codex demonstration: session 1

You are the runtime evolution agent for the elixir-mixir durable restart experiment.
The independent production runtime is connected as elixir_mixir. Use ONLY its seven
runtime MCP tools. Do not use shell, filesystem, direct HTTP, other servers,
subagents, process control, or local code edits. Author behavior only as source
strings passed to runtime_define. The outer operator owns termination and storage.

First call runtime_inspect. Require storage.mode durable, format 1, health ok,
generation 0, no workers and no pending effects. If not empty, stop and report the
mismatch without modifying anything. Record lineage_id and boot_id.

API contract:
- runtime_define: logical_name, source, expected_behavior="elixir_mixir.behavior.v1",
  request_id. Every new mutation needs a distinct ASCII request_id of 1..64 chars,
  prefixed p2s1_. Identical retry must reuse identical arguments and ID.
- Source is exactly one defmodule Generated do ... end, with
  @behaviour ElixirMixir.Behavior, @impl true and four warning-free callbacks:
  init(config) -> {:ok, JSON_map}; handle_event(event,state) ->
  {:ok, reply, JSON_map, effects} or {:error, reason};
  state_schema() -> positive integer; migrate(old,metadata) -> {:ok, JSON_map}.
  Use underscore-prefixed unused variables. JSON map keys are strings.
- runtime_start: worker_id, artifact_id, config, request_id.
- runtime_invoke: worker_id, event, request_id.
- runtime_replace: worker_id, artifact_id, expected_revision (CURRENT inspected
  worker_revision), request_id. Equal schema skips migration and preserves state;
  changed schema explicitly migrates. Uninterrupted replacement retains its PID.
- runtime_inspect: worker_id and detail="state", or global limit/cursor.
- runtime_events: optional worker_id, after, limit up to 100.
- runtime_stop: worker_id, request_id; retains a stopped definition.
- Exact effect shapes: {"type":"emit","to":"aggregate","event":{"value":N}}
  and {"type":"schedule","to":"aggregate","event":{"value":N},"delay_ms":60000}.
  Accepted IDs acknowledge durable admission. Poll MCP inspection for delivery.

Perform every step and verify actual results:
1. Define counter v1 with logical_name counter, schema 1 and init state
   {"count":0,"target":"aggregate"}. Positive integer amount events add amount
   to count and emit the NEW count as value to aggregate. Invalid amounts reject.
   Its migrate callback can preserve old state. Do not invoke before aggregate exists.
2. Define aggregate, schema 1, init {"events":0,"total":0}. Each integer value
   event adds 1 to events and value to total, with no effects. Start aggregate and
   counter with empty configs. Inspect both initial states and PIDs.
3. Invoke counter amount 2 and then amount 3 with separate IDs. Poll until counter
   count=5 and aggregate events=2,total=7. Observe two successful topology deliveries.
4. Define counter v2, same logical_name counter, state_schema 2. Its init must
   support nested {"schema":2,"counter":{"count":0,"target":"aggregate"}}.
   migrate explicitly converts the old flat state, preserving count=5 and target.
   Its positive amount handler adds TWICE amount and emits the new count. It must
   also support {"op":"schedule","value":integer,"delay_ms":60000}: return the
   existing state unchanged, reply "scheduled", and one kernel schedule to its
   target with that value. Do not use Process timers, IO or kernel internals.
   Replace using the current worker_revision. Inspect same PID, migrated nested
   count=5, schema 2 and artifact revision 2. Invoke amount 4; poll until nested
   count=13 and aggregate events=3,total=20. Inspect both and topology count=3.
5. Exercise retained stopped definitions: start stopped_probe using counter v1's
   artifact and empty config, never invoke it, then stop it. Inspect stopped status
   and preserved count=0. Read runtime_events for delivery/replacement history.
   This completes all seven tool types. Keep counter and aggregate running.
6. LAST MUTATION: invoke counter {"op":"schedule","value":11,"delay_ms":60000}
   with a fresh ID. Record the accepted effect ID. Immediately inspect counter,
   aggregate and runtime summary. Require counter still nested count=13, aggregate
   events=3,total=20, pending=1,timers=1,reserved=0. Do not wait for the timer.
   After those inspections FINISH IMMEDIATELY so the operator can disconnect and
   kill the runtime before the 60-second deadline. Do not do further tool calls.

Finish with ONE JSON object (no Markdown fences) containing the final counter,
aggregate, stopped_probe and summary snapshots, schedule request/effect IDs,
artifacts with source hashes/revisions, and each assertion's observed result.
Do not claim an unobserved assertion passed. Never stop the container or the two
running workers. The CLI transcript records actual MCP arguments and results.
