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

## Acceptance status

| Criteria | Current evidence | Remaining |
| --- | --- | --- |
| A01 | Automated initialize/list/inspect against independent BEAM | Actual Codex connection transcript |
| A13 | Automated close/reinitialize and same OS runtime identity | Worker continuity in later features; actual Codex reconnect |
| A14 | Loopback binding, configuration/header checks, local smoke startup | Isolated local deployment and actual demonstration |
| A02 | Automated define over HTTP | Actual Codex creation transcript |
| A03 | Loaded exports/BEAM/hash and immutable registry, including HTTP define | Complete for compiler substrate |
| A10 | Failed definitions preserve existing artifacts and generation | Live-worker assertion when workers exist |
| A04 | Registry membership, DynamicSupervisor child and HTTP define/start/inspect/stop | Verified for startup substrate |
| A05 | HTTP worker state inspection | Invocation and actual Codex observations |
| A12 | Real host kill preserves HTTP, Manager and healthy peer | Automatic recovery bounds in worker-recovery |
| A06–A09, A11 | Foundations only | Owning effect/replacement tasks |

Invocation, automatic recovery, effects, full history/topology inspection, replacement, isolated container/release
setup and the actual Codex transcript remain pending. No worker/domain behavior is
seeded in the production kernel or claimed by this checkpoint.
