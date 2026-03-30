#!/bin/bash
# tests/run_all.sh — Run all test suites
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "═══════════════════════════════════"
echo "  claude-autoresearch test suite"
echo "═══════════════════════════════════"
echo ""

FAILURES=0

for test_file in "$SCRIPT_DIR"/test_*.sh; do
  echo ""
  echo "━━━ $(basename "$test_file") ━━━"
  if bash "$test_file"; then
    echo "→ PASSED"
  else
    echo "→ FAILED"
    FAILURES=$((FAILURES + 1))
  fi
  echo ""
done

echo "═══════════════════════════════════"
if [ "$FAILURES" -gt 0 ]; then
  echo "  $FAILURES test suite(s) FAILED"
  exit 1
else
  echo "  All test suites passed!"
fi
