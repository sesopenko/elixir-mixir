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

## artifact-compiler

Verified 2026-11-10 on Elixir 1.18.3 / OTP 27. The checkpoint is the commit containing
its checked task document, with the normal pre-commit quality gate enabled.

- `mix test test/runtime/artifact_compiler_test.exs --warnings-as-errors`: 1 doctest,
  12 tests, zero failures. Covers exports/source/hash, inactive immutable artifacts,
  distinct revisions, replayed success/error, malformed/nested/dynamic/extra modules,
  missing callbacks including declared-behavior warnings, compiler/schema warnings,
  invalid/failed/timed-out schema, source boundaries, task heap flags and heap kill,
  helper-process joining, diagnostic UTF-8/size/count, response preflight, and EventLog
  eviction/cursor/metadata omission.
- `mix test test/mcp test/integration --warnings-as-errors`: 29 tests, zero failures.
  Exactly define/inspect are advertised. New real-HTTP cases verify definition,
  hash/revision/module identity, retained artifacts, replay/conflict/failures,
  reconnect with one compilation, shortened and real default compiler deadlines,
  and pre-reservation validation. Test-only stdin controls inspect registry/events;
  no production test tool exists.
- A separate BEAM with two slots verifies failed attempts exhaust capacity and
  remain consumed across application stop/start. Another case kills authoritative
  registry metadata and observes root/Manager shutdown without resetting authority.
- `mix check`: passed; 2 doctests, 67 tests, zero failures; strict Credo clean,
  Doctor 100% module/function documentation and typespec coverage, Dialyzer zero errors.
- `git diff --check`: passed; installed hook path `.githooks`.

The real five-second deadline exposed Hermes public-call timeout behavior; the
[transport refinement](../../prompts/phase01-transport-amendment-05.md) records its
reproduction, source evidence and thin POST correction. GET/DELETE retain the Hermes
Plug, and existing SSE/session/reconnect checks continue to pass. Contract examples,
source rewriting, failed-slot consumption and compile-time side-effect limitations
are documented in the [API](../../runtime-api.md). Generated source remains under
test/support or MCP submissions, never production lib/ domain modules.

## worker-start

Verified 2026-11-10 on Elixir 1.18.3 / OTP 27. The checked task document identifies
the verified commit; its normal pre-commit hook reruns the entire gate.

- `mix test test/runtime/worker_start_test.exs --warnings-as-errors`: 10 tests,
  zero failures. Covers Registry/DynamicSupervisor membership, init state, identity,
  duplicate IDs, missing references, error/raise/exit/timeout/heap/invalid-state paths,
  retained-definition capacity, stop/no-op stop/reinitialization, monotonic revisions,
  replay/conflicts, config/state byte and depth boundaries, actual host kill, healthy
  peer/Manager continuity and cleanup when the callback owner dies.
- `mix test test/mcp test/integration --warnings-as-errors`: 34 tests, zero failures.
  Discovery exposes exactly define/inspect/start/stop. The incremental HTTP journey
  verifies real define/start/inspect/stop/reinitialize, request replay, required
  schemas/unknown fields, no child after failed init, bounded init timeout, preserved
  worker PID/state after client close/reinitialize, actual Registry/supervisor
  membership through test-only controls and real host kill while HTTP/peer survive.
- `mix check`: passed; 2 doctests, 82 tests, zero failures; strict Credo clean,
  Doctor documentation/typespec coverage 100%, Dialyzer zero errors.
- `git diff --check`: passed; installed hook path `.githooks`.

A failing depth-boundary regression established that transport wrappers were
consuming the application depth allowance. Semantic config/state validators retain
the 16-level limit; argument/protocol envelopes now receive separate bounded nesting
allowance. Unit and actual HTTP tests accept the exact data depth and reject one over.
Another regression killed the caller during generated execution and proved tasks
could outlive it. The independent supervised kernel coordinator now owns deadline,
caller monitoring, cancellation and helper joining. Killing the callback owner leaves
no live generated callback/helper; client disconnect leaves its independent host alive.

Recovery is explicitly manual here: a killed host becomes a retained failed
definition, and only a fresh explicit start reinitializes it. No automatic restart
timers, event invocation or effects are claimed at this intermediate checkpoint.

## worker-invoke

