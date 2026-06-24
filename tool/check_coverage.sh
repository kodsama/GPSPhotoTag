#!/usr/bin/env bash
#
# check_coverage.sh <lcov-file> <min-percent>
#
# Parses an lcov.info file, computes line coverage as (sum of LH) / (sum of LF),
# prints the percentage, and exits non-zero if it is below <min-percent>.
#
#   LF: <number of instrumented lines in a file>
#   LH: <number of those lines that were hit>
#
# Example:
#   bash tool/check_coverage.sh packages/engine/coverage/lcov.info 90

set -euo pipefail

LCOV_FILE="${1:?usage: check_coverage.sh <lcov-file> <min-percent>}"
MIN_PERCENT="${2:?usage: check_coverage.sh <lcov-file> <min-percent>}"

if [[ ! -f "$LCOV_FILE" ]]; then
  echo "✗ coverage file not found: $LCOV_FILE" >&2
  exit 1
fi

# Sum LF (found) and LH (hit) across every record in the file.
read -r FOUND HIT < <(
  awk -F: '
    /^LF:/ { found += $2 }
    /^LH:/ { hit   += $2 }
    END    { printf "%d %d\n", found, hit }
  ' "$LCOV_FILE"
)

if [[ "$FOUND" -eq 0 ]]; then
  echo "✗ no instrumented lines (LF total is 0) in $LCOV_FILE" >&2
  exit 1
fi

# Percentage with two decimals, computed in awk to avoid bc dependency.
PERCENT="$(awk -v h="$HIT" -v f="$FOUND" 'BEGIN { printf "%.2f", (h / f) * 100 }')"

echo "Coverage for $LCOV_FILE: ${PERCENT}% (${HIT}/${FOUND} lines) — gate ≥ ${MIN_PERCENT}%"

# Compare with awk (handles decimals; exit 1 if below min).
if awk -v p="$PERCENT" -v m="$MIN_PERCENT" 'BEGIN { exit !(p < m) }'; then
  echo "✗ coverage ${PERCENT}% is below the required ${MIN_PERCENT}%" >&2
  exit 1
fi

echo "✓ coverage gate passed (${PERCENT}% ≥ ${MIN_PERCENT}%)"
