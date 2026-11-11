# Phase 1 actual runtime demonstration: session 1

You are the runtime evolution agent for the elixir-mixir Phase 1 demonstration.
The already-running disposable runtime is connected as the elixir_mixir MCP server.
Complete this entire experiment now, using ONLY that server's seven runtime tools.
Do not use shell, filesystem, code editing, direct HTTP, other servers, subagents,
or process-control tools. Do not create domain behavior in local files. Generate
all behavior as source strings passed to runtime_define. All state/artifacts live
inside this independent runtime, which must remain running when you finish.

First call runtime_inspect and verify health ok, generation 0 and no workers. If
not fresh, stop and report that mismatch instead of changing existing workers.

Contract and API:
- runtime_define requires logical_name, source, expected_behavior exactly
  elixir_mixir.behavior.v1, and a fresh ASCII request_id (1..64 chars).
- Source must be exactly one defmodule Generated do ... end. Include
  @behaviour ElixirMixir.Behavior and @impl true before each of four callbacks:
  init(config) -> {:ok, map} | {:error, reason};
  handle_event(event, state) -> {:ok, reply, map, effects} | {:error, reason};
  state_schema() -> positive integer;
  migrate(old_state, metadata) -> {:ok, map} | {:error, reason}.
  Use underscores for unused variables, and avoid compiler warnings.
- Config/event/state are JSON maps with string keys. Do not use atoms as map keys.
- runtime_start requires worker_id, artifact_id, config, request_id.
- runtime_invoke requires worker_id, event, request_id.
- runtime_replace requires worker_id, artifact_id, expected_revision (CURRENT
  worker_revision from inspection, not artifact revision), request_id.
- Matching schema preserves state and skips migrate; changed schema calls the
  candidate's migrate with the prior state and metadata. Never reruns init on replace.
- runtime_inspect accepts worker_id and detail state, or global limit/cursor.
- runtime_events accepts after (exclusive sequence, default 0), limit up to 100,
  optional worker_id; use it to observe accepted/delivered/failed effects.
- runtime_stop requires worker_id and request_id; it retains a stopped definition.
- Effects have exact string-key shapes:
  {"type":"emit","to":"aggregate","event":{"value":new_count}}
  {"type":"schedule","to":"probe","delay_ms":25,"event":{"op":"tick"}}
  {"type":"log","level":"info","message":"phase1-probe","metadata":{"kind":"demo"}}
  Accepted effect IDs acknowledge admission. Poll inspection/events until delivery.
- Use a distinct demo-prefixed request ID for each new mutation. Identical retries
  must reuse the exact original arguments/request ID. Errors leave prior live state.

Perform all steps, checking actual tool results, not just narrating intentions:
1. Define counter v1 (logical_name counter, schema 1), init count 0. It may retain
   target="aggregate" as an extra state field for later versions. Start worker
   counter, invoke one increment, inspect and record its PID/count=1/revisions.
   V1 emits no effects. Keep this PID through all normal replacements below.
2. Define/start worker aggregate (logical_name aggregate, schema 1), initially
   {"events":0,"total":0}. A {"value":integer} event increments events once and
   adds the value to total. All four callbacks must be valid.
3. Define counter v2 (same logical_name counter, schema 1) that increments count
   by one and emits the NEW count to aggregate as {"value":new_count}. Replace
   counter using its current worker_revision. Inspect exact compatible state and
   unchanged PID. Invoke twice. Poll until counter count=3, aggregate events=2,
   total=5. Inspect observed topology counter -> aggregate, delivered count=2.
4. Define counter v3 (schema 1) accepting {"amount":positive_integer}, increasing
   count by that amount and emitting the new count. Replace with current revision,
   preserving PID and count=3. Invoke amount=4. Poll for counter count=7 and
   aggregate events=3,total=12. Invoke amount=0 and amount=-1 with separate IDs;
   both must fail. Inspect after EACH rejection: counter state/artifact/PID and
   worker/state revisions must remain identical to the baseline count=7 snapshot.
5. Define counter v4 with state_schema 2. Its migrate/2 must explicitly turn the
   prior flat counter state into an explicitly versioned nested map, retaining
   count=7 and routing information, for example
   {"schema":2,"counter":{"count":7,"target":"aggregate"}}.
   Init and handle_event must support the new shape, and the event callback must
   still accept positive amounts/emit new counts, but DO NOT increment it again.
   Replace at the current revision. Inspect the same PID, value 7, active v4
   artifact and advanced worker/state revisions. Aggregate remains events=3,total=12.
6. Submit invalid source "defmodule Generated do" via runtime_define with a new ID.
   Confirm COMPILE_FAILED, then inspect counter and prove all active fields remain.
   Define a VALID inactive counter candidate with state_schema 3 and migrate/2
   returning {:error, "deliberate migration failure"}. Attempt replacement at the
   current revision. Confirm MIGRATION_FAILED and inspect unchanged active
   artifact/state/PID/worker/state revisions. Then attempt a replacement using a
   stale positive expected_revision. Confirm REVISION_CONFLICT and inspect again.
   Candidate definition itself may advance global generation; compare rejection
   baselines AFTER its successful definition. No automatic reverse migration.
7. Demonstrate delay/log separately so arithmetic above stays unchanged: define
   and start worker probe with {"seen":0}. A trigger event returns one structured
   log (phase1-probe) and one 25-ms schedule TO ITSELF with {"op":"tick"}. Tick
   increments seen once and emits nothing. Invoke trigger, inspect seen=1
   eventually, and read runtime_events to confirm the correlated log, scheduling
   and delivery. Then runtime_stop probe with a fresh ID, inspect stopped status.
   Do not stop counter or aggregate. Do not stop the runtime.
8. Read final counter and aggregate state plus runtime summary/history. Ensure
   no pending effects/timers; counter still value 7 in schema 2, aggregate still
   events=3,total=12, both original PIDs retained. All seven tools should have
   been exercised. Failed compile/migration/revision outcomes must be observable.

Finish with ONE JSON object containing counter and aggregate final inspection
snapshots, probe final status, runtime generation, and artifacts (each successful
runtime_define role, artifact_id, source_hash, revision and state_schema). Include
failure codes and whether each required assertion passed. Do not claim success
for any failed or unobserved assertion. Leave the runtime alive for a completely
fresh client session. Source strings and actual MCP results are captured by the
outer CLI event transcript; you do not need to save any files.
