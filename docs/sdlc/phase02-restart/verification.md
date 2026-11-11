# Phase 2 implementation verification

Status: store-foundation through recovery-quarantine verified; remaining checkpoints and application recovery
evidence are pending. Planning results belong in [planning-verification](planning-verification.md).
Governing [plan](plan.md); [assignment snapshot](../../prompts/phase02-restart-planning.md).

For each checkpoint record date, baseline and resulting commit, actual commands,
test counts/results, focused failure injections and HTTP increments, full quality
gate and hook results, observed durable/live state, and artifact locations. Never
record a planned result as observed. Update the owning task's checklist only when
the verified commit is created. Keep logs bounded and free of secrets.

Automated tests and actual Codex evidence are separate. For restart cases record
the owned BEAM/container kill mechanism, retained-directory identity, before/after
boot IDs, no-client recovery interval and state/revision/effect assertions. A fresh
printed PID string alone is not proof of reconstruction.

## store-foundation

Verified 2026-11-11 against baseline `5c7f8ea` (this checkpoint commit).
Implementation assignment: [snapshot](../../prompts/phase02-restart-implementation.md).

- `python3 scripts/verify-phase01-demo.py`: verified 59 actual Phase 1 Codex calls,
  confirming the committed prerequisite evidence before selecting this task.
- Focused storage/config/restart command: 8 tests passed. Coverage includes atomic
  paired writes and generation, conflict/canceled writes, invalid JSON and size/
  table limits, changed-record dependencies, unknown format preservation,
  invalid directory, duplicate owner, normal close/reopen, significant store loss,
  readiness-timeout child cleanup and real HTTP inspect/rejected define.
- `mix test test/mcp test/integration --warnings-as-errors`: 57 tests passed.
- `mix check`: 159 tests and 2 doctests passed, no warnings, strict Credo clean,
  Doctor documentation/typespec coverage 100%, Dialyzer zero errors/skips.
- `python3 docs/sdlc/phase02-restart/verify-plan.py` and `git diff --check`: passed;
  installed hook path is `.githooks`. Commit runs the same full gate.

`test/integration/phase02_store_test.exs` owns a unique `/tmp/mixir-restart-*`
directory, commits two audit records at generation 1, sends `kill -KILL` to the
reported BEAM OS PID, waits for exit status 137, then starts another independent
BEAM against that exact directory without an LLM. It verifies a different OS PID
and exact equality of metadata (including lineage/generation) and both records.
The fixture clears inherited storage/port settings. Production Store owns all
backend access, synchronous writes and compaction; test corruption setup alone
uses CubDB directly. A normal-close test caught a leaked backend process; explicit
backend shutdown now allows immediate same-directory reopen.

This proves store durability only. All durable application mutations fail with
`DURABILITY_UNAVAILABLE` before compiler slot use (zero attempts/artifacts);
memory behavior remains covered by the full prior suite. Generated definitions,
worker state, outbox recovery and the actual Phase 2 client demo remain pending.
README, CONTRIBUTING and runtime API describe this boundary.

## staged-hosts

Verified 2026-11-11, prerequisite `b9dea1a` committed and pushed before work.
This checkpoint preserves memory behavior and keeps durable mutations disabled.

- `mix test test/runtime/staged_hosts_test.exs test/runtime/worker_invoke_test.exs test/runtime/replacement_test.exs --warnings-as-errors`: 25 passed.
- `mix test test/integration/phase02_staging_test.exs --warnings-as-errors`: 1 passed.
- `mix test test/mcp test/integration --warnings-as-errors`: 58 passed.
- Full `mix check`: 168 tests, 2 doctests; strict Credo clean, Doctor 100%,
  Dialyzer zero errors/skips. Plan verifier and diff checks passed. The installed
  `.githooks` hook reruns the full gate for the checkpoint commit.

Prepared invoke/replacement leaves committed snapshots unchanged; candidates have
no Registry route. Tests cover abort and real candidate/dispatcher-lease expiry,
one candidate per host, caller ownership, stale revision/incarnation/ticket
rejection, repeated publication without repeating generated callbacks, same-host
replacement, owner/host death and capacity release. Publication pins the effect
reservation before exposing state so a lease cannot expire between publication
and Manager batch commit. A route-collision regression first demonstrated a
Manager crash; failed registration now closes the candidate and preserves the
original route plus both Managers.

