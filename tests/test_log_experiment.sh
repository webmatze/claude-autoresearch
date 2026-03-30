#!/bin/bash
# tests/test_log_experiment.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

SCRIPTS_DIR="$SCRIPT_DIR/../scripts"

setup_tmp() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
  git init -q
  git commit -q --allow-empty -m "initial"
  # Write config header so log knows segment
  echo '{"type":"config","name":"Test","metric_name":"total_s","metric_unit":"s","direction":"lower","segment":0,"timestamp":1000}' > autoresearch.jsonl
}

teardown_tmp() {
  cd /
  rm -rf "$TEST_DIR"
}

echo "=== log_experiment.sh ==="

# Test 1: Log a keep result — appends to JSONL
echo "— Test: log keep result"
setup_tmp
echo "change" > test_file.txt
git add test_file.txt
COMMIT=$(git rev-parse --short HEAD)
output=$("$SCRIPTS_DIR/log_experiment.sh" \
  --commit "$COMMIT" \
  --metric 12.34 \
  --status "keep" \
  --description "baseline run" \
  --jsonl "$TEST_DIR/autoresearch.jsonl")

last_line=$(tail -1 "$TEST_DIR/autoresearch.jsonl")
assert_contains "$last_line" '"type":"result"' "has type result"
assert_contains "$last_line" '"metric":12.34' "has metric value"
assert_contains "$last_line" '"status":"keep"' "has status keep"
assert_contains "$last_line" '"segment":0' "has segment 0"
assert_contains "$output" "Run #1" "shows run number"
teardown_tmp

# Test 2: Log a discard result — reverts changes
echo "— Test: log discard reverts changes"
setup_tmp
echo "original" > test_file.txt
git add test_file.txt && git commit -q -m "add file"
echo "modified" > test_file.txt
COMMIT=$(git rev-parse --short HEAD)
"$SCRIPTS_DIR/log_experiment.sh" \
  --commit "$COMMIT" \
  --metric 15.00 \
  --status "discard" \
  --description "worse result" \
  --jsonl "$TEST_DIR/autoresearch.jsonl" > /dev/null

content=$(cat test_file.txt)
assert_eq "original" "$content" "file reverted to original"
teardown_tmp

# Test 3: Confidence scoring after 3+ results
echo "— Test: confidence score after 3 results"
setup_tmp
for i in 1 2 3; do
  echo "{\"type\":\"result\",\"metric\":$((10+i)),\"status\":\"keep\",\"segment\":0,\"timestamp\":$((1000+i))}" >> "$TEST_DIR/autoresearch.jsonl"
done
COMMIT=$(git rev-parse --short HEAD)
output=$("$SCRIPTS_DIR/log_experiment.sh" \
  --commit "$COMMIT" \
  --metric 8.0 \
  --status "keep" \
  --description "fourth run" \
  --jsonl "$TEST_DIR/autoresearch.jsonl")

last_line=$(tail -1 "$TEST_DIR/autoresearch.jsonl")
assert_contains "$last_line" '"confidence":' "has confidence field"
teardown_tmp

# Test 4: Secondary metrics
echo "— Test: secondary metrics stored"
setup_tmp
COMMIT=$(git rev-parse --short HEAD)
output=$("$SCRIPTS_DIR/log_experiment.sh" \
  --commit "$COMMIT" \
  --metric 12.0 \
  --status "discard" \
  --description "with secondaries" \
  --metrics '{"compile_s":3.2,"render_s":8.8}' \
  --jsonl "$TEST_DIR/autoresearch.jsonl")

last_line=$(tail -1 "$TEST_DIR/autoresearch.jsonl")
assert_contains "$last_line" '"compile_s":3.2' "has compile_s"
assert_contains "$last_line" '"render_s":8.8' "has render_s"
teardown_tmp

# Test 5: ASI stored
echo "— Test: ASI data stored"
setup_tmp
COMMIT=$(git rev-parse --short HEAD)
output=$("$SCRIPTS_DIR/log_experiment.sh" \
  --commit "$COMMIT" \
  --metric 10.0 \
  --status "discard" \
  --description "with asi" \
  --asi '{"bottleneck":"parsing","tried":"parallel"}' \
  --jsonl "$TEST_DIR/autoresearch.jsonl")

last_line=$(tail -1 "$TEST_DIR/autoresearch.jsonl")
assert_contains "$last_line" '"bottleneck":"parsing"' "has ASI data"
teardown_tmp

# Test 6: Discard preserves autoresearch files
echo "— Test: discard preserves autoresearch files"
setup_tmp
echo "session doc" > autoresearch.md
echo "benchmark" > autoresearch.sh
echo "modified code" > app.js
git add -A && git commit -q -m "changes"
echo "new experiment" > app.js
COMMIT=$(git rev-parse --short HEAD)
"$SCRIPTS_DIR/log_experiment.sh" \
  --commit "$COMMIT" \
  --metric 20.0 \
  --status "discard" \
  --description "bad result" \
  --jsonl "$TEST_DIR/autoresearch.jsonl" > /dev/null

assert_file_exists "$TEST_DIR/autoresearch.md" "autoresearch.md preserved"
assert_file_exists "$TEST_DIR/autoresearch.sh" "autoresearch.sh preserved"
assert_file_exists "$TEST_DIR/autoresearch.jsonl" "autoresearch.jsonl preserved"
teardown_tmp

test_summary