Verified 2026-11-11 on Elixir 1.18.3 / OTP 27. The checked task's containing commit
is this checkpoint, created through the normal full-quality pre-commit hook.

- `mix test test/runtime/worker_invoke_test.exs --warnings-as-errors`: 9 tests,
  zero failures. Atomic counter replies/state/revisions, stable PID, serialized
  concurrency, exact replay/conflict, malformed/error/raise/exit/timeout/heap cases,
  non-JSON values, empty-effects restriction, late-result suppression, healthy peer,
  unknown/stopped targets, exact and over-limit payloads, and full wire preflight pass.
- `mix test test/mcp test/integration --warnings-as-errors`: 39 tests, zero failures.
  Discovery now advertises exactly define/inspect/invoke/start/stop. HTTP tests
  increment/inspect a counter, preserve active state/artifact after failed definitions,
  preserve state on invalid/timed-out callbacks and payload/wire rejection, and
  return matching bounded JSON text/structured envelopes.
- A test-only callback barrier confirms accepted work before physically closing
  the HTTP client's connection pool. Releasing that work, initializing a fresh
  client and replaying the same request ID returns reply 1/state_revision 2 and
  original generation 3, with exactly one increment and the original host PID.
  Barrier/controller code exists only in test/support, with no production test tool.
- `mix check`: passed; 2 doctests, 96 tests, zero failures; strict Credo clean,
  Doctor 100% documentation/typespec coverage, Dialyzer zero errors.
- `git diff --check`: passed; installed hook path `.githooks`.

Nonempty effects are deliberately INVALID_TRANSITION until event-effects, rather
than false success acknowledgements. Hosts accept transition messages only from
their owning Manager. Callback reasons are formatted and capped inside bounded
generated execution; state commits wait for all validation and response preflight.
Automatic worker recovery is still the following checkpoint.

## worker-recovery

Verified 2026-11-11; the checked task's containing commit is the recovery checkpoint.

- Focused recovery suite: 5 tests pass. Real host kills reset init state under the
  retained active artifact/config with a new PID/Registry mapping and increasing
  revisions. Deterministic clock/timer controls prove three attempts per rolling
  ten seconds, counting failed init, independent worker budgets, exact expiration,
  explicit start reset and stale DOWN/retry immunity after stop/new incarnation.
- Existing startup/invocation suites: 19 tests pass, including unchanged live hosts
  after callback failure/timeout and healthy peer continuity.
- Growing MCP/HTTP suites: 40 tests pass. A fresh client reconnects while recovery
  proceeds, observes a new PID/reset state and invokes the unchanged healthy peer;
  OS BEAM/health identity remains fixed. Failed reinitialization yields exactly
  three recorded attempts and retained failed status, then explicit start works.
  Stop during retry prevents resurrection after the deadline; no production test
  control is exposed.
- Full `mix check`: 2 doctests and 102 tests, zero failures; strict Credo clean,
  Doctor documentation/typespec coverage 100%, Dialyzer zero errors.
- `git diff --check` passes; `.githooks` remains enabled for the checkpoint commit.

## event-effects

Verified 2026-11-11; the checked task's containing commit is the effects checkpoint.

- Focused effects suite: 13 tests pass, covering generated counter/aggregator exact
  totals, request replay and deterministic accepted IDs, delayed events, bounded
  structured Logger/history, invalid batch atomicity, reservation cleanup on wire
  failure/owner death/expiry, exact default 256-slot capacity, all effect limits,
  sixteen-hop termination, missing/stopped destinations, logical routing after
  target recovery, source stop cancellation and finite unclaimed delivery deadlines.
- Growing MCP/HTTP suites: 44 tests pass. Define/start/invoke two workers through
  MCP and inspect exact count/total; delayed delivery and correlated log history;
  invalid batches, capacity/hop exhaustion and cancelled source timers; missing/
  stopped target failures and delayed routing to a new target PID after recovery.
- Physically close HTTP during accepted controlled work, release the callback,
  initialize a fresh client and replay the same source request twice: the source
  increments once, aggregator receives once, original accepted IDs replay, source
  PID and independent BEAM stay alive. Test controls remain outside production lib/.
