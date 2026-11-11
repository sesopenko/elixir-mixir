# Phase 1 dependency amendment 02

During kernel-api implementation, `mix deps.get` with the planned Jason 1.4.4 pin
failed: Doctor 0.23.0 requires Decimal ~> 3.1; Jason 1.4.4 accepts only Decimal 1/2.
The baseline already locks Jason 1.4.5 and Decimal 3.2.0. Published package source
in `deps/jason/mix.exs` confirms 1.4.5 accepts Decimal 1/2/3, while
`deps/doctor/mix.exs` confirms the Doctor requirement. Hex resolution supplies the
reproduction and full `mix check` will validate the compatible selection.

Use exact Jason 1.4.5 for kernel-api and subsequent tasks. Keep Doctor and every
quality threshold unchanged. This evidence-based correction follows the plan's
instruction to record dependency incompatibilities; it changes no runtime contract.
Read this alongside the original planning snapshot, amendment 01, implementation
assignment and current task. Original assignment snapshots remain unchanged.
