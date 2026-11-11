#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
current_hooks_path="$(git -C "$repo_root" config --get core.hooksPath || true)"

if [[ -n "$current_hooks_path" && "$current_hooks_path" != '.githooks' ]]; then
  printf 'Refusing to replace existing core.hooksPath: %s\n' "$current_hooks_path" >&2
  printf 'Integrate the project pre-commit hook with your existing hooks first.\n' >&2
  exit 1
fi

if [[ ! -x "$repo_root/.githooks/pre-commit" ]]; then
  printf 'Project pre-commit hook is missing or not executable.\n' >&2
  exit 1
fi

git -C "$repo_root" config --local core.hooksPath .githooks
printf 'Installed project Git hooks. Commits now require mix check to pass.\n'