- Full `mix check`: 2 doctests and 120 tests pass, strict Credo clean, Doctor 100%
  documentation/typespec coverage, Dialyzer zero errors. A deterministic regression
  also proves acknowledged stop releases Registry routing despite delayed death
  cleanup, with source timers cancelled before stop completion.
- `git diff --check`, local documentation links and installed `.githooks` verified.

Dispatch remains in-memory and best effort across a host-commit/publication crash
gap; no durable outbox or exactly-once crash guarantee is claimed. Full public event
history/topology/pagination belongs to runtime-inspection, immediately next.

## runtime-inspection

Verified 2026-11-11; the checked task's containing commit is the inspection checkpoint.

- Focused inspection suite: 11 tests pass. Real host state/PID/revisions and cached
  artifact metadata agree; instrumented generated callbacks prove neither read API
  executes generated code. Running/stopped/unavailable/exhausted states, pending
  timers and successful directed relationships are explicit. Independent sorted
  worker/edge pagination has no duplication; stale runtime/generation/detail
  cursors fail with a restart hint.
- Maximum 32-worker escaped Unicode state pages fit duplicated MCP JSON-RPC encoding
  with visible omissions. Large escaped event pages shrink safely while preserving
  exclusive sequence progression. Ring eviction, metadata truncation, filtering,
  UTC timestamps, monotonic sequences and every Phase 1 lifecycle append shape pass.
- MCP/HTTP suite: 48 tests pass, exactly six tools. Public HTTP inspection/history
  verifies relationships, timers, correlations/failure codes, Registry identity,
  artifacts, stopped workers, history across fresh clients, eviction/filter cursors,
  stale cursor rejection and maximum worker-state response size <=65,536 bytes.
- Full `mix check`: 2 doctests and 135 tests pass; strict Credo clean, Doctor 100%
  documentation/typespec coverage, Dialyzer zero errors. Local links, diff whitespace
  and `.githooks` verified before the checkpoint commit.

History stays in memory, and read omissions do not alter committed state or stored
events. The minimum 1 KiB response ceiling can yield a bounded error when a minimal
snapshot cannot fit. Replacement and the separate actual Codex demonstration remain.

## live-replacement

Verified 2026-11-11; the checked task's containing commit is the replacement checkpoint.

- Focused replacement suite: 9 tests pass. Same-schema activation preserves exact
  PID/state/state_revision and bypasses migrate; changed schema receives validated
  context and migrates explicitly, including reverse migration to an old artifact.
  Immutable artifacts remain unchanged. Ten failure modes preserve all old fields
  and behavior; replay/conflict, competing revisions, response preflight, true queued
  event ordering and actual host death during staging are verified.
- Growing MCP/HTTP suite: 54 tests pass with exactly seven strict tool schemas.
  Two successive compatible replacements, explicit/reverse schema migration, active
  worker survival after invalid definitions, ten migration failures, revision races,
  request replay/conflict, wire envelopes and endpoint continuity pass.
- A physical HTTP disconnect during accepted controlled migration is followed by
  fresh initialize and repeated identical request: one replacement, original result,
  same PID, active candidate and migrated state. Actual host death instead returns
  cached CALLBACK_FAILED and restarts the retained old artifact with a new PID.
- Full HTTP graph evolution: counter/aggregator total 3, same-PID counter replacement
  retaining prior state, next input 4 emits 8, aggregate reaches total 11/count 2,
  both original host PIDs and observed topology remain intact.
- Full `mix check`: 2 doctests and 150 tests pass; strict Credo clean, Doctor 100%
  documentation/typespec coverage, Dialyzer zero errors. All seven JSON argument
  examples decode, Generated template syntax parses, local links/diff checks pass,
  and the normal `.githooks` checkpoint gate remains enabled.

The automated runtime substrate is complete. The actual Codex connection/evolution/
reconnect demonstration and isolated release deployment remain unverified until
codex-demo; automated HTTP tests are not substitutes for that transcript.

## codex-demo

Verified 2026-11-11. The commit containing the checked final task is the tenth
checkpoint. Evidence is distinct from automated HTTP tests:

- [Session metadata](evidence/codex-sessions.json),
  [session 1 actual MCP calls](evidence/codex-session01.jsonl),
  [session 2 fresh-client MCP calls](evidence/codex-session02.jsonl).