The independent HTTP fixture pauses the coordinator at its injected trusted
`before_publish` hook. Direct host snapshots show the original source and peer
state, while the dispatcher shows one reserved effect and zero pending work.
Physical client disconnect leaves the accepted operation running; after release,
a fresh session replays exactly one committed source transition and the peer
receives exactly one effect (total 7, count 1). Existing host-kill/reconnect tests
also pass with explicit `{manager_pid, host_pid}` Registry values. No application
restart recovery is claimed at this checkpoint.

## durable-artifacts

Verified 2026-11-11 after prerequisite `fa5b364` was committed and pushed.

- `mix test test/runtime/durable_artifacts_test.exs test/runtime/durable_requests_test.exs --warnings-as-errors`: 8 passed.
- `mix test test/integration/phase02_artifacts_test.exs --warnings-as-errors`: 6 passed.
- `mix test test/mcp test/integration --warnings-as-errors`: 64 passed.
- Full `mix check`: 182 tests, 2 doctests; no warnings, strict Credo clean,
  Doctor 100% module/function/spec coverage, Dialyzer zero errors/skips.
- Plan verifier and diff checks passed; `.githooks` remains installed and the
  checkpoint commit reruns the full gate.

Actual independent BEAM SIGKILL tests retain one unique temporary directory per
scenario. Two HTTP definitions recover source/hash/ID/revisions without a client;
boot identity changes, lineage/generation and stored records stay equal, the next
logical revision is 3, and restored artifact capacity rejects a fourth definition.
A restored-module unit assertion executes init successfully. A random original
module diagnostic stays a binary and is absent from the atom table after recovery.

Named test-only controls pause `after_admission`, `after_prepare` and `after_commit`.
The first two leave zero durable/registered artifacts and replay
`OPERATION_INTERRUPTED` after SIGKILL. The last retains one artifact and the exact
completed result despite zero registry entries at the interruption. Its historical
module string differs from the current recompiled slot, proving replay does not
pretend to return a current handle. Retained compile failures and request conflicts
also replay across restart without rerunning compilation.

A controlled boot compilation shows health 503 and `RUNTIME_RECOVERING` reads and
mutations before admission. After release, the valid artifact recovers and a
separately corrupted inactive hash remains on disk with a bounded degraded-recovery
diagnostic. Parseable revision high-water survives quarantine. Retained or remaining
BEAM-lifetime capacity fails readiness before partial reconstruction. The initial
readiness fixture was rejected for a compile-time warning; asserting definition
acceptance exposed that cause, and the warning-free compile-time fixture now
exercises the intended recovery boundary.

UTC request-record tests cover serialized exact outcomes, capacity, distinct random
operation IDs on expired reuse, pending non-expiry and conservative backward-clock
retention. An actual SIGKILL/downtime case expires the retained request and creates
a distinct artifact at revision 2. Source definition and replacement wire-preflight
tests now use maximum valid request/worker identifiers: shorter opaque artifact
IDs legitimately reduced their old boundary payload sizes.

A pre-push response-budget regression reproduced an oversized retained compilation
error with a 1,024-byte wire limit. Error outcomes now pass the full response
preflight before their durable commit; the stored/replayed result becomes the
bounded `LIMIT_EXCEEDED` error without advancing generation. The final full gate
includes this regression.

README, contributor and API guidance describe durable opt-in, exclusive volumes,
source-only recovery, readiness, bounded replay, historical diagnostics and repeated
compile-time IO. Worker mutations remain `DURABILITY_UNAVAILABLE`; lifecycle,
committed worker state, effects and the actual client demo are still pending.

## durable-lifecycle

Verified 2026-11-11 after inspecting prerequisite `12e4c30`, the governing contracts,
committed evidence and origin. This checkpoint meets milestone 5's automated exit.

