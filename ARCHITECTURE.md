# elixir-mixir architecture entry point

The governing design is [ADR-001](docs/adr/001-architecture.md). The implemented
Phase 1 contract, limits and failure boundaries are in the
[runtime API](docs/runtime-api.md); task checkpoints and evidence are in the
[Phase 1 plan](docs/sdlc/phase01/plan.md) and
[verification record](docs/sdlc/phase01/verification.md).

The permanent Elixir/OTP kernel under lib/ provides a loopback MCP endpoint,
serialized Manager, bounded compilation into immutable module slots, temporary
supervised hosts, bounded callbacks, logical effect dispatch and read-only
inspection/history. Generated application behavior enters only through MCP and
stays in the in-memory artifact registry. No counter or aggregator starts with the
kernel. Kernel development and runtime evolution are separate activities.

Worker IDs route events independently of diagnostic PIDs. Replacement changes a
host's active immutable artifact while keeping its PID/mailbox and compatible
state; schema changes require explicit migration. Request IDs cache complete
outcomes across client sessions. Effect admission precedes state commit; dispatch
is asynchronous and best effort across the documented Phase 1 commit/publication
crash gap. Per-worker restart budgets contain host crashes, rerunning init and
losing volatile state. Manager, artifact registry or dispatcher authority loss
stops the kernel rather than pretending to recover empty metadata.

Definitions, state, request outcomes, timers, graph counts and history are in
memory. Logical identity, immutable artifact/schema revisions, deterministic effect
IDs and explicit commit boundaries leave Phase 2 seams; there is no persistence,
durable outbox, kernel recovery, clustering or autonomous controller in Phase 1.

The [Dockerfile](Dockerfile) builds a production OTP release. The
[release environment](rel/env.sh.eex) disables distribution, keeps temporary files
under /tmp and bounds VM threads/ports. This avoids Mix/dependency downloads at
startup and oversized port-table allocation under unusually high Docker FD limits.
The [demonstration](examples/phase_1_demo.md) runs generated behavior only inside a
disposable, nonroot, read-only, resource-limited container. Host networking makes
its loopback listener reachable on Linux; it is not a network sandbox. Use a
separate disposable Linux VM for stronger separation. Generated Elixir retains
BEAM privileges; callback limits are resource controls, not hostile-code isolation.
