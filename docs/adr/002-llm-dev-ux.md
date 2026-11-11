# elixir-mixir — Prioritized Agent Developer Experience Roadmap

## Objective

Extend elixir-mixir beyond the initial seven-tool runtime to make it significantly easier for autonomous AI agents to construct, test, debug, optimize, and evolve running applications.

The guiding principle is **agent-first development**: capabilities should minimize unnecessary context consumption, tool calls, repeated computation, and uncertainty about the consequences of runtime changes.

The roadmap is ordered by implementation priority and dependencies.

## Baseline and prerequisites

**Phase 1 — Live Genesis** establishes the seven MCP tools for defining, starting, invoking, inspecting, stopping, and replacing live workers, plus reading runtime events:

- `runtime_define`
- `runtime_start`
- `runtime_replace`
- `runtime_invoke`
- `runtime_inspect`
- `runtime_stop`
- `runtime_events`

**Phase 2 — Durable Genesis** introduces persistent artifacts, state, topology, operation journals, and recovery.

The following features build upon these foundations. Phase 2 can proceed in parallel where appropriate, but any guarantee that must survive a complete BEAM restart depends on its durable storage and journal.

**Implementation status:** These seven tools represent the intended Phase 1 API, not a claim that all are currently implemented. The developer-experience features in this roadmap are recommendations beyond that baseline.

## Prioritized feature list

| Priority | Feature | Dependencies | Agent developer experience |
|---|---|---|---|
| **1** | **Read and patch exact artifact revisions** | Phase 1 artifact registry | Resolve a worker to its active artifact, read source by path or line range, and submit patches against a specific source hash. Fresh agents can inspect and modify unfamiliar implementations without reconstructing source from memory. |
| **2** | **Run candidates in a disposable runtime** | Phase 1 process host and effect dispatcher | Submit code, unit tests, fixtures, and assertions. Start from specified worker state and queued events, advance a controlled clock, inject inputs, and inspect resulting effects. Failed experiments cannot mutate live state or consume live compilation slots. |
| **3** | **Compare revisions and reproduce behavioral differences** | 2 | Execute baseline and candidate revisions against identical scenarios. Control event ordering and nondeterministic inputs, compare outputs and state transitions, and report the first meaningful difference with a reproducible fixture. |
| **4** | **Enforce verification before activation** | 2; optionally 3 for comparative checks | Reject worker starts and replacements unless the exact artifact passes required tests, regression suites, and versioned code-quality policies. Expose actionable diagnostics and allow verification to be rerun independently. |
| **5** | **Trace and await logical operations** | Phase 1 operation and effect IDs | Follow requests across workers, effects, and deliveries. Identify committed, pending, failed, and unknown outcomes. Await specific results with bounded deadlines and recover operation context after agent disconnection. |
| **6** | **Verify and reconcile external effects** | 5; optionally 2 for failure rehearsal | Provide destination-specific effect tracking, completion evidence, retry policies, and reconciliation of ambiguous outcomes. Agents can recover partial failures without blindly repeating successful external operations. |
| **7** | **Support long-running jobs and reusable intermediate outputs** | 5; 6 for external executors | Run expensive work asynchronously, expose job status, and publish immutable results. Subsequent behavior revisions can reuse intermediate outputs without repeating expensive upstream computation. |
| **8** | **Define multi-file behavior bundles** | 1, 2, 4 | Package behavior entry points, helper modules, tests, and fixtures into one immutable artifact. Support targeted file patches, source-level diagnostics, and safe coexistence of multiple dependency revisions. |
| **9** | **Search responsibilities across source and runtime topology** | 1, 5 | Search for behavior, responsibilities, message contracts, consumers, dependencies, and relevant tests. Combine static relationships with runtime observations, distinguishing known relationships from inferred or unresolved ones. |
| **10** | **Coordinate resumable multi-worker upgrades** | 4, 5, 9; Phase 2 for restart durability | Execute ordered changes across related workers. Validate compatibility, enforce revision preconditions, handle queued messages from older implementations, and recover interrupted upgrade plans. |

## Recommended implementation sequence

### Milestone A — Verified runtime evolution

**Features 1–4**

Deliver a complete agent development loop:

1. Inspect the currently running implementation.
2. Create a candidate using source-level modifications.
3. Execute tests and behavioral simulations without affecting the live runtime.
4. Compare candidate behavior against the existing implementation.
5. Activate only the exact artifact that passed verification.

**Acceptance scenario:** An agent optimizes a procedural terrain generator while preserving previously generated seeded worlds. It identifies an ordering-dependent regression, corrects the implementation, and proves that the runtime rejects the defective revision while accepting the verified replacement.

### Milestone B — Observable and recoverable execution

**Features 5–7**

Enable agents to understand outcomes beyond an immediate function return.

An agent must be able to determine what happened to an operation, which downstream effects completed, which remain pending, and whether retrying is safe.

Long-running computations should expose reusable intermediate results.

**Acceptance scenario:** A weather ingestion service forwards observations to multiple destinations. One destination becomes unavailable. The agent diagnoses the partial failure, reconciles the uncertain outcome, and restores the missing measurement without duplicating successful deliveries.

