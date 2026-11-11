defmodule ElixirMixir.GitHooksTest do
  use ExUnit.Case, async: true

  setup do
    repo =
      Path.join(
        System.tmp_dir!(),
        "elixir-mixir hooks #{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(repo, "scripts"))
    File.mkdir_p!(Path.join(repo, ".githooks"))
    File.mkdir_p!(Path.join(repo, "bin"))
    on_exit(fn -> File.rm_rf!(repo) end)

    for path <- ["scripts/install-git-hooks.sh", ".githooks/pre-commit"] do
      File.cp!(Path.expand("../#{path}", __DIR__), Path.join(repo, path))
      File.chmod!(Path.join(repo, path), 0o755)
    end

    File.write!(Path.join(repo, "bin/mix"), """
    #!/usr/bin/env bash
    printf '%s\\n' "$PWD" "$MIX_ENV" "$*" >> "$QUALITY_HOOK_LOG"
    exit "${QUALITY_HOOK_EXIT:-0}"
    """)

    File.chmod!(Path.join(repo, "bin/mix"), 0o755)

    # Git exports repository-specific variables when invoking hooks. Clear them
    # so these fixtures remain isolated even when mix test runs in a real hook.
    {git_variables, 0} = System.cmd("git", ["rev-parse", "--local-env-vars"])
    clean_git_env = Enum.map(String.split(git_variables), &{&1, nil})

    env =
      clean_git_env ++
        [
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_AUTHOR_NAME", "Hook Test"},
          {"GIT_AUTHOR_EMAIL", "hook-test@example.invalid"},
          {"GIT_COMMITTER_NAME", "Hook Test"},
          {"GIT_COMMITTER_EMAIL", "hook-test@example.invalid"},
          {"PATH", Path.join(repo, "bin") <> ":" <> System.fetch_env!("PATH")},
          {"MIX_ENV", "dev"},
          {"QUALITY_HOOK_LOG", Path.join(repo, "quality.log")},
          {"QUALITY_HOOK_EXIT", "0"}
        ]

    git = fn args -> System.cmd("git", args, cd: repo, env: env, stderr_to_stdout: true) end
    assert {_output, 0} = git.(["init", "--quiet"])

    %{repo: repo, env: env, git: git, installer: Path.join(repo, "scripts/install-git-hooks.sh")}
  end

  test "installs from another directory and can be installed repeatedly", context do
    for _attempt <- 1..2 do
      assert {_output, 0} =
               System.cmd(context.installer, [],
                 cd: System.tmp_dir!(),
                 env: context.env,
                 stderr_to_stdout: true
               )
    end

    assert {".githooks\n", 0} = context.git.(["config", "--local", "--get", "core.hooksPath"])
  end

  test "preserves an existing hook configuration", context do
    assert {_output, 0} = context.git.(["config", "--local", "core.hooksPath", "custom-hooks"])

    assert {output, 1} =
             System.cmd(context.installer, [],
               cd: context.repo,
               env: context.env,
               stderr_to_stdout: true
             )

    assert output =~ "Refusing to replace"
    assert {"custom-hooks\n", 0} = context.git.(["config", "--local", "--get", "core.hooksPath"])
  end

  test "refuses to install a nonexecutable hook", context do
    File.chmod!(Path.join(context.repo, ".githooks/pre-commit"), 0o644)

    assert {_output, 1} =
             System.cmd(context.installer, [], env: context.env, stderr_to_stdout: true)

    assert {_output, 1} = context.git.(["config", "--local", "--get", "core.hooksPath"])
  end

  test "an installed hook runs the full gate in the test environment before committing",
       context do
    assert {_output, 0} = System.cmd(context.installer, [], env: context.env)
    assert {_output, 0} = context.git.(["commit", "--allow-empty", "-m", "Test checkpoint"])
    assert File.read!(Path.join(context.repo, "quality.log")) == "#{context.repo}\ntest\ncheck\n"
    assert {_output, 0} = context.git.(["rev-parse", "--verify", "HEAD"])
  end

  test "a failed quality gate prevents Git from creating a commit", context do
    assert {_output, 0} = System.cmd(context.installer, [], env: context.env)
    env = List.keystore(context.env, "QUALITY_HOOK_EXIT", 0, {"QUALITY_HOOK_EXIT", "37"})

    assert {_output, status} =
             System.cmd("git", ["commit", "--allow-empty", "-m", "Rejected checkpoint"],
               cd: context.repo,
               env: env,
               stderr_to_stdout: true
             )

    assert status != 0
    assert File.read!(Path.join(context.repo, "quality.log")) == "#{context.repo}\ntest\ncheck\n"
    assert {_output, status} = context.git.(["rev-parse", "--verify", "HEAD"])
    assert status != 0
  end
end
