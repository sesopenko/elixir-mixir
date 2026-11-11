# Phase 2 session 2 callback-contract clarification

This clarification is appended to the preserved session 2 instructions before the
next actual execution. It corrects an omitted signature; it does not change the
requested arithmetic or recovery scope. The earlier actual attempt remains under
`docs/sdlc/phase02-restart/evidence/attempt01/`.

The callback tuple order is mandatory:
- init(config) -> {:ok, state_map} | {:error, reason}
- handle_event(event, state) -> {:ok, reply, new_state_map, effect_list}
  or {:error, reason}
- state_schema() -> positive integer
- migrate(old_state, metadata) -> {:ok, migrated_state_map} | {:error, reason}

In particular, after calculating new_count and new_state, return
`{:ok, new_count, new_state, effects}`. Returning the state in position 2 and the
numeric reply in position 3 is INVALID_TRANSITION. Counter state must remain the
nested JSON map; a numeric third element is invalid. Migrate's arguments are old
state first, metadata second. Equal schema skips migration entirely.

If an authored callback fails, investigate the actual tool result and the source
you submitted. Correct that source through a new runtime_define and expected-
revision replacement, using fresh request IDs, then reverify actual arithmetic.
Do not claim the failed transition succeeded. Do not change kernel files or use
any tools outside the elixir_mixir MCP runtime tools.
