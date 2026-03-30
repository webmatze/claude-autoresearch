#!/bin/bash
# tests/test_init_experiment.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

SCRIPTS_DIR="$SCRIPT_DIR/../scripts"

setup_tmp() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
}

teardown_tmp() {
  cd /
  rm -rf "$TEST_DIR"
}

echo "=== init_experiment.sh ==="

# Test 1: Creates new JSONL with config header
echo "— Test: creates new jsonl with config header"
setup_tmp
output=$("$SCRIPTS_DIR/init_experiment.sh" \
  --name "Test Session" \
  --metric "total_seconds" \
  --unit "s" \
  --direction "lower" \
  --jsonl "$TEST_DIR/autoresearch.jsonl")

assert_file_exists "$TEST_DIR/autoresearch.jsonl" "jsonl file created"

line=$(cat "$TEST_DIR/autoresearch.jsonl")
assert_contains "$line" '"type":"config"' "has type config"
assert_contains "$line" '"name":"Test Session"' "has name"
assert_contains "$line" '"metric_name":"total_seconds"' "has metric_name"
assert_contains "$line" '"metric_unit":"s"' "has unit"
assert_contains "$line" '"direction":"lower"' "has direction"
assert_contains "$line" '"segment":0' "first segment is 0"
teardown_tmp

# Test 2: Increments segment on existing JSONL
echo "— Test: increments segment number"
setup_tmp
echo '{"type":"config","name":"Old","metric_name":"x","metric_unit":"","direction":"lower","segment":0,"timestamp":1000}' > "$TEST_DIR/autoresearch.jsonl"
"$SCRIPTS_DIR/init_experiment.sh" \
  --name "New Session" \
  --metric "y" \
  --direction "higher" \
  --jsonl "$TEST_DIR/autoresearch.jsonl" > /dev/null

line_count=$(wc -l < "$TEST_DIR/autoresearch.jsonl" | tr -d ' ')
assert_eq "2" "$line_count" "jsonl has 2 lines"

last_line=$(tail -1 "$TEST_DIR/autoresearch.jsonl")
assert_contains "$last_line" '"segment":1' "segment incremented to 1"
assert_contains "$last_line" '"direction":"higher"' "new direction"
teardown_tmp

# Test 3: Defaults
echo "— Test: defaults for unit and direction"
setup_tmp
"$SCRIPTS_DIR/init_experiment.sh" \
  --name "Defaults" \
  --metric "score" \
  --jsonl "$TEST_DIR/autoresearch.jsonl" > /dev/null

line=$(cat "$TEST_DIR/autoresearch.jsonl")
assert_contains "$line" '"metric_unit":""' "default unit is empty"
assert_contains "$line" '"direction":"lower"' "default direction is lower"
teardown_tmp

test_summary
