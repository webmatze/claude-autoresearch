#!/bin/bash
# tests/test_finalize.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

SCRIPTS_DIR="$SCRIPT_DIR/../skills/autoresearch-finalize/scripts"

setup_repo() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
  git init -q
  git checkout -b main 2>/dev/null || true
  echo "base" > base.txt
  git add . && git commit -q -m "initial"
  BASE_COMMIT=$(git rev-parse HEAD)

  # Create autoresearch branch with two changes in different files
  git checkout -b autoresearch/test-session
  echo "change1" > file_a.txt
  git add . && git commit -q -m "autoresearch: optimize file A"
  COMMIT_A=$(git rev-parse HEAD)

  echo "change2" > file_b.txt
  git add . && git commit -q -m "autoresearch: optimize file B"
  COMMIT_B=$(git rev-parse HEAD)
}

teardown_repo() {
  cd /
  rm -rf "$TEST_DIR"
}

echo "=== finalize.sh ==="

# Test 1: Creates independent branches from groups
echo "— Test: creates branches from groups"
setup_repo

GROUPS_FILE=$(mktemp)
cat > "$GROUPS_FILE" << GROUPSEOF
{
  "base": "$BASE_COMMIT",
  "trunk": "main",
  "final_tree": "$COMMIT_B",
  "goal": "test-opt",
  "groups": [
    {
      "title": "Optimize file A",
      "body": "Changed file A.\n\nMetric: 10s → 8s (-20%)",
      "last_commit": "$COMMIT_A",
      "slug": "file-a"
    },
    {
      "title": "Optimize file B",
      "body": "Changed file B.\n\nMetric: 8s → 6s (-25%)",
      "last_commit": "$COMMIT_B",
      "slug": "file-b"
    }
  ]
}
GROUPSEOF

output=$(bash "$SCRIPTS_DIR/finalize.sh" "$GROUPS_FILE" 2>&1)

assert_contains "$output" "Preflight passed" "preflight passed"
assert_contains "$output" "autoresearch/test-opt/01-file-a" "branch A created"
assert_contains "$output" "autoresearch/test-opt/02-file-b" "branch B created"
assert_contains "$output" "All checks passed" "verification passed"

# Verify branch A only has file_a.txt
git checkout autoresearch/test-opt/01-file-a 2>/dev/null
assert_file_exists "$TEST_DIR/file_a.txt" "branch A has file_a"
if [ -f "$TEST_DIR/file_b.txt" ]; then
  echo "  ✗ branch A should NOT have file_b.txt"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  ✓ branch A does not have file_b.txt"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi
TESTS_RUN=$((TESTS_RUN + 1))

rm -f "$GROUPS_FILE"
teardown_repo

# Test 2: Fails on overlapping files
echo "— Test: fails on overlapping files"
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init -q
git checkout -b main 2>/dev/null || true
echo "base" > shared.txt
git add . && git commit -q -m "initial"
BASE_COMMIT=$(git rev-parse HEAD)

git checkout -b autoresearch/overlap
echo "v1" > shared.txt
git add . && git commit -q -m "change 1"
COMMIT1=$(git rev-parse HEAD)
echo "v2" > shared.txt
git add . && git commit -q -m "change 2"
COMMIT2=$(git rev-parse HEAD)

GROUPS_FILE=$(mktemp)
cat > "$GROUPS_FILE" << GROUPSEOF
{
  "base": "$BASE_COMMIT",
  "trunk": "main",
  "final_tree": "$COMMIT2",
  "goal": "overlap-test",
  "groups": [
    {
      "title": "Group 1",
      "body": "first",
      "last_commit": "$COMMIT1",
      "slug": "g1"
    },
    {
      "title": "Group 2",
      "body": "second",
      "last_commit": "$COMMIT2",
      "slug": "g2"
    }
  ]
}
GROUPSEOF

output=$(bash "$SCRIPTS_DIR/finalize.sh" "$GROUPS_FILE" 2>&1 || true)
assert_contains "$output" "appears in multiple groups" "detects overlap"

rm -f "$GROUPS_FILE"
cd /
rm -rf "$TEST_DIR"

test_summary