- `mix test test/runtime/durable_lifecycle_test.exs --warnings-as-errors`: 6 passed.
- `mix test test/integration/phase02_lifecycle_test.exs --warnings-as-errors`: 11 passed.
- `mix test test/mcp test/integration --warnings-as-errors`: 75 passed.
- Full `mix check`: 199 tests, 2 doctests; warnings-as-errors clean, strict Credo
  clean, Doctor 100%, Dialyzer zero errors/skips.
- Plan verifier, diff checks and installed `.githooks` path verified. The checkpoint
  commit runs the full quality gate again. README/contributor/API guidance updated
  together; existing client commands and Claude Code qualification are preserved.

An independent BEAM starts two workers linked by config and a third subsequently
stopped worker. Init writes a marker and raises if called again; migration raises.
After actual SIGKILL, the same directory reopens with no MCP session. The running
hosts are newly supervised and routed, stopped routing stays absent, stored worker/
state/request records and generation stay equal, logical IDs/config/artifacts/
revisions/initial state match, and marker contents prove init was not repeated.
A new OS PID and boot ID with the same lineage prove a new process lifetime without
assuming printed host PID inequality. Explicit start after stop initializes from
new config and advances worker/state revisions. Invocation remains gated.

Six SIGKILL scenarios pause start and stop after admission, after preparation and
after durable commit. Starts remain unrouted at all barriers. Before commit there
is no partial worker/state record set; boot replays `OPERATION_INTERRUPTED`.
After commit, boot honors the entire saved desired definition and replays the exact
historical outcome despite interruption before routing/termination/response.
Stopped records stay stopped and no-op stop preserves generation and revisions.

Focused failures cover init error/timeout/invalid shape/non-JSON state, duplicate
start, response-size rejection with synchronous candidate cleanup, maximum-depth
state inside a checkpoint envelope, host death restoration, and stale DOWN/retry
tokens. Restoring a host preserves state revision; crash/retry lifecycle revisions
and UTC retry timestamps commit before publication. Three injected restoration
failures persist exhaustion; a real VM restart keeps the definition failed.
Manual start resets the budget, and edits to a failed definition require stop.

Offline corruption tests retain a mismatched schema or missing artifact reference.
Only the affected worker is quarantined; a healthy peer restores. A migration
side-effect marker stays absent, proving mismatched schema does not run migration.
Broken references are explicitly unavailable in inspection, rather than inventing
an implementation version. The original bad records remain until explicit repair;
stop can repair a broken reference and start a valid definition.

A held compilation then held host-construction boundary verifies health 503 through
reconstruction. The latter first reproduced a queued read instead of prompt
`RUNTIME_RECOVERING`; public default-runtime calls now check the readiness table
before entering Manager's mailbox. Held reads return promptly, mutations never
enter the durable ledger, and health 200 appears only after healthy routes exist.
The initial new HTTP helper also exposed duplicate fixed-profile ownership; closing
the health-probe pool before opening the MCP client fixed that fixture cause.

Durable request coordination is shared by definitions and lifecycle operations:
prepare and response preflight, one atomic record/outcome/audit commit, then live
publication. Existing memory behavior and all earlier artifact interruption tests
remain green. Worker event transitions, replacement, outbox/delivery, deployment,
actual Codex restart demonstration and final evidence review remain pending.

## durable-transitions

Verified 2026-11-11 after prerequisite `6d60201` was committed, verified and pushed.

- `mix test test/runtime/durable_transitions_test.exs test/runtime/worker_recovery_test.exs --warnings-as-errors`: 11 passed.
- `mix test test/integration/phase02_transitions_test.exs --warnings-as-errors`: 8 passed.
- `mix test test/mcp test/integration --warnings-as-errors`: 83 passed.
- Full `mix check`: 212 tests, 2 doctests; warnings-as-errors, strict Credo and
  Doctor 100% passed; Dialyzer zero errors/skips. Plan/diff checks passed and
  `.githooks` remains installed for the checkpoint's full pre-commit gate.

Four independent-BEAM cases SIGKILL before commit, after commit, before publication
and before response, retaining the same owned temporary directory. Stored state
and completed outcome are one transaction: an initial count 2 remains 2 with an
interrupted retained request before commit, or becomes 7 with the exact reply,
state revision 3 and saved generation afterward. Direct host snapshots stay at 2
until publication; the before-response case sees 7. After a fresh VM, stored worker/
state records match and replay does not increment again. A new event continues
from the recovered value.