A secondary acceptance test verifies that an agent can change subtitle-formatting logic without repeating an expensive transcription.

### Milestone C — Complex application construction

**Features 8–10**

Enable agents to develop larger applications consisting of interdependent behaviors, reusable modules, and multiple cooperating workers.

The system should support source-level organization without sacrificing immutable revision identity or live process evolution.

**Acceptance scenario:** An agent upgrades a multi-worker application that exchanges versioned messages. It stages compatible changes, preserves messages already in flight, validates the complete behavior, and resumes the upgrade correctly after losing its connection.

## Architectural principles

**Immutable, addressable revisions.** Source, dependencies, tests, verification evidence, and behavior revisions must be associated with explicit identities.

**Verification belongs to the runtime.** Agents propose implementations, but the kernel enforces activation requirements rather than trusting agent-reported test success.

**Experiments are isolated from production behavior.** Candidate execution must not mutate live worker state or perform uncontrolled external effects.

**Diagnostics should support the next action.** Return specific failures, affected source locations, first behavioral differences, and reproduction references rather than generic success/failure summaries.

**Observability must include downstream outcomes.** Accepting an event is not equivalent to successfully delivering its effects.

**Expensive work should be reusable.** Immutable intermediate outputs and resumable jobs should allow agents to iterate without repeating unrelated computation.

**Dependencies are explicit.** Bundle revisions must preserve the implementations of their helper modules, contracts, and declared dependencies.

**Long-running changes are recoverable.** The runtime should preserve sufficient execution and change-plan information for another agent session to safely continue.

**The running process graph remains the application model.** Source files, bundles, tests, and verification results support the development experience, but do not replace the ADR's runtime-first architecture.

## Initial recommendation

Implement **Features 1–4 as the first post-Phase-1 developer-experience milestone**.

These establish the foundation on which the remaining capabilities become useful: an agent can inspect the current system, propose a change, experimentally verify its consequences, and safely activate the result.

The primary success measure should not be the number of tools implemented. It should be whether a fresh agent can independently diagnose a defect, produce a correct revision, verify its behavior, and evolve the running application without unnecessary human intervention.

---

# Supporting Design Analysis

The following sections preserve the scenarios, engineering reasoning, developer-experience requirements, and implementation cautions that informed the priorities above.

## Why the initial seven tools are insufficient

The original MCP tools answer seven fundamental questions:

- Can an agent create executable behavior?
- Can it start a worker?
- Can it invoke that worker?
- Can it inspect the running system?
- Can it replace behavior without restarting the process?
- Can it stop a worker?
- Can it observe recent events?

These are sufficient to establish the initial experiment: an LLM can construct and evolve a live application through MCP.

They do not yet provide a complete software development experience.

Consider a fresh agent given the instruction:

> A production behavior is wrong. Find the responsible code, repair it, prove the repair, and keep everything else working.

With only the initial tools, the agent may encounter several problems:

1. It can inspect a worker's state but cannot necessarily retrieve its exact active source.
2. It can compile a candidate but cannot run comprehensive tests against that inactive candidate.
3. It may have to experiment on live workers to determine whether a change works.
4. It cannot reliably distinguish an accepted event from a successful downstream outcome.
5. It may understand one worker but not the consequences of changing its messages to other workers.
6. It cannot rely on the runtime to reject a candidate that has failed its regression tests.
7. It may lose essential debugging or upgrade context when the agent session ends.

The roadmap addresses these gaps.

The central developer-experience requirement is:

**An agent should be able to investigate, reproduce, change, verify, and activate application behavior without treating the live application as its test environment.**

The following simulations demonstrate why this matters.

## Scenario 1 — Reservation management and legacy scheduled events

### Application

A service manages limited inventory using reservations with expiration deadlines.

It has:

- An inventory worker.
- Reservation state.
- Scheduled expiration events.
- Operations to create, renew, and release reservations.

Assume an initial inventory of 10 units and a reservation for 3 units. Available inventory is 7.

A new requirement allows users to renew reservations.

### The difficult case

An existing reservation was scheduled to expire at time `t = 5`.

At time `t = 4`, the reservation is renewed until `t = 10`.

The original expiration message remains queued and arrives at `t = 5`.

The application also contains other reservations that were **not** renewed and still need to expire normally at `t = 5`.

The agent is asked:

> Renewed reservations sometimes put stock back too early. Fix the bug.

### Mental simulation

**Candidate A: Release any matching active reservation when its expiration event arrives.**

This passes a simple test in which an unrenewed reservation expires.

It fails the renewed-reservation test. The old queued expiration event releases 3 units at `t = 5`, even though the reservation is valid until `t = 10`.

**Candidate B: Ignore expiration messages that use the old event format.**

This fixes the renewed reservation.

It introduces another bug. Old, unrenewed reservations never expire, so inventory becomes unavailable indefinitely.

**Candidate C: Check the current authoritative deadline before releasing inventory.**

At `t = 5`, a renewed reservation has a current deadline of `t = 10`, so its inventory remains reserved.

An unrenewed reservation whose current deadline is `t = 5` is released normally.

At `t = 10`, the renewed reservation can be released if it has not been renewed again.

This candidate handles both cases.

### What an agent needs from the runtime

