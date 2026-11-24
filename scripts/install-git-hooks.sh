#!/usr/bin/env bash
# Enable the repository's versioned Git hooks for this clone.
#
#   ./scripts/install-git-hooks.sh
#
# The pre-commit hook scans staged changes for secrets with gitleaks. It is
# wired up through core.hooksPath so it also runs when commits are made from
# Xcode, VS Code, or another Git GUI.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .githooks/pre-commit ]]; then
  echo "error: .githooks/pre-commit not found in $ROOT" >&2
  exit 1
fi
chmod +x .githooks/pre-commit

git config core.hooksPath .githooks

# Older clones installed a copy directly in .git/hooks. It is ignored once
# core.hooksPath is set, but remove the stale copy so it cannot be revived by
# unsetting core.hooksPath later.
LEGACY="$(git rev-parse --absolute-git-dir)/hooks/pre-commit"
if [[ -f "$LEGACY" ]] && ! cmp -s "$LEGACY" .githooks/pre-commit; then
  rm -f "$LEGACY"
  printf 'removed legacy hook: %s\n' "$LEGACY"
fi

# The hook itself searches Homebrew's prefix, so this is only a hint.
if ! command -v gitleaks >/dev/null 2>&1; then
  printf 'note: gitleaks is not on PATH; install it with: brew install gitleaks\n' >&2
  printf '      (the hook also checks Homebrew and /usr/local/bin at commit time)\n' >&2
fi

printf '✓ Git hooks enabled (core.hooksPath=%s)\n' "$(git config --get core.hooksPath)"
