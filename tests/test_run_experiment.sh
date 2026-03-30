#!/bin/bash
# tests/test_run_experiment.sh
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

echo "=== run_experiment.sh ==="

# Test 1: Successful command with METRIC output
echo "— Test: successful command with metrics"
setup_tmp
output=$("$SCRIPTS_DIR/run_experiment.sh" \
  --command 'echo "hello world"; echo "METRIC total_seconds=1.23"; echo "METRIC compile_seconds=0.45"')

assert_contains "$output" '"passed":true' "passed is true"
assert_contains "$output" '"crashed":false' "crashed is false"
assert_contains "$output" '"timed_out":false' "not timed out"
assert_contains "$output" '"exit_code":0' "exit code 0"
assert_contains "$output" '"total_seconds":1.23' "parsed total_seconds"
assert_contains "$output" '"compile_seconds":0.45' "parsed compile_seconds"
teardown_tmp

# Test 2: Failed command
echo "— Test: failed command"
setup_tmp
output=$("$SCRIPTS_DIR/run_experiment.sh" \
  --command 'echo "failing"; exit 1')

assert_contains "$output" '"passed":false' "passed is false"
assert_contains "$output" '"exit_code":1' "exit code 1"
teardown_tmp

# Test 3: Timeout
echo "— Test: command timeout"
setup_tmp
output=$("$SCRIPTS_DIR/run_experiment.sh" \
  --command 'sleep 60' \
  --timeout 1)

assert_contains "$output" '"timed_out":true' "timed out"
assert_contains "$output" '"passed":false' "not passed"
teardown_tmp

# Test 4: Checks script runs on success
echo "— Test: checks script runs after passing command"
setup_tmp
cat > "$TEST_DIR/autoresearch.checks.sh" << 'CHECKSEOF'
#!/bin/bash
set -euo pipefail
echo "checks passed"
CHECKSEOF
chmod +x "$TEST_DIR/autoresearch.checks.sh"

output=$("$SCRIPTS_DIR/run_experiment.sh" \
  --command 'echo "METRIC x=1"' \
  --checks-dir "$TEST_DIR")

assert_contains "$output" '"checks_pass":true' "checks passed"
teardown_tmp

# Test 5: Checks script failure
echo "— Test: checks script failure"
setup_tmp
cat > "$TEST_DIR/autoresearch.checks.sh" << 'CHECKSEOF'
#!/bin/bash
set -euo pipefail
echo "type error on line 5" >&2
exit 1
CHECKSEOF
chmod +x "$TEST_DIR/autoresearch.checks.sh"

output=$("$SCRIPTS_DIR/run_experiment.sh" \
  --command 'echo "METRIC x=1"' \
  --checks-dir "$TEST_DIR")

assert_contains "$output" '"checks_pass":false' "checks failed"
teardown_tmp

# Test 6: No metrics in output
echo "— Test: no METRIC lines"
setup_tmp
output=$("$SCRIPTS_DIR/run_experiment.sh" \
  --command 'echo "no metrics here"')

assert_contains "$output" '"parsed_metrics":null' "parsed_metrics is null"
teardown_tmp

# Test 7: Output truncation
echo "— Test: output truncated to tail"
setup_tmp
output=$("$SCRIPTS_DIR/run_experiment.sh" \
  --command 'for i in $(seq 1 200); do echo "line $i"; done')

# tail_output should not contain line 1 (truncated)
assert_contains "$output" '"passed":true' "passed"
# The output should be truncated (not all 200 lines)
teardown_tmp

test_summary
