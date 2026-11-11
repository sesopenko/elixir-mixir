# Phase 2 actual Codex demonstration: session 2

You are a NEW runtime evolution client after automatic durable recovery. Use ONLY
elixir_mixir's seven MCP runtime tools. No shell, filesystem, direct HTTP, other
servers, subagents, process control or kernel edits. Author application behavior
only through runtime_define source strings. Do not reconstruct missing workers:
this experiment must inspect the already recovered application first.

Use fresh ASCII mutation request IDs prefixed p2s2_. Source must be one
`defmodule Generated`, @behaviour ElixirMixir.Behavior, four warning-free @impl true
callbacks init/1, handle_event/2, state_schema/0 and migrate/2. JSON map keys are
strings. runtime_replace expected_revision is the CURRENT inspected worker_revision.
Matching schema preserves state and skips migrate. Effect shape is exactly
{"type":"emit","to":"aggregate","event":{"value":new_count}}.

The earlier actual client created counter schema 1, invoked amounts 2 and 3, then
migrated counter to schema 2 with state
{"schema":2,"counter":{"count":13,"target":"aggregate"}}. Its selected artifact
revision is 2 and it adds twice each positive amount. Aggregate initially reached
{"events":3,"total":20}. The client scheduled value 11 with a 60-second deadline,
exited, and the operator SIGKILLed and recreated the production container with the
same volume. An automated read-only observer verified recovery and that timer's
single delivery WITHOUT a Codex/LLM connection. Aggregate is now events=4,total=31.
The stopped_probe definition remains stopped with count=0.

Perform and verify these actions now:
1. First call runtime_inspect summary, then inspect counter and aggregate with
   detail state and inspect stopped_probe. Require durable storage, ready/healthy,
   no pending work, the nested count=13 with artifact revision 2/schema 2, aggregate
   events=4,total=31, and stopped_probe still stopped. Record boot/lineage, selected
   artifact IDs/hashes, current PIDs and worker/state revisions. Do not start workers.
2. Invoke counter amount 1. Its recovered v2 behavior must produce count=15.
   Poll until aggregate events=5,total=46. Inspect both actual states.
3. Define counter v3 under logical_name counter, same schema 2, supporting the same
   nested state. Its event handler must add THREE TIMES each positive amount and
   emit the new count to aggregate. Preserve target. Invalid amounts reject. Init
   supports nested state. migrate may return {:error,"same-schema migration must
   not run"} because this replacement must skip migration. Use underscore variables
   where unused. Replace with the current inspected worker_revision. Require
   artifact revision 3 (revision high-water survived), migration_result preserved,
   count=15 and the same post-recovery PID.
4. Invoke counter amount 2. Poll until count=21, aggregate events=6,total=67. Inspect
   both. Reject amount 0 with a new request ID; inspect that counter state/artifact/
   PID/worker_revision/state_revision stay unchanged by the rejection.
5. Read runtime_events and summary. Confirm recovered timer history and subsequent
   deliveries, no pending work, running counter/aggregate and stopped stopped_probe.

Finish with ONE JSON object, no Markdown fences, containing initial and final
worker snapshots, runtime summary, new artifact metadata, rejection outcome and
observed assertions. Leave the application intact; the operator owns cleanup.
Do not claim success without actual MCP observations.