The test-only Store protocol proxy passes admission to the real Store, then either
raises before the final write or commits it and deliberately never replies. The
latter reaches the actual Store API timeout. Both close Manager and readiness;
after VM restart, the former retains old state and `OPERATION_INTERRUPTED`, while
the latter restores state 9 and a successful exact result at generation 3. No
assumed rollback replaces the disk outcome. A separate post-commit host death
forces publication failure and kernel shutdown; restart preserves state 13 and
the unchanged successful request record rather than recording `CALLBACK_FAILED`.
Initial cleanup tried to DELETE a session on the deliberately stopped listener;
local disconnect fixed that test-fixture cause without changing runtime behavior.

Unit and HTTP failure paths cover callback error/raise/exit/deadline, invalid and
non-JSON/oversized state/reply, full wire preflight, request conflict and replay,
peer health and latest-state host restoration without a new state revision.
Valid nonempty emit/schedule/log batches fail `DURABILITY_UNAVAILABLE` before
reservation, dispatch or state commit; memory effects stay covered by prior tests.
An initial host-recovery wait used two snapshots across a status change; using one
atomic observation fixed that measurement race. The healthy restored worker then
continues from count 11 to 12.

The Manager reads a matching owner-bound prepared checkpoint, commits worker/state/
request/audit together, then publishes the same host ticket. Checkpoint and request
operation IDs agree. Host recovery caches only the latest committed data after
publication. README, contributor and API guidance describe effect-free durable
invocation, uncertain responses, bounded retention and the limits on direct callback
IO. Replacement and durable effect acceptance/delivery remain pending.

## durable-replacement

Verified 2026-11-11 after prerequisite `a0114e0` was committed and pushed.
Milestone 6's automated exit condition is met by this checkpoint.

- `mix test test/runtime/durable_replacement_test.exs --warnings-as-errors`: 4 passed.
- `mix test test/integration/phase02_replacement_test.exs --warnings-as-errors`: 7 passed.
- `mix test test/mcp test/integration --warnings-as-errors`: 90 passed.
- Full `mix check`: 223 tests, 2 doctests; warnings-as-errors clean, strict Credo
  clean, Doctor 100%, Dialyzer zero errors/skips. Plan verifier and diff checks pass;
  the installed `.githooks` hook reruns the full gate before commit.

A real HTTP counter invokes v1 to 3, preserves its live PID/state on compatible v2
replacement, invokes v2 to 7, migrates once to schema 2 in v3, and invokes v3 to 17.
The migration writes a marker and raises on its second execution. After SIGKILL and
same-directory boot without a client, selected artifact/schema/state/revisions and
all stored records match. Historical replacement replay is exact and a new v3
invocation reaches 27, proving the recovered selection is executable. The marker
stays unchanged and the worker runs, proving boot did not repeat migration. PID
continuity is asserted only inside an uninterrupted VM; a new OS PID proves reboot.

Five actual SIGKILL cases pause after migration/preparation, before commit, after
commit, before publication and before response. All durable worker/state records
contain either old selection/schema/count 5 or new selection/schema/value 5. Live
selection stays old until publication. After restart the old pair returns
`OPERATION_INTERRUPTED`, or the new pair replays the exact completed result. A
fresh invocation continues to 6 under v1 or 15 under v3. The migration marker can
exist even on an uncommitted interruption, demonstrating the documented direct-IO
boundary rather than assuming kernel rollback can undo it.

Focused failures include invalid/missing definitions and callbacks, stale worker
revision, error/raise/exit/deadline/late/malformed/non-JSON/oversized/heap migrations,
and full response preflight. They preserve prior selection/state/revisions and
retain exact failure replay. A history regression first showed a generic
`replacement_failed` event for `MIGRATION_FAILED`; the shared coordinator now emits
the documented `migration_failed` event, with focused coverage. Initial fixture
invocations reused definition request IDs and correctly hit conflict; distinct
mutation IDs fixed the fixture.

