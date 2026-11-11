## Code quality

- Run `mix check` before considering a change complete. It requires formatter compliance, compilation without warnings, strict Credo checks, ExUnit tests without warnings, and Dialyzer analysis.
- Format Elixir code with `mix format`; use the committed formatter and Credo configurations.
- Use `ElixirMixir` module namespaces, `CamelCase` module names, and `snake_case` functions, variables, and filenames.
- Keep modules focused, prefer pattern matching and small functions, and use standard Elixir/OTP primitives before adding dependencies.
- Document public modules and functions with `@moduledoc` and `@doc`; add accurate `@spec` annotations to public functions. Internal modules may explicitly use `@moduledoc false`.
- Write focused ExUnit tests for observable behavior, including failure paths when relevant. Use doctests for executable public API examples and `async: true` only when tests do not share mutable state.
- Fix compiler, Credo, and Dialyzer findings at their cause. Do not blanket-disable checks or suppress warnings to make the quality gate pass.
- Keep development tooling out of production runtime dependencies and commit `mix.lock` when dependencies change.
- Follow `CONTRIBUTING.md` for setup and common development tasks.
