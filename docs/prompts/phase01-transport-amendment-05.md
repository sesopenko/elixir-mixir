# Phase 1 transport deadline and kernel-lifetime refinement 05

Read with the implementation assignment, unattended-continuation amendment 04,
original planning snapshot, prior amendments, plan and current task.

The artifact-compiler checkpoint reproduced a required-contract failure with the
real default compile deadline: a `Process.sleep(:infinity)` template resulted in
HTTP 500 after five seconds, instead of the cached bounded COMPILE_FAILED result.
Installed Hermes 0.14.1 source explains the cause: StreamableHTTP.handle_message/4
and handle_message_for_sse/4 call GenServer.call without a timeout argument, imposing
5,000 ms even though the server request timeout is configured to 7,000 ms.

Keep the pinned Hermes version. Add a thin POST adapter sending the same versioned
transport messages with an explicit 7,000 ms operation wait. Reuse Hermes sessions,
request handling, component schemas, response encoding and SSE registration. GET
and DELETE still use the Hermes Plug. Do not modify vendored package source. The
same real-HTTP test now verifies the full five-second compilation timeout returns
COMPILE_FAILED and replays without a second attempt; existing JSON/SSE and reconnect
checks verify transport compatibility.

Root supervision also now enforces the already-planned fatal-authority rule:
Manager and ArtifactRegistry are temporary significant children, and the root
one_for_one supervisor uses auto_shutdown: :any_significant. Losing authoritative
metadata shuts down the kernel instead of silently restarting empty authority.
Other children retain ordinary supervision. This is a concrete OTP implementation
of the existing failure boundary, replacing the plan's shorthand that every root
child was permanent. A separate-BEAM test kills the registry and observes root and
Manager shutdown.

The fixed module-slot counter is a VM-lifetime atomics reference in persistent_term.
Application stop/start loses in-memory artifacts but cannot reuse consumed slots.
A fresh-BEAM exhaustion test proves failed attempts remain consumed across that
restart. No persistence or Phase 2 recovery behavior is introduced.
