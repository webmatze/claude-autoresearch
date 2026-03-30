#!/bin/bash
# tests/test_helpers.sh — minimal test harness
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ $msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ $msg"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ $msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ $msg"
    echo "    '$needle' not found in output"
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -f "$path" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ $msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ $msg"
    echo "    file not found: $path"
  fi
}

test_summary() {
  echo ""
  echo "══ Results: $TESTS_PASSED/$TESTS_RUN passed ══"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "$TESTS_FAILED FAILED"
    exit 1
  fi
}