The test environment should support:

- Loading a worker's state from a specific revision.
- Queuing events generated by an earlier implementation.
- Replacing the worker implementation before delivering those events.
- Advancing virtual time without waiting for real timers.
- Asserting available inventory and reservation status at specific times.
- Running both renewed and unrenewed scenarios together.
- Returning a trace of state changes and emitted effects.

The most important discovery is that **successful state migration does not prove behavioral compatibility with outstanding messages**.

A worker can preserve its PID, mailbox, and state while still mishandling messages created by earlier versions.

### Features validated

- **2:** Disposable scenario execution.
- **3:** Baseline/candidate comparison and reproducibility.
- **4:** Regression verification before activation.
- **5:** Tracking scheduled effects.
- **10:** Compatibility-aware upgrades.

This is also a strong future test of multi-worker protocol evolution.

## Scenario 2 — Event batching and the distinction between accepted and completed

### Application

An event aggregator buffers incoming items and forwards them downstream in batches of three.

Its implementation emits a batch immediately when the buffer reaches three items.

An agent is asked to ensure events are delivered even when traffic slows.

### Test sequence

Events arrive at these times:

| Time | Event | Buffered count | Result |
|---|---|---|---|
| `t = 0` | A | 1 | Accepted, not yet delivered |
| `t = 1` | B | 2 | Accepted, not yet delivered |
| `t = 2` | C | 3 | Batch A/B/C emitted |
| `t = 30` | D | 1 | Accepted, not yet delivered |
| `t = 35` | No new event | 1 | D remains buffered indefinitely under the original policy |

At `t = 35`, all four events have been accepted, but only three have been forwarded.

A test that checks only immediate invocation replies reports success.

A test that checks only whether the first batch was emitted also reports success.

Neither detects the stranded event.

### Proposed correction

Add a maximum buffer residence time of five seconds.

If the buffer has not reached three items within that interval, flush the partial batch.

At `t = 35`, event D is forwarded.

### What an agent needs from the runtime

The agent should be able to:

- Advance the test clock to `t = 35`.
- Assert that all four accepted items reached the intended downstream consumer.
- Inspect the operation tree rooted at each incoming event.
- Distinguish buffering, delivery attempts, and successful completion.
- Reproduce the failure with no live worker mutations.

A useful result might distinguish:

- 4 events accepted.
- 2 batches emitted.
- 4 items delivered.
- 0 pending items.
- 0 failed deliveries.

### Features validated

- **2:** Virtual-time scenarios.
- **3:** Behavioral comparison.
- **5:** Causal operation tracing and outcome waiting.

This scenario also establishes an important API rule:

**An effect acknowledgement must not be presented as proof of downstream delivery.**

## Scenario 3 — Ecowitt weather ingestion and partial external failures

### Source projects