Replacement reuses the established owner-bound prepared checkpoint and atomic
outcome path, updating selected artifact and state in one Store transaction before
same-host publication. Matching schema preserves state revision; explicit migration
advances it. Pending records are untouched. README, contributor and API guidance
now cover durable replacement, recovered selection, current versus historical PID
diagnostics, failure semantics and the migration IO limitation. Nonempty durable
effects remain disabled until the outbox/delivery tasks.

## durable-outbox

Verified 2026-11-11 after prerequisite `461350f` was committed and pushed.

- `mix test test/runtime/durable_outbox_test.exs --warnings-as-errors`: 6 passed.
- `mix test test/integration/phase02_outbox_test.exs --warnings-as-errors`: 6 passed.
- `mix test test/mcp test/integration --warnings-as-errors`: 96 passed.
- Full `mix check`: 235 tests, 2 doctests; no warnings, strict Credo clean,
  Doctor 100% documentation/typespec coverage, Dialyzer zero errors/skips.
- Plan verifier, public-document local file links and diff checks pass. The
  installed `.githooks` hook reruns the full gate for the checkpoint commit.

An HTTP invocation emits one peer event, one schedule and one log intent. Actual
SIGKILL at before-commit, after-commit and before-response barriers reopens the
same owned temporary directory without a client. State and all three intents
survive together or neither does. Exact effect records, IDs and absolute UTC
deadlines remain unchanged after reopening. Retained replay never adds work;
uncommitted requests replay `OPERATION_INTERRUPTED`. Peer state stays zero and
no `effect_log` event appears before commit or after recovery. Reconstructed
pending/timer counts match disk, reservations are zero, and public inspection
reports paused dispatch. Three more SIGKILL cases surround source stop: retained
running source plus three effects, or stopped source plus zero effects, never a
partially canceled batch.

Focused tests verify identity from the unique persisted operation ID plus path,
separate caller correlation, exact replay, distinct identities after expired
caller-key reuse, JSON-only records, fixed UTC deadlines, whole-batch invalid/full
queue rejection, invalid-state and response-budget rollback with zero leaked
reservations, host-crash/replacement preservation and atomic stop cancellation.
A lowered boot capacity fails recovery before recompilation without rewriting any
retained record. Existing staged-host owner/host-death cleanup and memory effect
coverage remain green. One initial test used `expected_worker_revision` instead
of the supported `expected_revision`; correcting the fixture made its preservation
assertion exercise replacement successfully.

The coordinator serializes the owner-bound reservation and commits its complete
batch with origin state, revisions, exact outcome and audit. Publication releases
the transient reservation and reconstructs retained queue accounting; boot does
the same reconstruction before readiness. No durable effect dispatch occurs in
this checkpoint. README, contributor and API guidance state that boundary and
cover fixed deadlines, operation identities, capacity and stop semantics. Delivery
and quarantine reconciliation remain the next tasks.

## durable-delivery

Verified 2026-11-11 after prerequisite `1f43b8c` was committed and pushed.

- `mix test test/runtime/durable_delivery_test.exs test/runtime/durable_timers_test.exs --warnings-as-errors`: 10 passed.
- `mix test test/integration/phase02_delivery_test.exs --warnings-as-errors`: 7 passed.
- `mix test test/mcp test/integration --warnings-as-errors`: 103 passed.
- Full `mix check`: 252 tests, 2 doctests; warnings-as-errors clean, strict Credo
  clean, Doctor 100% documentation/typespec coverage, Dialyzer zero errors/skips.
- Plan verifier, public-document file links and diff checks pass; `.githooks`
  repeats the full quality gate before recording this checkpoint.

Real HTTP source/peer/leaf workers produce a two-step effect chain. Actual SIGKILL
before target commit, after commit and after host publication reopens the same
owned directory without an LLM. Before commit disk has the parent and old peer
state; after commit it has one child, new peer state and one topology increment.
Live state stays old until publication. Recovery produces peer total 5 and leaf
total 9 exactly once, with one edge increment per step and no pending records.
A forced duplicate volatile claim for the consumed parent after restart and expired
external retention leaves the entire store unchanged. A fresh invocation continues
the peer total to 7. Internal delivery creates no client-ledger entry; a full
client ledger also cannot block durable consumption.

