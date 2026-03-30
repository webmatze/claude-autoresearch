#!/bin/bash
# tests/test_pipeline.sh — end-to-end test of the full script pipeline
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

SCRIPTS_DIR="$SCRIPT_DIR/../scripts"

echo "=== Pipeline: init → run → log ==="

TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init -q
echo "hello" > app.txt
git add . && git commit -q -m "initial"

# Step 1: Init
echo "— Init session"
"$SCRIPTS_DIR/init_experiment.sh" \
  --name "Pipeline Test" \
  --metric "total_seconds" \
  --unit "s" \
  --direction "lower" \
  --jsonl "$TEST_DIR/autoresearch.jsonl" > /dev/null

assert_file_exists "$TEST_DIR/autoresearch.jsonl" "jsonl created"

# Step 2: Run baseline
echo "— Run baseline experiment"
run_output=$("$SCRIPTS_DIR/run_experiment.sh" \
  --command 'echo "METRIC total_seconds=10.5"; echo "METRIC compile_s=3.2"')

assert_contains "$run_output" '"passed":true' "baseline passed"
assert_contains "$run_output" '"total_seconds":10.5' "parsed primary metric"

# Step 3: Log baseline as keep
echo "— Log baseline"
COMMIT=$(git rev-parse --short HEAD)
log_output=$("$SCRIPTS_DIR/log_experiment.sh" \
  --commit "$COMMIT" \
  --metric 10.5 \
  --status "keep" \
  --description "baseline" \
  --metrics '{"compile_s":3.2}' \
  --jsonl "$TEST_DIR/autoresearch.jsonl")

assert_contains "$log_output" "Run #1" "first run"
assert_contains "$log_output" "keep" "status is keep"

# Step 4: Simulate improvement — run + keep
echo "— Simulate improvement"
echo "optimized" > app.txt
git add app.txt

run_output2=$("$SCRIPTS_DIR/run_experiment.sh" \
  --command 'echo "METRIC total_seconds=8.2"')
assert_contains "$run_output2" '"total_seconds":8.2' "improved metric"

COMMIT2=$(git rev-parse --short HEAD)
log_output2=$("$SCRIPTS_DIR/log_experiment.sh" \
  --commit "$COMMIT2" \
  --metric 8.2 \
  --status "keep" \
  --description "optimized parsing" \
  --jsonl "$TEST_DIR/autoresearch.jsonl")

assert_contains "$log_output2" "Run #2" "second run"

# Step 5: Simulate regression — run + discard
echo "— Simulate regression"
echo "broken" > app.txt

COMMIT3=$(git rev-parse --short HEAD)
log_output3=$("$SCRIPTS_DIR/log_experiment.sh" \
  --commit "$COMMIT3" \
  --metric 15.0 \
  --status "discard" \
  --description "tried aggressive caching — worse" \
  --jsonl "$TEST_DIR/autoresearch.jsonl")

assert_contains "$log_output3" "Run #3" "third run"
assert_contains "$log_output3" "discard" "discarded"

# Verify file was reverted
content=$(cat app.txt)
assert_eq "optimized" "$content" "file reverted after discard"

# Step 6: Verify JSONL integrity
echo "— Verify JSONL"
line_count=$(wc -l < "$TEST_DIR/autoresearch.jsonl" | tr -d ' ')
assert_eq "4" "$line_count" "4 lines: 1 config + 3 results"

# Cleanup
cd /
rm -rf "$TEST_DIR"

test_summary