- [First checkpoint](evidence/codex-session01-final.json),
  [fresh checkpoint](evidence/codex-session02-final.json), and
  [runtime/container manifest](evidence/runtime-manifest.json).
- [Exact experiment/prompts](../../../examples/phase_1_demo.md) and
  [independent observation verifier](../../../scripts/verify-phase01-demo.py).

Runtime/client versions: Codex CLI 0.167.1; Elixir 1.18.3; OTP 27.3.4/ERTS 15.2.7;
application 0.1.0; Docker 26.1.5+dfsg1; Linux/amd64. The official base image is pinned
at multi-platform digest
`sha256:fc227cb4b0c568a1f7cf6a8e40269185248cd29204c0d4e95cdefe31f5d1a873`.
Built release image:
`sha256:8cfeb62aa2885ea16b7e76d7e429b75978511948e92ce9b2bfa33782fcdebf6c`.

Docker build and the exact documented constrained startup passed. Actual inspect
and process checks proved nonroot UID/GID 1000, read-only root, /tmp tmpfs, no bind
mounts or Docker socket, all capabilities dropped, no-new-privileges, memory
536870912, NanoCpus 1000000000, PidsLimit 128, distribution disabled and only
127.0.0.1:4100 listening. A separate identical constrained container with network
none returned GET /health HTTP 200 ready, proving startup needs no dependency
network downloads. Both smoke-test containers and the actual demo container were
removed; no unrelated containers were touched.

Two packaging failures were investigated at their cause. The slim builder lacked
a CA trust bundle; installing ca-certificates permits verified dependency downloads.
A bare VM under 512 MiB was OOM-killed: Docker supplied a 1,073,741,816-FD limit,
OTP selected 134,217,727 ports and allocated about 2 GiB of system memory. A +Q 65536
release/build setting fixes startup without raising the required memory/PID limits.
Thread caps keep VM startup inside 128 PIDs. Release startup invokes no Mix, writes
temporary files under /tmp and includes only production kernel/runtime code.

The final contract audit also found that failed definitions could change retained
artifact/config through start without an explicit stop. A failing recovery test
proved the mismatch against the plan. The startup guard now returns INVALID_ARGUMENT
with a stop-first hint, preserving failed status/revisions/budget; same-definition
recovery remains available, and stop then start allows changed identity/config.
Focused unit and real-HTTP regressions pass. The final release and actual Codex
sessions below include this correction.

Actual Codex session 1 used all seven tools in 51 calls. Initial inspection showed
generation zero and no workers. Codex created and evolved the application solely
through runtime_define/start/invoke/replace; no shell/file/direct-HTTP domain
construction occurred. Intentional runtime errors appear as failed CLI tool items
with valid bounded structured results, not transport failures.

| Observed stage | Counter | Aggregate events | Aggregate total |
| --- | --- | --- | --- |
| v1 increment | 1 | — | — |
| v2 same-schema replacement and two increments | 3 | 2 | 5 |
| v3 positive amount 4 | 7 | 3 | 12 |
| Rejected amount 0 and -1 | 7 | 3 | 12 |
| v4 explicit schema-2 migration | nested value 7 | 3 | 12 |
| Failed define/migration/stale revision | nested value 7 | 3 | 12 |
| Fresh Codex session 2 | same nested value 7 | 3 | 12 |

Counter PID stayed `#PID<0.1559.0>`; aggregate PID stayed `#PID<0.1581.0>`.
Counter ended artifact revision 4, worker_revision 4, state_revision 6, schema 2;
aggregate stayed artifact/worker revision 1, state_revision 4. A separate probe
emitted a structured log and delayed self-event, observed seen=1, then stopped.
Final generation was 23 with pending/reserved/timers all zero. Failed operations
were two CALLBACK_FAILED invalid amounts, COMPILE_FAILED source, MIGRATION_FAILED
candidate and REVISION_CONFLICT stale revision; actual snapshots after each retained
active PID/artifact/state/worker and state revisions.

Session 1 process exited 0. A completely new Codex process/thread made 8 read-only
MCP calls and exited 0, observing exact counter/aggregate snapshots and generation
23. Container ID 6be756fce623, host BEAM PID 232827 and StartedAt
2026-11-11T08:51:26.544177969Z remained unchanged, restart count zero, throughout both
clients. The manifest records complete identity before/after, followed by explicit
cleanup. Reconnect used no mutation or replayed fixture construction.