A separate SIGKILL case retains an overdue schedule and a 60-second future schedule.
Boot restores healthy routes and delivers the overdue amount 3 without a client;
the future record, ID and UTC deadline stay exact. A controlled forward UTC change
then delivers amount 7, reaching total 10 with an empty queue. Controlled unit
clocks prove zero delay, backward rearming, forward eligibility and ordered
`(due_at, effect_id)` consumption without mutation on an early wakeup. An actually
changed source implementation preserves existing schedules; the first delivers its
old payload and explicit stop cancels the later one despite a stale wakeup.

Log interruption pauses after actual Logger execution and correlated `effect_log`
recording while its intent remains on disk. SIGKILL/recovery executes that same ID
again and commits completion. Source state remains committed once and request
replay emits no further output, demonstrating the external at-least-once boundary.
Raised precommit Store failure and a timeout after successful commit both close
authority; recovery reads actual disk and reaches target total 4 once, with one
edge increment. The timeout fixture observes committed state and deletion before
waiting for the real five-second Store call timeout.

Focused failures cover unknown/stopped/quarantined targets, callback error/invalid
state/timeout, restarting and BUSY targets with 100 ms transient retries, hop
exhaustion, full queue with parent-slot reclamation, and atomic failure when a child
batch exceeds even reclaimed capacity. A controlled queued-wakeup/host-DOWN race
first proved that classifying a dead host as permanent discarded work. Delivery
now reclassifies preparation errors from a dead host as transient, preserving its
intent until restoration. The regression verifies one subsequent target transition.

The full suite exposed default-Manager generation pollution from shared compiled
fixtures. Both delivery and prior outbox fixtures now compile through private
Managers; bootstrap plus delivery tests pass under the failing seed. Compiled test
support uses ExUnit callbacks, so Dialyzer's PLT includes `:ex_unit` for analysis;
there is no new production runtime dependency. Alias ordering and validator
complexity findings were fixed structurally without changing thresholds. A new
replacement fixture initially had an unused event argument; warning-free generated
source now exercises the intended replacement and cancellation path.

Manager owns one volatile OTP wakeup rebuilt from committed deadlines. It rechecks
pending existence and UTC eligibility, prepares outside Store, then atomically
consumes the parent with target state, children, bounded outcome audit and topology.
Reservations reclaim the consumed parent's slot; internal deduplication never
uses expiring client outcomes. Logs commit intent before output and completion
afterward. Queue completion advances generation once; retries and timer claims do
not. README, contributor and API guidance explain resumed work, retry/terminal
behavior, wall-clock semantics, external IO limits and a retained-store restart
example. The earlier outbox tests explicitly hold the trusted injected timer to
continue testing acceptance/cancellation independently of delivery.

A10/A11 and the delivery portion of A08/A14 now have automated evidence. Full
Phase 2 completion remains pending quarantine, release storage and the actual
Codex demonstration and evidence review.

## recovery-quarantine

Verified 2026-11-11 after prerequisite `180d853` was committed and pushed.

- `mix test test/runtime/recovery_quarantine_test.exs --warnings-as-errors`: 8 passed.
- `mix test test/integration/phase02_quarantine_test.exs --warnings-as-errors`: 15 passed.
- `mix test test/mcp test/integration --warnings-as-errors`: 118 passed.
- Full `mix check`: 276 tests, 2 doctests; no warnings, strict Credo clean,
  Doctor 100% documentation/typespec coverage, Dialyzer zero errors/skips.
- Plan verifier, public-document file links and diff checks pass. `.githooks`
  remains installed and repeats the entire quality gate before this checkpoint.

Ten real HTTP cases create a healthy/broken worker pair, accumulate totals 4/9,
SIGKILL the owned BEAM, damage one source/hash/contract/state/schema/reference,
inactive artifact, intent payload, intent metadata or worker metadata record in
the closed directory, then reopen it. Healthy state restores and another event
reaches total 6. Damaged records remain exact through recovery; unavailable workers
have no route and inspection reports degraded recovery. Invalid intent records
remain retained and counted while being excluded from dispatch. Compact diagnostic
audits contain no copied source or private path text. Worker-filtered events expose
quarantine outcomes, including a specific schema-mismatch reason.

