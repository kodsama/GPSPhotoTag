#!/usr/bin/env bash
#
# One-time setup: point git at the repo-tracked hooks in .githooks/ and make
# them executable. Re-runnable and idempotent.
#
#   bash tool/setup-hooks.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

git config core.hooksPath .githooks
chmod +x .githooks/*

echo "✓ git hooksPath set to .githooks and hooks made executable"
echo "  The pre-commit hook now runs format + analyze + tests on every commit."