- [ecowitt-proxy](https://github.com/sesopenko/ecowitt-proxy)
- [ecowitt-to-influxdb](https://github.com/sesopenko/ecowitt-to-influxdb)

The proxy forwards weather-station reports to multiple destinations because the Ecowitt gateway supports only one custom endpoint.

Those destinations can include Home Assistant, Hubitat, and an InfluxDB collector.

The proxy's implementation returns HTTP 200 without waiting for every downstream destination to succeed.

A related observation from the repositories: the proxy's forwarding test verifies that selected form fields reached the HTTP client, while the InfluxDB parser requires additional fields, including absolute pressure and the observation timestamp.

This illustrates a general limitation of tests that stop at a service boundary: successful forwarding does not establish successful ingestion.

### Agent assignment

> Home Assistant received the noon observation, but the historical archive is missing it. Recover the observation without creating duplicate deliveries.

### Mental simulation

**Candidate A: Retry the original incoming request.**

This may recover the archive.

It also resends the request to destinations that already succeeded.

**Candidate B: Retry only the failed archive branch.**

This is better.

However, it still has an unresolved case: the archive may have stored the observation successfully while its response was lost.

A retry could duplicate an externally visible effect.

**Candidate C: Reconcile the archive's actual state before retrying.**

If the destination exposes a suitable read API, the agent or effect adapter checks whether the observation identified by station and timestamp already exists.

If the observation exists with the expected values, no retry is needed.

If it does not exist, the runtime retries according to the destination's supported idempotency contract.

If the destination cannot establish whether a write succeeded and has no safe idempotent retry mechanism, the result must remain **unknown**, not falsely reported as successful or failed.

### Required failure scenarios

The rehearsal environment should distinguish:

1. The archive rejects a request before storing the observation.
2. The archive stores the observation but the acknowledgement is lost.
3. One destination succeeds while another fails.
4. The process crashes after scheduling an external effect but before completion.
5. A retry encounters an already completed effect.

### What an agent needs from the runtime

Each external effect should have:

- A stable effect ID.
- A named destination and operation.
- A completion state.
- A retry policy.
- Any available idempotency key.
- A way to obtain destination-specific completion evidence.
- A correlation link to its originating operation.

For this scenario, the agent should be able to ask:

> What happened to the archive delivery for this station and observation timestamp?

The response should separate what the runtime knows from what it has merely attempted.

### Features validated

- **5:** Logical operation tracing.
- **6:** External effect reconciliation.
- **2:** Failure simulation for external adapters.

### Architectural conclusion

The original dispatcher supports internal `emit`, `schedule`, and `log` effects.

External integrations should be added through controlled, kernel-managed adapters rather than assuming arbitrary network or filesystem calls inside generated callbacks have durability guarantees.

**Exactly-once external execution must not be promised.** Where available, recipient-supported idempotency and reconciliation can make retries safe. Otherwise, uncertainty is a legitimate outcome.

## Scenario 4 — Procedural terrain generation and nondeterministic regressions

### Source project

[sesopenko_diamond_square](https://github.com/sesopenko/sesopenko_diamond_square)

This Elixir project implements diamond-square fractal terrain generation through a sequence of diamond and square passes.

The implementation separates higher-level generation from low-level coordinate and noise calculations.

Its architecture records a useful historical decision: removing direct GenServer responsibility from the algorithm made the computational interface easier to modify and test.

This supports a similar distinction in elixir-mixir: a stable process host should own lifecycle while behavior implementations remain focused on computations and state transitions.

### Agent assignment

> Make the terrain-generation service faster by parallelizing a pass. Existing worlds must remain reproducible from their saved inputs.

Seeded, reproducible generation is an illustrative requirement added for this scenario; the source project's random-number implementation is not itself a guarantee of seeded cross-revision reproducibility.

### Mental simulation

Two cells have the same average neighboring height: 20.

The original implementation assigns the next two noise values in coordinate order:

- Cell `(1,1)` receives `+2`, producing height 22.
- Cell `(3,1)` receives `−3`, producing height 17.

The agent parallelizes these calculations.

A different worker execution order reverses the assignment:

- Cell `(1,1)` becomes 17.
- Cell `(3,1)` becomes 22.

The generated grid still has:

- The correct dimensions.
- The correct number of cells.
- The same minimum and maximum.
- The same total and average.

A superficial regression suite passes.

However, terrain-dependent gameplay, structures, or cached assets may now refer to a different world.

### What an agent needs from the runtime

A useful comparison should report:

> First divergence: diamond pass, coordinate `(1,1)`. The baseline assigned noise `+2`; the candidate assigned `−3`.

The agent can then assign random draws deterministically to coordinates instead of depending on task scheduling order.

The test runner needs to capture or inject:

- A controlled random source.
- The position in that random stream or an equivalent deterministic key.
- Starting algorithm state.
- Named execution steps.
- Alternative permitted execution orders.
- A domain-specific comparator.

A saved seed alone is insufficient for resuming a partially generated world unless the implementation can reconstruct the precise point in its random sequence.

### Features validated

- **2:** Controlled candidate execution.
- **3:** First-divergence comparison.
- **4:** Verification against preserved worlds.
- **7:** Checkpointed and reusable intermediate outputs.

### Architectural conclusion

Reproducibility is not only about creating a fixture with known inputs.

The runtime needs a way to control **time, ordering, and other sources of nondeterminism used by the behavior under test**.

The initial runner need not emulate every possible BEAM scheduling interleaving. Explicitly controlled, named scheduling points are a useful first implementation.

## Scenario 5 — Subtitle generation and reuse of expensive computation

### Source project

[yomisub](https://github.com/sesopenko/yomisub)

This desktop application extracts audio through FFmpeg, transcribes the audio using Whisper, and converts transcription segments into SRT subtitles.

In the existing formatter, subtitle end times receive up to half a second of padding, subject to a six-second maximum duration.

### Agent assignment

> Prevent adjacent subtitles from overlapping while preserving additional reading time whenever possible.

### Mental simulation

Consider a subtitle starting at 10.0 seconds and ending at 11.0 seconds.

**Case A: The next subtitle starts at 11.2 seconds.**

The original formatter extends the first subtitle to 11.5 seconds.

The two subtitles overlap by 0.3 seconds.

**Case B: The next subtitle starts at 13.0 seconds.**

The original formatter extends the first subtitle to 11.5 seconds without causing an overlap.

### Candidate implementations

| Implementation | Next starts at 11.2 | Next starts at 13.0 |
|---|---|---|
| Original half-second padding | End at 11.5; overlap | End at 11.5; correct |
| Remove all padding | End at 11.0 | End at 11.0; unnecessary loss of reading time |
| Cap padded end at next subtitle's start | End at 11.2 | End at 11.5 |

The third implementation satisfies both requirements.

### The developer-experience problem

Running the entire application for every formatter revision would require expensive audio extraction and transcription even though neither stage changed.

The ideal development workflow is:

1. Run transcription once.
2. Preserve its segments as an immutable intermediate output.
3. Test multiple formatter revisions against those exact segments.
4. Compare the resulting subtitle cues.
5. Avoid rerunning transcription unless a relevant upstream input changes.

For example, changing the subtitle formatter should reuse the segments.

Changing the selected audio track should invalidate that reuse.

### What an agent needs from the runtime

- A stable long-running job ID.
- Progress and completion inspection.
- An immutable result reference.
- Provenance identifying the producing artifact and inputs.
- Dependency-aware result reuse.
- Bounded retrieval of individual segments or output ranges.
- A way to run downstream candidates from the saved result.

### Features validated

- **7:** Long-running jobs and reusable intermediate outputs.
- **2:** Candidate execution against saved fixtures.
- **3:** Output comparison.

### Architectural conclusion

A long-running computational job is different from a short state-transition callback.

The Phase 1 callback deadline and bounded JSON state should remain intact.

The worker can coordinate a job using IDs and compact metadata while an appropriate executor performs the expensive computation.

Generated callbacks should not directly launch unrestricted external processes as an implicit substitute for kernel-managed job execution.

---

# Detailed Developer Experience Requirements

## Feature 1 — Source inspection and patching

The artifact registry already intends to retain submitted source and its hash.

An agent should not have to reconstruct that source by reading its own prior conversation.

The preferred workflow is:

1. Inspect the worker's active artifact ID.
2. Read the relevant source at that exact revision.
3. Submit a targeted edit with the expected source hash.
4. Receive an immutable candidate artifact ID.
5. Confirm that the live worker still points to the old revision.

For multi-file bundles, source retrieval should support paths and bounded line ranges.

Patches should reject stale bases instead of silently overwriting concurrent changes.

Source search and patching should provide stable references to the code that diagnostics mention.

## Feature 2 — Candidate scenario runner

This is the most important new execution capability.

It should begin as a minimal, reusable test environment and expand through several test levels:

| Level | What is tested |
|---|---|
| Pure behavior | Callback outputs for explicit events and state |
| Single-worker scenario | Multiple transitions and assertions over time |
| Process-graph scenario | Events and effects across multiple workers |
| Temporal scenario | Timers, expiry conditions, and event ordering |
| Migration scenario | Existing state and outstanding old-version messages |
| Failure scenario | Callback failure, dropped effects, crash, retry |
| External-adapter scenario | Simulated external responses and ambiguous outcomes |

### Required controls

The runner should accept:

- Exact candidate artifact or bundle revision.
- Initial worker state and schema versions.
- Supporting worker revisions.
- Initial queued events and timers.
- Ordered event inputs.
- Controllable time.
- Controlled nondeterministic inputs where supported.
- Assertions and expected outcomes.
- Resource and execution budgets.

### Required outputs

A failure result should include:

- Assertion that failed.
- Relevant state before and after the transition.
- Inputs and events that caused the failure.
- First relevant differing effect or output.
- Active artifacts involved.
- A stable reproduction reference.
- Sufficient diagnostics for the next source edit.

### Critical implementation constraint

The Phase 1 compiler uses a bounded pool of generated module slots. Compilation attempts consume slots even when compilation fails.

Candidate experimentation must not exhaust the live BEAM's module budget.

Run disposable candidate compilation and execution in a separate, restartable executor environment.

A separate Elixir Task in the same BEAM is not a security boundary.

The initial runner can use declarative, data-driven scenarios and runtime-owned assertions. More elaborate ExUnit test bundles can be added when multi-file packaging is implemented.

## Feature 3 — Baseline/candidate comparison

Ordinary unit tests answer:

> Did this implementation produce an expected result?

Comparison testing adds:

> What changed relative to the implementation that is already working?

The comparison mechanism should:

- Start baseline and candidate from equivalent checkpoints.
- Apply the same controlled inputs.
- Compare externally meaningful results first.
- Identify the earliest divergence.
- Support configurable assertions and tolerated differences.
- Produce a rerunnable reproduction.
- Avoid dumping unrelated state into the agent's context.

### Examples of useful comparisons

- Reservation inventory before and after scheduled expiry.
- Number of events accepted versus delivered.
- First terrain coordinate with a different height.
- First subtitle cue with a different timestamp.
- Changed downstream messages or external effect requests.

Not every difference is a regression. The comparison should be paired with explicit behavioral expectations.

For example, an intended change to batching may alter effect timing while preserving the requirement that all items are eventually delivered.

## Feature 4 — Verification and activation policy

The runtime should distinguish between:

**Code quality checks**

- Formatting.
- Compilation diagnostics.
- Documentation and typespec requirements.
- Static analysis.
- Complexity and maintainability policies.

**Behavioral verification**

- Unit tests.
- Regression tests.
- Integration scenarios.
- State migration checks.
- Pending-message compatibility.
- Failure injection.

**Operational compatibility**

- Resource-budget compliance.
- Supported behavior contract.
- Declared event schemas.
- Effect permissions and dependencies.
- Activation revision preconditions.

The project's existing `mix check` workflow is a useful precedent, but it verifies the conventional kernel repository.

A separate mechanism must verify agent-generated runtime artifacts.

### Verification evidence must be revision-bound

A passing verification record should identify at least:

- Artifact or bundle hash.
- Exact dependency revisions.
- Test-suite revision.
- Fixture revision.
- Verification-policy revision.
- Test-executor version.
- Individual outcomes and diagnostics.
- Verification run ID.

Activation must require evidence applicable to the exact candidate being activated.

A passing result for an earlier source revision must not authorize a later revision.

### Tests must not be silently weakened

The agent may propose new tests and modifications to existing tests, but it must not be able to bypass verification by simply deleting failing tests or lowering quality thresholds.

An independently controlled verification policy should define required checks.

New agent-generated tests can extend the suite without automatically gaining authority to remove established regressions.

### Integration with existing tools

Rather than requiring a completely separate deployment workflow, the verification gate can be enforced inside the existing `runtime_start` and `runtime_replace` paths.

Compilation and testing remain separate from activation.

A failed activation attempt must leave the active worker's artifact, state, revision, and PID unchanged.

## Feature 5 — Causal tracing and operation outcomes

`runtime_events` provides chronological event history.

Chronological history alone does not necessarily explain which events belong to a particular user operation.

A useful trace should follow one root operation through:

- The initial invocation.
- The committed state transition.
- Emitted child effects.
- Scheduled deliveries.
- Receiving workers.
- Further emitted effects.
- Completion, failure, or unresolved status.

The agent should be able to retrieve or await an operation by ID without repeatedly scanning an entire global event log.

### Distinguish outcomes precisely

Relevant statuses include:

- Accepted.
- State committed.
- Effect queued.
- Effect dispatched.
- Downstream acknowledgement observed.
- Completed according to a defined contract.
- Failed.
- Outcome unknown.

These statuses must not be collapsed into a single success boolean.

A request can be successful locally while one or more downstream effects fail.

### History gaps matter

The existing runtime event history is bounded.

A trace query must explicitly report when its source history is incomplete.

It should not present an incomplete sequence of events as complete evidence.

## Feature 6 — External effect reconciliation

Different external systems have different completion and retry semantics.

The runtime should allow adapters to describe:

- The operation being attempted.
- The evidence that establishes success.
- Whether the destination supports idempotency.
- How to identify an already completed operation.
- Which failures are retryable.
- How to report uncertainty.

This should be implemented as an extensible adapter contract rather than hardcoding behavior for one database or HTTP service.

### Important consistency boundary

Even with a durable outbox, a process can fail after an external destination performs an effect but before that success is recorded locally.

Therefore:

- Durable storage can preserve intent to execute an effect.
- It can support retries and recovery.
- It cannot automatically provide exactly-once external execution.

Exactly-once-like application behavior requires cooperation from the destination, such as idempotency keys or reliable reconciliation.

## Feature 7 — Long-running jobs and intermediate outputs

The runtime should distinguish short worker transitions from long-running operations.

A job should expose:

- Logical job ID.
- Current status and progress.
- Input references and producing artifact revision.
- Completion or failure diagnostics.
- Immutable output references.
- Bounded result inspection.
- Retry or restart policy.
- Cancellation semantics where supported.

### Reuse rules

An output should be reusable when the relevant inputs and upstream implementation match.

For example:

- Subtitle formatting revision changed: reuse transcription segments.
- Audio track changed: create new transcription output.
- Terrain rendering changed but the heightmap did not: reuse the heightmap.
- Terrain algorithm or random seed changed: invalidate incompatible heightmap results.

A content-addressed result store is a possible implementation, but the first useful version only needs immutable identifiers and verifiable provenance.

Large results should not be forced into a 16 KiB worker state or a single MCP response.

## Feature 8 — Multi-file bundles

Two separate capabilities must be distinguished:

**Multi-file implementation:** A single logical behavior consists of multiple source files and helpers.

**Multi-worker upgrade:** Multiple independently running workers change as part of one coordinated operation.

This feature addresses the first problem.

An immutable bundle should identify:

- Its behavior entry point.
- Helper modules.
- Configuration and supported contracts.
- Test files and fixtures.
- Declared dependencies.
- Bundle revision and content hash.

### Version isolation

If worker A uses helper revision 1 and worker B uses helper revision 2, their implementations must not collide on a shared mutable module name.

Versioned helper-module identity or another explicit isolation mechanism is necessary.

The bundle's full dependency closure, not merely its entry-point source hash, must determine what was tested.

The original Phase 1 single-module source contract should remain valid as a simpler supported case.

## Feature 9 — Responsibility-oriented search

Text search is useful for locating names and symbols.

An agent working on a running application often needs a higher-level answer:

> What is responsible for this behavior, and what else depends on it?

A useful search result can connect:

- Logical worker identity.
- Active artifact and relevant source span.
- Declared event handlers.
- Emitted event types.
- Configured destinations.
- Observed runtime communication.
- State ownership.
- Pending timers and deliveries.
- Relevant regression scenarios.
- Other workers potentially affected by a change.

The graph should distinguish:

**Declared:** A relationship established from source or a formal contract.

**Observed:** A relationship supported by runtime execution history.

**Unknown:** A possible dependency that cannot be established from the available evidence.

The runtime should not claim that an observed graph is complete when conditional paths have not executed.

Results should return bounded, relevant source ranges rather than entire artifacts.

## Feature 10 — Resumable multi-worker upgrades

Replacing one worker atomically does not make a sequence of replacements across several workers atomic.

Consider a producer that emits a new event format and a consumer that initially understands only the old format.

Replacing the producer first can break the consumer.

A safer plan is:

1. Upgrade the consumer to accept both old and new event formats.
2. Verify compatibility with existing queued messages.
3. Upgrade the producer to emit the new format.
4. Observe or drain outstanding old-format messages.
5. Remove old-format support only when the required compatibility conditions are satisfied.

A change plan should track:

- Target workers and expected revisions.
- Required ordering.
- Candidate artifact identities.
- Verification evidence.
- Completed and pending steps.
- Compatibility and drain conditions.
- Failures and recovery actions.

### Resuming an interrupted plan

If the agent disconnects after upgrading the consumer but before upgrading the producer, a new session should retrieve the plan and continue from the actual runtime state.

It should not need to infer progress from a previous chat transcript.

### Rollback is not automatically safe

Switching back to an old module does not necessarily reverse state mutations or migrations performed under a new implementation.

The upgrade plan must explicitly account for:

- Whether the old artifact can read the current state.
- Whether a reverse migration exists.
- Whether incompatible external effects have already occurred.
- Whether restoring an earlier checkpoint is permitted.

Phase 2 persistence can make upgrade plans durable across full BEAM restarts, but it does not eliminate these semantic constraints.

---

# Implementation Constraints and Tradeoffs

## Existing Phase 1 execution limits

The Phase 1 implementation plan deliberately imposes bounded runtime resources.

Relevant defaults include:

| Constraint | Phase 1 default | Implication for roadmap |
|---|---|---|
| Submitted source | 32 KiB | Large implementations need explicit bundle and source limits |
| Generated compilation slots | 128 per BEAM lifetime, including failed attempts | Candidate compilation must be isolated from the live executor |
| Top-level modules per source | One | Multi-file bundles require an extension of the compiler contract |
| Callback deadline | 200 ms | Expensive work belongs in a job executor |
| Worker definitions | 32 | Graph-wide scenarios must respect the configured test environment |
| State, event, and reply values | 16 KiB each | Large intermediate outputs need external references |
| Effects per transition | 16 | Integration scenarios must test partial and rejected batches |
| Pending deliveries and timers | 256 | Rehearsal must support capacity and backpressure tests |
| Effect hop budget | 16 | Trace results must explain exhausted hops and dropped deliveries |
| Event history | 1,000 records | Queries must disclose missing history |
| Request ledger | 1,024 entries with 10-minute retention | A retry after ledger expiry cannot be assumed safe |
| Whole MCP result | 64 KiB | Diagnostics and search results must be bounded and paginated |

These limits are not merely implementation details. They directly affect the tools an agent needs.

For example, a tool that returns a complete terrain grid or transcript in one response is incompatible with the intended bounded state and response model.

The runtime should expose references and bounded inspection instead.

## Trust and execution isolation

Generated Elixir code is not safely sandboxed by executing it in a separate Task.

Compile-time macros and runtime callbacks can perform operations with the privileges of the executing BEAM.

The roadmap's disposable test environment should use a genuinely separate execution boundary, with resource limits and no sensitive host access.

This isolation also allows candidate compilation capacity to be reclaimed by restarting the disposable executor.

The same principle applies to external job executors.

The control plane must not treat runtime-generated code as inherently trusted merely because it passed static analysis.

## Durable recovery does not preserve BEAM identities

Phase 2 reconstructs workers from persisted definitions and committed state.

A full BEAM restart does not preserve:

- PIDs.
- Live mailboxes as native process structures.
- Open file handles.
- Process references.
- Existing network connections.

Persisted operation IDs, logical worker IDs, serialized state, scheduled intents, and artifact revisions allow reconstruction without pretending the original BEAM processes survived.

This distinction is important when designing resumable jobs and upgrade plans.

## Keep the kernel small

The roadmap should not be interpreted as an instruction to introduce a large framework before finishing Phase 1.

The first implementation can remain small:

- Read exact artifact source.
- Execute a few declarative scenarios in a disposable executor.
- Record machine-readable verification evidence.
- Enforce that evidence in the existing activation path.

More elaborate scheduling, graph search, output stores, and external adapters should follow demonstrated needs.

## Capabilities are not necessarily individual MCP tools

The ten priorities describe capabilities, not a requirement to add exactly ten new public MCP endpoints.

Some capabilities may be exposed as:

- Extensions of existing tools.
- MCP resources for immutable source or results.
- Focused read-only queries.
- A small number of new execution tools.
- Internal services used by verification and activation.

Tool design should minimize unnecessary round trips while preserving precise contracts and useful errors.

---

# Agent Workflow Simulations

These are illustrative workflows, not currently implemented tool contracts.

## Workflow A — Fix an unfamiliar live behavior

**User goal:** “Renewed reservations are releasing inventory too early.”

The desired agent experience:

1. Query the runtime to identify the reservation worker and its active revision.
2. Read the responsible source and any existing regression cases.
3. Inspect scheduled expiration events relevant to the defect.
4. Reproduce the defect in an isolated scenario using an old queued event.
5. Produce a targeted source patch.
6. Run both the renewed and unrenewed reservation tests.
7. Receive a verification result tied to the candidate hash.
8. Replace the live worker only after verification succeeds.
9. Inspect the active revision and its operation outcome.

The runtime should guide the agent from the observed problem to the relevant code and then to a verified change, without requiring live diagnostic mutations.

## Workflow B — Optimize a working implementation

**User goal:** “Parallelize terrain generation without changing existing worlds.”

The desired agent experience:

1. Retrieve the active implementation and saved-world fixtures.
2. Prepare a candidate optimized implementation.
3. Run baseline and candidate against the same controlled random inputs.
4. Explore a different execution order.
5. Receive the first differing coordinate and relevant trace.
6. Fix random-draw assignment.
7. Rerun the comparison and regression suite.
8. Activate only after the compatibility requirement passes.

The important optimization is not just faster code.

It is faster development through deterministic, high-signal feedback.

## Workflow C — Recover after agent disconnection

**User goal:** “Finish the interrupted update to the event-processing pipeline.”

The desired agent experience:

1. Inspect active operation and change-plan IDs.
2. Retrieve completed and pending upgrade steps.
3. Confirm actual worker revisions.
4. Determine whether old-format events remain pending.
5. Resume the remaining compatible steps.
6. Wait for the relevant outcomes.
7. Report completion or unresolved work.

This workflow should not require the original agent's conversation history.

---

# Acceptance Tests and Success Measures

## Milestone A acceptance test

Use a small Elixir terrain-generation service.

Supply the agent with:

> Parallelize the generator while preserving existing seeded worlds.

The evaluation should include:

- At least one deterministic baseline world.
- An alternative work order that exposes a naive implementation's regression.
- A regression requirement that the agent cannot silently remove.
- A verified candidate artifact.
- Confirmation that failed candidates never became active.
- Confirmation that the successful candidate is the exact verified revision.

**Success:** The agent reproduces the defect, identifies the cause, corrects it, and activates the verified revision without mutating the live worker during experimentation.

## Milestone B acceptance test

Use a simulated weather ingestion pipeline with multiple destinations.

Inject:

- A failure before an external write.
- A successful write with a lost acknowledgement.
- A successful delivery to another destination.
- A reconnect during reconciliation.

**Success:** The agent distinguishes confirmed outcomes from uncertain ones, avoids unnecessary repeat deliveries, and does not invent completion evidence.

A separate job-reuse check should verify that changing subtitle formatting causes **zero additional transcription runs**, while changing the audio input invalidates the prior result.

## Milestone C acceptance test

Use a producer and consumer exchanging versioned messages.

Prepare:

- Existing old-format queued events.
- A new-format producer.
- A compatibility-capable consumer.
- A disconnected agent between upgrade steps.
- A state-migration case in which naive rollback would be unsafe.

**Success:** The agent stages the upgrade correctly, preserves queued message compatibility, and resumes from actual runtime state.

## Metrics to record

| Metric | Why it matters |
|---|---|
| Correct scenarios passed | Measures behavior rather than tool activity |
| Live mutations during debugging | Detects unsafe experimentation |
| Unintended external effects | Detects unsafe test execution |
| Duplicate external deliveries | Tests retry and reconciliation behavior |
| Tool calls to resolve a defect | Measures agent interaction efficiency |
| Source/context bytes returned | Measures context efficiency |
| Diagnostic steps required after a failure | Measures feedback quality |
| Repeated expensive computations | Measures intermediate-output reuse |
| Incorrect activations rejected | Measures verification enforcement |
| Successful recovery after reconnect | Measures independence from agent session history |
| Successful continuation after BEAM restart | Measures Phase 2 durability |

Compare these metrics against an agent using only the initial seven-tool interface.

A feature is valuable when it measurably improves correctness, development efficiency, or operational safety.

---

# Final Recommendations and Research Questions

## Immediate implementation target

After completing and validating Phase 1, implement the smallest version of:

1. Exact source retrieval and revision-aware patching.
2. Isolated candidate execution with deterministic fixtures.
3. Baseline/candidate behavioral comparison.
4. Verification-gated activation.

These form the minimum practical development environment for an agent evolving a live system.

## Subsequent architectural questions

The experiments should inform several decisions before larger investments are made.

**Testing representation:** Which behaviors are best expressed through declarative scenarios, and when is full ExUnit execution necessary?

**Determinism:** Which sources of nondeterminism should be controlled by the kernel, and which should be injected by the generated application?

**Artifact organization:** How much conventional source-file structure is useful before it becomes a second, competing application model?

**Effect evidence:** What level of outcome verification can a generic effect adapter provide, and what must be destination-specific?

**Search quality:** Does combining static source information with observed process relationships materially improve an agent's ability to identify change impact?

**Agent autonomy:** Can the runtime enforce stable verification policies even when the agent itself is proposing changes to implementation and tests?

**Operational scope:** At what point should generated behavior move into a separately isolated execution plane rather than sharing a BEAM with the control kernel?

## Long-term direction

The original ADR envisions an application that can progressively modify its own behavior and eventually expose newly generated capabilities.

The developer-experience roadmap provides the missing feedback loop that would make such autonomy more reliable.

A mature agent should be able to:

**Observe → Locate → Reproduce → Propose → Verify → Activate → Measure → Reconcile → Repeat**

The runtime should make every step inspectable, reproducible where possible, and recoverable according to its documented guarantees.

The intended result is not simply a runtime that accepts generated Elixir code.

It is **a runtime that gives an AI agent the evidence, controls, and safeguards needed to develop increasingly complex applications while those applications continue running.**