Artifact SHA-256 values were independently recomputed from actual MCP source
arguments and matched runtime returns. Full artifact IDs and original source/metadata
references are in the sanitized transcript and checkpoints:

| Role | Slot | Logical revision | Schema | Source SHA-256 |
| --- | --- | --- | --- | --- |
| counter v1 | 1 | 1 | 1 | 20a93958e80435860007e7e669ab66fef3aeb3fbc8ce2ff26967f9ea03cc81ad |
| aggregate | 2 | 1 | 1 | c9846906c6f33152023a404a4b539591e498affc99b0efc54380a4c33761fae6 |
| counter v2 | 3 | 2 | 1 | 987d0e6c88d3f69d3f1d1b620fe56e2a0bcd43ed4b1a7a84be420b945b356353 |
| counter v3 | 4 | 3 | 1 | 5ce5d231a5be0f6936624e456aa36c3549265b2f9fc63c301831c673ea117be3 |
| counter v4 | 5 | 4 | 2 | d71bb2c7c170a3e923301384e4aa53e611b1c928224b10192f35a959953d5783 |
| rejected migration candidate | 7 | 5 | 3 | 5bd8850af024f34b88bd4bc73c917e8705b8a348911ca2f33025523e77110873 |
| probe | 8 | 1 | 1 | 21227456cebaf383ea71072ab6773a3b3340bf7126667bfe754a0c12968f6007 |

Slot 6 was consumed by deliberate invalid source and never reused. Sanitization
retains all actual MCP arguments and structured results; duplicate text was checked
equal then omitted. Auth/cookies, unrelated settings, agent narration and stderr
are excluded. Credential-pattern and JSON checks pass.

Final commands: `python3 scripts/verify-phase01-demo.py` passes all recorded-call,
arithmetic, failure, source-hash, continuity and isolation/cleanup assertions.
`mix test test/integration/phase01_runtime_test.exs --warnings-as-errors` passes
28 tests; `mix check` passes 2 doctests and 151 tests, strict Credo, Doctor 100%
documentation/typespec coverage and Dialyzer. Local Markdown links, JSON examples,
Generated syntax, shell syntax and `git diff --check` pass; `.githooks` remains
active for the final checkpoint. The local elixir-mixir MCP registration was added
and listed successfully; its runtime container is intentionally cleaned up.

## Acceptance status

| Criterion | Authoritative evidence | Status |
| --- | --- | --- |
| A01 | Actual initial Codex MCP inspection, then a second fresh CLI process | Verified |
| A02 | Seven successful actual Codex defines; original source and recomputed hashes | Verified |
| A03 | Actual compile outcomes plus loaded-export/BEAM/immutable-registry tests | Verified |
| A04 | Actual starts and logical IDs/PIDs; Registry/DynamicSupervisor unit/HTTP checks | Verified |
| A05 | Actual counter invocation/state observations, backed by bounded inspection tests | Verified |
| A06 | Actual counter/aggregate creation, emitted arithmetic and observed topology | Verified |
| A07 | Three actual replacements with changed callback behavior/active artifacts | Verified |
| A08 | Same actual counter PID across replacements; unit monitor observes no DOWN | Verified |
| A09 | Actual same-schema retention and explicit v4 schema migration; reverse-migration tests | Verified |
| A10 | Actual rejected source followed by unchanged active snapshot and compiler/HTTP tests | Verified |
| A11 | Actual deliberate migration failure preserves all active fields; ten automated modes | Verified |
| A12 | Automated actual host kills, peer/MCP survival and bounded recovery; demo callback rejection isolation | Verified |
| A13 | Actual client exit/new thread with exact live state/PID/artifact/generation equality; HTTP accepted-work replay tests | Verified |
| A14 | Local constrained container, loopback listener, actual local MCP endpoint and no host mounts | Verified |

Phase 1 is complete. State/artifacts/history/effects remain in memory, host crashes
rerun init, and kernel/BEAM restart loses the application. Generated code retains
BEAM privileges; host networking permits network access. Strong hostile-code
isolation, durable recovery/outbox, remote deployment and an autonomous controller
remain outside Phase 1.