Affected workers reject a changed definition before stop. Explicit stop preserves
the checkpoint, then define/start with a valid artifact initializes new state and
processes amount 3. Damaged source artifacts remain retained after repair. As
documented, explicit initialization can replace old checkpoint evidence; an operator
can copy a closed store first. Recovery itself never silently migrates or rewrites
broken source/state/intent records, and no automatic retry of quarantined hosts is
armed. Prior migration-failure and exhausted restart-budget tests stay green.

A minimum-response case retains 21 invalid inactive/selected artifacts and one
affected worker. Recovery returns healthy readiness and all 22 diagnostic rows
through `detail: "recovery"` pages at 1,024 bytes. Unit pages cover maximum-length
IDs, explicit reason omission, complete duplicate MCP encoding and stale generation/
boot cursor rejection. Original source, store paths and raw exception stacks are
omitted. Last-boot diagnostic rows are a snapshot; individual worker inspection
reflects subsequent repair. Normal summary snapshots retain their existing bounded
omission/error behavior if a configured response cannot contain them.

A trusted pre-validation barrier proves health 503, recovery reads and mutations
returning `RUNTIME_RECOVERING`, and no admitted request or store change while held.
Releasing it reconstructs healthy routing, diagnostics, queue counts and a bounded
wakeup before readiness opens. A lowered global worker limit closes authority
without changing metadata or definitions. A separate request-table overflow with
a real retained artifact proves zero compilation attempts and no interrupted-request
rewrite. All table ceilings are checked before recovery work. Unsupported format,
unusable directory and malformed global lineage fail startup and preserve their
original evidence. A first HTTP test tried querying ArtifactRegistry after authority
shutdown; observing closed availability and inspecting the closed store replaced
that invalid assumption, with compiler-order verification in an isolated unit test.

A regression first proved malformed `artifact_revision` metadata could enter the
delivery selector. Full envelope/identity/path/payload/reference validation now
quarantines it without touching original evidence. Another regression proved a
large backward UTC jump could request a wakeup beyond the timer ceiling. Scheduling
now uses bounded wakeup intervals and rechecks the unchanged absolute deadline.
The four timer tests and all prior delivery/restart tests pass. Recovery audits are
trimmed to the configured history bound and do not advance application generation.
Validation helpers were split to resolve Credo complexity without suppressions.

README, contributor and API guidance cover ready-with-quarantines, paginated
inspection, boot-snapshot semantics, explicit repair/evidence retention and global
failure behavior. Tool names, API version and HTTP transport remain unchanged;
`recovery` is an additive inspection detail. Claude Code remains explicitly
untested. A12 and isolated-recovery portions of A08/A14 now have automated evidence;
release storage and the actual Codex client journey remain pending.

## release-storage

Pending. Owning [task](tasks/release-storage.md). No execution evidence yet.

## codex-restart-demo

Pending. Owning [task](tasks/codex-restart-demo.md). No execution evidence yet.

## evidence-review

Pending. Owning [task](tasks/evidence-review.md). No execution evidence yet.

## Acceptance and milestone evidence

Source recovery evidence for A01, desired definitions/logical identities/fresh hosts
for A02/A05/A06, selected implementation evidence for A03, committed event-state
evidence for A04, automated no-client recovery
for A07, timer/effect recovery and internal deduplication evidence for A10/A11,
isolated quarantine/repair evidence for A12,
and source/lifecycle/event/delivery boundary evidence for A08/A09/A14 are recorded above. Milestones 5 and 6 have verified automated exits.
Full acceptance reconciliation, the actual-client portion of A07, and milestone 7
remain pending. Add an evidence table mapping
each criterion to exact tests/results and committed artifacts as features land.
The final evidence-review reconciles these existing records; it does not create
missing runtime coverage.

## Actual Codex demonstration

Pending. No Phase 2 actual Codex session has been run for this planning checkpoint.
Record prompt snapshots, session provenance, tool calls, pre-kill state, disconnected
SIGKILL/restart, automatic restoration, resumed timers/effects and fresh-session
post-recovery evolution. Preserve the distinction from automated HTTP fixtures and
from Claude Code, which remains untested with this project.
