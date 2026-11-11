# Contributing

## Development environment

The initial supported baseline is Elixir 1.18.3 and Erlang/OTP 27. The Mix project
requires Elixir `~> 1.18`. On Debian/Ubuntu, install the prerequisites:

```sh
sudo apt update
sudo apt install git elixir erlang-dev build-essential erlang-dialyzer
```

Distribution package versions vary. Check that your installed versions match the
baseline before developing:

```sh
elixir --version
mix --version
```

From the repository root, install Hex and fetch the locked dependencies:

```sh
mix local.hex --force
mix deps.get
```

Credo, Dialyxir, and Doctor are development/test tools and do not run as production
application dependencies. Commit `mix.lock` when changing dependencies. No
database, container, credentials, or external services are needed for this
bootstrap.

## Run the application

```sh
mix compile --warnings-as-errors
mix run -e 'IO.inspect(ElixirMixir.hello())'
iex -S mix
```

The greeting command prints `:world`. In IEx, call `ElixirMixir.hello()` or inspect
the empty supervision tree with
`Supervisor.which_children(ElixirMixir.Supervisor)`. Exit IEx with Ctrl+C twice.

To keep the OTP application running without an interactive shell:

```sh
mix run --no-halt
```

Stop it with Ctrl+C twice. The bootstrap starts an empty supervisor and does not
yet expose an MCP endpoint. Kernel development happens in this repository;
future demonstrations will create application behavior through MCP, as described
in [the architecture](docs/adr/001-architecture.md).

## Tests

ExUnit runs unit tests and doctests. The bootstrap tests the `:world` greeting and
application supervisor startup.

```sh
mix test
mix test test/elixir_mixir_test.exs
mix test test/elixir_mixir_test.exs:5
mix test --cover
```

The `file:line` form selects the test at that line; adjust the line number as the
file changes. Coverage reports are written to the ignored `cover/` directory.

## Code quality

Run the required gate before submitting changes:

```sh
mix check
```

The alias uses the test environment and stops on a failed check. It checks
formatting, compiles with warnings treated as errors, runs strict Credo and
Doctor, runs ExUnit with warnings treated as errors, and runs Dialyzer.

Individual commands are available for faster feedback:

| Task | Command |
| --- | --- |
| Apply formatting | `mix format` |
| Check formatting without edits | `mix format --check-formatted` |
| Compile without warnings | `mix compile --warnings-as-errors` |
| Check style and consistency | `mix credo --strict` |
| Check documentation and typespec coverage | `mix doctor --raise` |
| Run tests without warnings | `mix test --warnings-as-errors` |
| Analyze types | `MIX_ENV=test mix dialyzer` |
| Explain a Dialyzer warning | `mix dialyzer.explain WARNING_NAME` |

[Doctor](https://doctor.hexdocs.pm/readme.html) enforces 100% module documentation,
function documentation, and typespec coverage through `.doctor.exs`. Document
exceptions and provide a `t()` typespec for structs. Do not lower thresholds or
exclude modules to pass the gate.

Dialyzer uses inferred types and `@spec` annotations to find type mismatches and
impossible calls. It complements tests; a clean analysis does not prove every
input is safe. Its first run builds Persistent Lookup Tables (PLTs), which can
take several minutes. Later runs reuse the caches under ignored
`_build/dialyzer/`. Runtime upgrades and dependency changes can require rebuilding
or updating them. Do not commit PLTs or suppress findings to pass the gate.

Use idiomatic Elixir naming, focused modules, documented public APIs, accurate
typespecs, and focused behavior tests. See the
[code-quality rules](rules/30-code-quality.md). For unexpected results, follow the
[root-cause rule](rules/00-root-cause.md): prove the cause with a test before
fixing the system, and stop and ask the user after three unsuccessful attempts.

## Agent instructions

Project instructions live in separate `rules/*.md` files. Their numeric filename
prefixes determine the order of the generated `AGENTS.md`.

After changing any rule, run:

```sh
./scripts/build-agent-rules.sh
```

Include the regenerated `AGENTS.md` with the rule changes. Do not edit it
directly.
