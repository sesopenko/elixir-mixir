# elixir-mixir architecture entry point

The governing design is [ADR-001](docs/adr/001-architecture-initial-phases.md). The implemented
memory and durable contracts, limits and failure boundaries are in the
[runtime API](docs/runtime-api.md); task checkpoints and evidence are in the
[Phase 1 plan](docs/sdlc/phase01/plan.md) and
[verification record](docs/sdlc/phase01/verification.md). Durable recovery and its
actual Codex demonstration are recorded in the
[Phase 2 plan](docs/sdlc/phase02-restart/plan.md) and
[verification record](docs/sdlc/phase02-restart/verification.md).

The permanent Elixir/OTP kernel under lib/ provides a loopback MCP endpoint,
serialized Manager, bounded compilation into immutable module slots, temporary
supervised hosts, bounded callbacks, logical effect dispatch and read-only
inspection/history. Generated application behavior enters only through MCP and
is compiled into bounded artifact slots. No counter or aggregator starts with the
kernel. Kernel development and runtime evolution are separate activities.

Worker IDs route events independently of diagnostic PIDs. Replacement changes a
host's active immutable artifact while keeping its PID and compatible state;
schema changes require explicit migration. The coordinator prepares and validates
callback results before publication. Memory mode retains metadata only for its
runtime lifetime; host recovery reruns init and loses volatile state.

Setting `ELIXIR_MIXIR_DATA_DIR` selects an exclusive local CubDB store. Durable
mutations commit authoritative source, definitions, state, revisions, request
outcomes and outgoing effects before live publication and acknowledgement. Boot
validates/recompiles retained sources, creates fresh hosts from committed state
without init or migration, and reconstructs routes and timers before readiness.
It quarantines invalid generated records while healthy workers recover. Store
uncertainty closes availability rather than continuing from stale memory.

Internal delivery consumes its pending ID atomically with target state and child
effects, preventing duplicate committed transitions after interruption. Timers keep
absolute UTC deadlines. Logs and direct generated IO can repeat; exactly-once
external effects are outside this phase. Request outcomes have bounded retention,
so an expired caller key may execute again. Durable recovery needs no LLM. The
[restart walkthrough](docs/phase02-recovery.md) covers retained-volume deployment;
[actual Codex evidence](examples/phase_2_recovery.md) shows further evolution after
SIGKILL and automatic recovery. Clustering and autonomous control remain future work.

The [Dockerfile](Dockerfile) builds a production OTP release. The
[release environment](rel/env.sh.eex) disables distribution, keeps temporary files
under /tmp and bounds VM threads/ports. This avoids Mix/dependency downloads at
startup and oversized port-table allocation under unusually high Docker FD limits.
The [demonstration](examples/phase_1_demo.md) runs generated behavior only inside a
disposable, nonroot, read-only, resource-limited container. Host networking makes
its loopback listener reachable on Linux; it is not a network sandbox. Use a
separate disposable Linux VM for stronger separation. Generated Elixir retains
BEAM privileges; callback limits are resource controls, not hostile-code isolation.
