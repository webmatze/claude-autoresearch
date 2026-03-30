# Claude Autoresearch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an autonomous experiment loop for Claude Code — two skills backed by four bash helper scripts that let Claude run optimization loops (edit, benchmark, keep/revert, repeat).

**Architecture:** Skills (markdown prompts) instruct Claude on behavior; helper scripts (bash) handle mechanical work (timing, metric parsing, JSONL logging, confidence scoring, git operations). Session state lives in per-project files (autoresearch.md, autoresearch.jsonl, autoresearch.sh).

**Tech Stack:** Bash 4.0+, awk, git, jq (with python3 fallback for finalize.sh)

---

## File Structure

```
claude-autoresearch/
├── skills/
│   ├── autoresearch/
│   │   └── SKILL.md              # /autoresearch skill — setup, run, resume loop
│   └── autoresearch-finalize/
│       └── SKILL.md              # /autoresearch-finalize skill — clean branches
├── scripts/
│   ├── init_experiment.sh        # Session config → JSONL header
│   ├── run_experiment.sh         # Run + time + parse metrics + optional checks
│   ├── log_experiment.sh         # Record result, confidence scoring, git commit/revert
│   └── finalize.sh              # Create independent branches from kept experiments
├── tests/
│   ├── test_init_experiment.sh   # Tests for init_experiment.sh
│   ├── test_run_experiment.sh    # Tests for run_experiment.sh
│   ├── test_log_experiment.sh    # Tests for log_experiment.sh
│   └── test_finalize.sh         # Tests for finalize.sh
└── README.md
```

Each script is a standalone bash executable. Each skill is a SKILL.md with YAML frontmatter. Tests use plain bash assertions with a minimal test harness.

---

### Task 1: Test Harness and init_experiment.sh

**Files:**
- Create: `tests/test_helpers.sh`
- Create: `tests/test_init_experiment.sh`
- Create: `scripts/init_experiment.sh`

- [ ] **Step 1: Write the test helper**

Create a minimal bash test harness used by all test files.

```bash
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
```

- [ ] **Step 2: Write failing tests for init_experiment.sh**

```bash
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

line_count=$(wc -l < "$TEST_DIR/autoresearch.jsonl")
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
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/test_init_experiment.sh`
Expected: FAIL — scripts/init_experiment.sh not found

- [ ] **Step 4: Implement init_experiment.sh**

```bash
#!/bin/bash
# scripts/init_experiment.sh — Initialize an autoresearch session
set -euo pipefail

# Defaults
NAME=""
METRIC=""
UNIT=""
DIRECTION="lower"
JSONL="autoresearch.jsonl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --metric) METRIC="$2"; shift 2 ;;
    --unit) UNIT="$2"; shift 2 ;;
    --direction) DIRECTION="$2"; shift 2 ;;
    --jsonl) JSONL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$NAME" ] || [ -z "$METRIC" ]; then
  echo "Usage: init_experiment.sh --name <name> --metric <metric_name> [--unit <unit>] [--direction lower|higher] [--jsonl <path>]" >&2
  exit 1
fi

if [ "$DIRECTION" != "lower" ] && [ "$DIRECTION" != "higher" ]; then
  echo "Error: --direction must be 'lower' or 'higher'" >&2
  exit 1
fi

# Determine segment number
SEGMENT=0
if [ -f "$JSONL" ]; then
  # Find highest segment number in existing config lines
  LAST_SEGMENT=$(grep '"type":"config"' "$JSONL" | awk -F'"segment":' '{print $2}' | awk -F'[,}]' '{print $1}' | sort -n | tail -1)
  if [ -n "$LAST_SEGMENT" ]; then
    SEGMENT=$((LAST_SEGMENT + 1))
  fi
fi

TIMESTAMP=$(date +%s)

# Write config line (no jq dependency — manual JSON)
echo "{\"type\":\"config\",\"name\":\"$NAME\",\"metric_name\":\"$METRIC\",\"metric_unit\":\"$UNIT\",\"direction\":\"$DIRECTION\",\"segment\":$SEGMENT,\"timestamp\":$TIMESTAMP}" >> "$JSONL"

echo "Initialized autoresearch session:"
echo "  Name:      $NAME"
echo "  Metric:    $METRIC ($UNIT, $DIRECTION is better)"
echo "  Segment:   $SEGMENT"
echo "  JSONL:     $JSONL"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test_init_experiment.sh`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add tests/test_helpers.sh tests/test_init_experiment.sh scripts/init_experiment.sh
git commit -m "feat: add init_experiment.sh with test harness"
```

---

### Task 2: run_experiment.sh

**Files:**
- Create: `tests/test_run_experiment.sh`
- Create: `scripts/run_experiment.sh`

- [ ] **Step 1: Write failing tests for run_experiment.sh**

```bash
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
tail_output=$(echo "$output" | grep -o '"tail_output":"[^"]*"')
assert_contains "$output" '"passed":true' "passed"
# The output should be truncated (not all 200 lines)
teardown_tmp

test_summary
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_run_experiment.sh`
Expected: FAIL — scripts/run_experiment.sh not found

- [ ] **Step 3: Implement run_experiment.sh**

```bash
#!/bin/bash
# scripts/run_experiment.sh — Run a command, time it, parse metrics, run checks
set -euo pipefail

COMMAND=""
TIMEOUT=600
CHECKS_TIMEOUT=300
CHECKS_DIR="."
MAX_TAIL_LINES=80

while [[ $# -gt 0 ]]; do
  case "$1" in
    --command) COMMAND="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --checks-timeout) CHECKS_TIMEOUT="$2"; shift 2 ;;
    --checks-dir) CHECKS_DIR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$COMMAND" ]; then
  echo "Usage: run_experiment.sh --command <cmd> [--timeout <s>] [--checks-timeout <s>] [--checks-dir <dir>]" >&2
  exit 1
fi

TMPOUT=$(mktemp)
trap 'rm -f "$TMPOUT"' EXIT

# Run command with timeout
START_TIME=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
EXIT_CODE=0
TIMED_OUT=false

if command -v timeout &>/dev/null; then
  timeout "$TIMEOUT" bash -c "$COMMAND" > "$TMPOUT" 2>&1 || EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 124 ]; then
    TIMED_OUT=true
  fi
else
  # macOS fallback using perl
  perl -e "
    alarm $TIMEOUT;
    \$SIG{ALRM} = sub { kill 'TERM', \$pid; exit 124 };
    \$pid = fork();
    if (\$pid == 0) { exec('bash', '-c', '$COMMAND'); }
    waitpid(\$pid, 0);
    exit (\$? >> 8);
  " > "$TMPOUT" 2>&1 || EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 124 ]; then
    TIMED_OUT=true
  fi
fi

END_TIME=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
DURATION_NS=$((END_TIME - START_TIME))
DURATION_S=$(awk "BEGIN {printf \"%.2f\", $DURATION_NS / 1000000000}")

PASSED=false
CRASHED=false
if [ "$TIMED_OUT" = "true" ]; then
  CRASHED=true
elif [ "$EXIT_CODE" -eq 0 ]; then
  PASSED=true
elif [ "$EXIT_CODE" -gt 128 ]; then
  CRASHED=true
fi

# Parse METRIC lines
METRICS_JSON="null"
HAS_METRICS=false
METRIC_PAIRS=""
while IFS= read -r metric_line; do
  name=$(echo "$metric_line" | sed 's/^METRIC //' | cut -d= -f1)
  value=$(echo "$metric_line" | sed 's/^METRIC //' | cut -d= -f2)
  if [ -n "$name" ] && [ -n "$value" ]; then
    if [ "$HAS_METRICS" = "true" ]; then
      METRIC_PAIRS="$METRIC_PAIRS,"
    fi
    METRIC_PAIRS="$METRIC_PAIRS\"$name\":$value"
    HAS_METRICS=true
  fi
done < <(grep '^METRIC ' "$TMPOUT" 2>/dev/null || true)

if [ "$HAS_METRICS" = "true" ]; then
  METRICS_JSON="{$METRIC_PAIRS}"
fi

# Truncate output to last N lines
TAIL_OUTPUT=$(tail -n "$MAX_TAIL_LINES" "$TMPOUT" | head -c 4096)
# Escape for JSON
TAIL_OUTPUT_ESCAPED=$(echo "$TAIL_OUTPUT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null | sed 's/^"//;s/"$//')

# Run checks if command passed and checks file exists
CHECKS_PASS="null"
CHECKS_TIMED_OUT=false
CHECKS_OUTPUT=""
CHECKS_DURATION=0

CHECKS_FILE="$CHECKS_DIR/autoresearch.checks.sh"
if [ "$PASSED" = "true" ] && [ -x "$CHECKS_FILE" ]; then
  CHECKS_TMPOUT=$(mktemp)
  CHECKS_START=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
  CHECKS_EXIT=0

  if command -v timeout &>/dev/null; then
    timeout "$CHECKS_TIMEOUT" bash "$CHECKS_FILE" > "$CHECKS_TMPOUT" 2>&1 || CHECKS_EXIT=$?
  else
    bash "$CHECKS_FILE" > "$CHECKS_TMPOUT" 2>&1 || CHECKS_EXIT=$?
  fi

  CHECKS_END=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
  CHECKS_DURATION_NS=$((CHECKS_END - CHECKS_START))
  CHECKS_DURATION=$(awk "BEGIN {printf \"%.2f\", $CHECKS_DURATION_NS / 1000000000}")

  if [ "$CHECKS_EXIT" -eq 124 ]; then
    CHECKS_TIMED_OUT=true
    CHECKS_PASS=false
  elif [ "$CHECKS_EXIT" -eq 0 ]; then
    CHECKS_PASS=true
  else
    CHECKS_PASS=false
  fi

  CHECKS_OUTPUT=$(tail -n "$MAX_TAIL_LINES" "$CHECKS_TMPOUT" | head -c 4096)
  CHECKS_OUTPUT=$(echo "$CHECKS_OUTPUT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null | sed 's/^"//;s/"$//')
  rm -f "$CHECKS_TMPOUT"
fi

# Output JSON
cat << JSONEOF
{"exit_code":$EXIT_CODE,"duration_seconds":$DURATION_S,"passed":$PASSED,"crashed":$CRASHED,"timed_out":$TIMED_OUT,"parsed_metrics":$METRICS_JSON,"checks_pass":$CHECKS_PASS,"checks_timed_out":$CHECKS_TIMED_OUT,"checks_output":"$CHECKS_OUTPUT","checks_duration":$CHECKS_DURATION,"tail_output":"$TAIL_OUTPUT_ESCAPED"}
JSONEOF
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_run_experiment.sh`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add tests/test_run_experiment.sh scripts/run_experiment.sh
git commit -m "feat: add run_experiment.sh — command runner with metric parsing and checks"
```

---

### Task 3: log_experiment.sh

**Files:**
- Create: `tests/test_log_experiment.sh`
- Create: `scripts/log_experiment.sh`

- [ ] **Step 1: Write failing tests for log_experiment.sh**

```bash
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
# Create a file to commit
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
# Add 3 result lines manually
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
# Should have a non-null confidence value
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_log_experiment.sh`
Expected: FAIL — scripts/log_experiment.sh not found

- [ ] **Step 3: Implement log_experiment.sh**

```bash
#!/bin/bash
# scripts/log_experiment.sh — Record experiment result, compute confidence, git ops
set -euo pipefail

COMMIT=""
METRIC=""
STATUS=""
DESCRIPTION=""
METRICS="{}"
ASI="{}"
JSONL="autoresearch.jsonl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit) COMMIT="$2"; shift 2 ;;
    --metric) METRIC="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --metrics) METRICS="$2"; shift 2 ;;
    --asi) ASI="$2"; shift 2 ;;
    --jsonl) JSONL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$COMMIT" ] || [ -z "$METRIC" ] || [ -z "$STATUS" ] || [ -z "$DESCRIPTION" ]; then
  echo "Usage: log_experiment.sh --commit <hash> --metric <value> --status <keep|discard|crash|checks_failed> --description <text> [--metrics <json>] [--asi <json>] [--jsonl <path>]" >&2
  exit 1
fi

case "$STATUS" in
  keep|discard|crash|checks_failed) ;;
  *) echo "Error: --status must be keep, discard, crash, or checks_failed" >&2; exit 1 ;;
esac

# Read current segment from last config line
SEGMENT=0
if [ -f "$JSONL" ]; then
  LAST_CONFIG_SEGMENT=$(grep '"type":"config"' "$JSONL" | tail -1 | awk -F'"segment":' '{print $2}' | awk -F'[,}]' '{print $1}')
  if [ -n "$LAST_CONFIG_SEGMENT" ]; then
    SEGMENT=$LAST_CONFIG_SEGMENT
  fi
fi

# Read config for direction and baseline
DIRECTION="lower"
if [ -f "$JSONL" ]; then
  DIR_VAL=$(grep '"type":"config"' "$JSONL" | tail -1 | awk -F'"direction":"' '{print $2}' | awk -F'"' '{print $1}')
  if [ -n "$DIR_VAL" ]; then
    DIRECTION=$DIR_VAL
  fi
fi

# Count existing results in current segment
RUN_NUMBER=1
if [ -f "$JSONL" ]; then
  EXISTING=$(grep '"type":"result"' "$JSONL" | grep "\"segment\":$SEGMENT" | wc -l | tr -d ' ')
  RUN_NUMBER=$((EXISTING + 1))
fi

# Collect metric values from current segment for confidence scoring
CONFIDENCE="null"
if [ -f "$JSONL" ]; then
  METRIC_VALUES=$(grep '"type":"result"' "$JSONL" | grep "\"segment\":$SEGMENT" | awk -F'"metric":' '{print $2}' | awk -F'[,}]' '{print $1}')
  # Add current metric
  ALL_VALUES=$(printf "%s\n%s" "$METRIC_VALUES" "$METRIC" | grep -v '^$')
  VALUE_COUNT=$(echo "$ALL_VALUES" | wc -l | tr -d ' ')

  if [ "$VALUE_COUNT" -ge 3 ]; then
    # Get baseline (first result in segment)
    BASELINE=$(grep '"type":"result"' "$JSONL" | grep "\"segment\":$SEGMENT" | head -1 | awk -F'"metric":' '{print $2}' | awk -F'[,}]' '{print $1}')

    CONFIDENCE=$(echo "$ALL_VALUES" | awk -v baseline="$BASELINE" -v direction="$DIRECTION" '
    BEGIN { n=0 }
    { vals[n++] = $1+0 }
    END {
      # Sort values
      for (i=0; i<n; i++)
        for (j=i+1; j<n; j++)
          if (vals[i] > vals[j]) { t=vals[i]; vals[i]=vals[j]; vals[j]=t }

      # Median
      if (n % 2 == 0) median = (vals[n/2-1] + vals[n/2]) / 2
      else median = vals[int(n/2)]

      # MAD
      for (i=0; i<n; i++) {
        dev = vals[i] - median
        if (dev < 0) dev = -dev
        devs[i] = dev
      }
      # Sort devs
      for (i=0; i<n; i++)
        for (j=i+1; j<n; j++)
          if (devs[i] > devs[j]) { t=devs[i]; devs[i]=devs[j]; devs[j]=t }

      if (n % 2 == 0) mad = (devs[n/2-1] + devs[n/2]) / 2
      else mad = devs[int(n/2)]

      if (mad == 0) { printf "null"; exit }

      # Best improvement from baseline
      if (direction == "lower") {
        best = vals[0]
        improvement = baseline - best
      } else {
        best = vals[n-1]
        improvement = best - baseline
      }
      if (improvement < 0) improvement = -improvement

      conf = improvement / mad
      printf "%.1f", conf
    }')
  fi
fi

TIMESTAMP=$(date +%s)

# Escape description for JSON
DESC_ESCAPED=$(echo "$DESCRIPTION" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null | sed 's/^"//;s/"$//')

# Append result to JSONL
echo "{\"type\":\"result\",\"commit\":\"$COMMIT\",\"metric\":$METRIC,\"metrics\":$METRICS,\"status\":\"$STATUS\",\"description\":\"$DESC_ESCAPED\",\"timestamp\":$TIMESTAMP,\"segment\":$SEGMENT,\"confidence\":$CONFIDENCE,\"asi\":$ASI}" >> "$JSONL"

# Git operations
if [ "$STATUS" = "keep" ]; then
  git add -A
  git commit -m "autoresearch: $DESCRIPTION" --quiet 2>/dev/null || true
else
  # Save autoresearch files
  TMPDIR_SAVE=$(mktemp -d)
  for f in autoresearch.*; do
    if [ -f "$f" ]; then
      cp "$f" "$TMPDIR_SAVE/"
    fi
  done

  # Revert all changes
  git checkout -- . 2>/dev/null || true
  git clean -fd --quiet 2>/dev/null || true

  # Restore autoresearch files
  for f in "$TMPDIR_SAVE"/autoresearch.*; do
    if [ -f "$f" ]; then
      cp "$f" .
    fi
  done
  rm -rf "$TMPDIR_SAVE"
fi

# Get baseline and compute delta for display
BASELINE_VAL=""
DELTA_PCT=""
if [ -f "$JSONL" ]; then
  BASELINE_VAL=$(grep '"type":"result"' "$JSONL" | grep "\"segment\":$SEGMENT" | head -1 | awk -F'"metric":' '{print $2}' | awk -F'[,}]' '{print $1}')
  if [ -n "$BASELINE_VAL" ] && [ "$BASELINE_VAL" != "0" ]; then
    DELTA_PCT=$(awk "BEGIN {printf \"%.1f\", (($METRIC - $BASELINE_VAL) / $BASELINE_VAL) * 100}")
  fi
fi

# Count totals
TOTAL_RUNS=$RUN_NUMBER
KEPT=$(grep '"type":"result"' "$JSONL" | grep "\"segment\":$SEGMENT" | grep '"status":"keep"' | wc -l | tr -d ' ')

# Print summary
echo ""
echo "══ Run #$RUN_NUMBER ══"
echo "Status: $STATUS"
if [ -n "$BASELINE_VAL" ] && [ -n "$DELTA_PCT" ]; then
  echo "Metric: $METRIC (baseline: $BASELINE_VAL, ${DELTA_PCT}%)"
else
  echo "Metric: $METRIC"
fi
if [ "$CONFIDENCE" != "null" ]; then
  if awk "BEGIN {exit ($CONFIDENCE >= 2.0) ? 0 : 1}" 2>/dev/null; then
    echo "Confidence: ${CONFIDENCE}x (likely real)"
  elif awk "BEGIN {exit ($CONFIDENCE >= 1.0) ? 0 : 1}" 2>/dev/null; then
    echo "Confidence: ${CONFIDENCE}x (marginal)"
  else
    echo "Confidence: ${CONFIDENCE}x (within noise)"
  fi
fi
echo "Session: $TOTAL_RUNS runs, $KEPT kept"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_log_experiment.sh`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add tests/test_log_experiment.sh scripts/log_experiment.sh
git commit -m "feat: add log_experiment.sh — result logging with MAD confidence scoring"
```

---

### Task 4: End-to-End Script Pipeline Test

**Files:**
- Create: `tests/test_pipeline.sh`

- [ ] **Step 1: Write end-to-end pipeline test**

This test runs init → run → log in sequence to verify scripts work together.

```bash
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
line_count=$(wc -l < "$TEST_DIR/autoresearch.jsonl")
assert_eq "4" "$line_count" "4 lines: 1 config + 3 results"

# Cleanup
cd /
rm -rf "$TEST_DIR"

test_summary
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test_pipeline.sh`
Expected: All tests pass (scripts from previous tasks must be working)

- [ ] **Step 3: Commit**

```bash
git add tests/test_pipeline.sh
git commit -m "test: add end-to-end pipeline test for init → run → log"
```

---

### Task 5: finalize.sh

**Files:**
- Create: `scripts/finalize.sh`
- Create: `tests/test_finalize.sh`

- [ ] **Step 1: Write failing tests for finalize.sh**

```bash
#!/bin/bash
# tests/test_finalize.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

SCRIPTS_DIR="$SCRIPT_DIR/../scripts"

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_finalize.sh`
Expected: FAIL — scripts/finalize.sh not found

- [ ] **Step 3: Implement finalize.sh**

Port the finalize.sh from the pi-autoresearch repo with one key change: replace `node -e` JSON parsing with `jq` (primary) or `python3 -c` (fallback).

The implementation is the full pi finalize.sh script with the JSON parsing section replaced:

```bash
#!/usr/bin/env bash
set -euo pipefail

# autoresearch-finalize — creates independent branches from an autoresearch session
# Ported from pi-autoresearch, adapted for Claude Code (jq instead of node)
#
# Usage: finalize.sh <groups.json>

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

DATA_DIR=""
ORIG_BRANCH=""
TRUNK=""
BASE=""
FINAL_TREE=""
GOAL=""
GROUP_COUNT=""
STASHED=false
CREATED_BRANCHES=()
declare -a GROUP_BRANCH

warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
info() { echo -e "${GREEN}$1${NC}"; }
cleanup_data() { if [ -d "${DATA_DIR:-}" ]; then rm -rf "$DATA_DIR"; fi; }
fail() { cleanup_data; echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }

is_session_file() {
  local base
  base=$(basename "$1")
  case "$base" in autoresearch.*) return 0;; *) return 1;; esac
}

# --- Parse (jq with python3 fallback) ---

parse_groups() {
  local groups_file="$1"
  [ -f "$groups_file" ] || fail "$groups_file not found"

  DATA_DIR=$(mktemp -d)

  if command -v jq &>/dev/null; then
    jq -r '.base' "$groups_file" > "$DATA_DIR/base"
    jq -r '.trunk // "main"' "$groups_file" > "$DATA_DIR/trunk"
    jq -r '.final_tree' "$groups_file" > "$DATA_DIR/final_tree"
    jq -r '.goal' "$groups_file" > "$DATA_DIR/goal"
    jq -r '.groups | length' "$groups_file" > "$DATA_DIR/count"
    local count
    count=$(cat "$DATA_DIR/count")
    for ((i=0; i<count; i++)); do
      jq -r ".groups[$i].title" "$groups_file" > "$DATA_DIR/$i.title"
      jq -r ".groups[$i].body" "$groups_file" > "$DATA_DIR/$i.body"
      jq -r ".groups[$i].last_commit" "$groups_file" > "$DATA_DIR/$i.last_commit"
      jq -r ".groups[$i].slug" "$groups_file" > "$DATA_DIR/$i.slug"
    done
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json, os
config = json.load(open('$groups_file'))
out = '$DATA_DIR'
open(f'{out}/base','w').write(config['base'])
open(f'{out}/trunk','w').write(config.get('trunk','main'))
open(f'{out}/final_tree','w').write(config['final_tree'])
open(f'{out}/goal','w').write(config['goal'])
open(f'{out}/count','w').write(str(len(config['groups'])))
for i, g in enumerate(config['groups']):
    open(f'{out}/{i}.title','w').write(g['title'])
    open(f'{out}/{i}.body','w').write(g['body'])
    open(f'{out}/{i}.last_commit','w').write(g['last_commit'])
    open(f'{out}/{i}.slug','w').write(g['slug'])
" || fail "Failed to parse $groups_file"
  else
    fail "Neither jq nor python3 found. Install one of them."
  fi

  BASE=$(cat "$DATA_DIR/base")
  TRUNK=$(cat "$DATA_DIR/trunk")
  FINAL_TREE=$(cat "$DATA_DIR/final_tree")
  GOAL=$(cat "$DATA_DIR/goal")
  GROUP_COUNT=$(cat "$DATA_DIR/count")
}

# --- Preflight ---

assert_on_feature_branch() {
  ORIG_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  [ -n "$ORIG_BRANCH" ] || fail "Detached HEAD — switch to the autoresearch branch first."
  [ "$ORIG_BRANCH" != "$TRUNK" ] || fail "On trunk ($TRUNK) — switch to the autoresearch branch first."
}

assert_commits_exist() {
  git rev-parse "$BASE" >/dev/null 2>&1 || fail "Base commit $BASE not found."
  git rev-parse "$FINAL_TREE" >/dev/null 2>&1 || fail "Final tree commit $FINAL_TREE not found."
}

collect_group_files() {
  local group_index="$1" prev_commit="$2"
  local last_commit
  last_commit=$(cat "$DATA_DIR/$group_index.last_commit")
  git cat-file -t "$last_commit" 2>/dev/null | grep -q "commit" \
    || fail "Group $((group_index+1)) last_commit $last_commit not found. Use full hashes."

  : > "$DATA_DIR/$group_index.files"
  local changed_file
  while IFS= read -r -d '' changed_file; do
    [ -n "$changed_file" ] || continue
    is_session_file "$changed_file" || echo "$changed_file" >> "$DATA_DIR/$group_index.files"
  done < <(git diff --name-only -z "$prev_commit" "$last_commit")
}

assert_no_overlapping_files() {
  local new_files_path="$1" seen_files_path="$2"
  [ -s "$new_files_path" ] || return 0
  [ -s "$seen_files_path" ] || return 0
  local candidate
  while IFS= read -r candidate; do
    if grep -qxF "$candidate" "$seen_files_path"; then
      fail "File '$candidate' appears in multiple groups. Merge the overlapping groups and retry."
    fi
  done < "$new_files_path"
}

assert_branch_available() {
  local branch_name="$1"
  if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    fail "Branch '$branch_name' already exists. Delete it first or use a different goal slug."
  fi
}

preflight() {
  echo ""
  info "═══ Preflight ═══"
  echo ""

  assert_on_feature_branch
  assert_commits_exist

  local prev_commit="$BASE"
  local all_seen_path="$DATA_DIR/all_seen_files"
  : > "$all_seen_path"

  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    collect_group_files "$i" "$prev_commit"
    assert_no_overlapping_files "$DATA_DIR/$i.files" "$all_seen_path"
    cat "$DATA_DIR/$i.files" >> "$all_seen_path"

    local group_number branch_name
    group_number=$(printf "%02d" $((i + 1)))
    branch_name="autoresearch/${GOAL}/${group_number}-$(cat "$DATA_DIR/$i.slug")"
    assert_branch_available "$branch_name"
    GROUP_BRANCH[$i]=""

    prev_commit=$(cat "$DATA_DIR/$i.last_commit")
  done

  assert_branch_available "autoresearch/${GOAL}/verify-tmp"

  info "Preflight passed."
  echo "  Branch:     $ORIG_BRANCH"
  echo "  Base:       ${BASE:0:12}"
  echo "  Groups:     $GROUP_COUNT"
}

# --- Create branches ---

rollback_on_failure() {
  local exit_code=$?
  if [ $exit_code -eq 0 ]; then return; fi

  echo ""
  echo -e "${RED}FAILED — rolling back...${NC}"
  git reset --quiet HEAD -- . 2>/dev/null || true
  for branch in "${CREATED_BRANCHES[@]}"; do
    git branch -D "$branch" 2>/dev/null || true
  done
  if [ -n "${ORIG_BRANCH:-}" ]; then
    git checkout "$ORIG_BRANCH" --quiet 2>/dev/null || true
  fi
  if [ "$STASHED" = true ]; then
    git stash pop --quiet 2>/dev/null \
      || echo -e "${YELLOW}⚠ Could not restore stashed changes. Run 'git stash list' to recover.${NC}"
  fi
  cleanup_data
  echo -e "${RED}Rolled back to '$ORIG_BRANCH'. No branches left behind.${NC}"
}

stash_if_dirty() {
  if ! git diff --quiet 2>/dev/null \
    || ! git diff --cached --quiet 2>/dev/null \
    || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    warn "Stashing uncommitted changes..."
    git stash -u
    STASHED=true
  fi
}

create_group_branch() {
  local i="$1"
  local title last_commit slug group_number branch_name

  title=$(cat "$DATA_DIR/$i.title")
  local body
  body=$(cat "$DATA_DIR/$i.body")
  last_commit=$(cat "$DATA_DIR/$i.last_commit")
  slug=$(cat "$DATA_DIR/$i.slug")
  local files_path="$DATA_DIR/$i.files"

  group_number=$(printf "%02d" $((i + 1)))
  branch_name="autoresearch/${GOAL}/${group_number}-${slug}"

  info "[$group_number/$GROUP_COUNT] $title"

  if [ ! -s "$files_path" ]; then
    warn "No files changed — skipping this group"
    GROUP_BRANCH[$i]="skipped"
    return
  fi

  git checkout "$BASE" --quiet --detach 2>/dev/null || git checkout "$BASE" --quiet
  git checkout -b "$branch_name"

  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    git checkout "$last_commit" -- "$changed_file"
  done < "$files_path"
  git commit -m "$title" -m "$body"

  CREATED_BRANCHES+=("$branch_name")
  GROUP_BRANCH[$i]="$branch_name"
  echo "  Branch: $branch_name"
  echo "  Files: $(tr '\n' ' ' < "$files_path")"
  echo ""
}

create_branches() {
  echo ""
  info "═══ Creating branches ═══"
  echo ""

  trap rollback_on_failure EXIT
  stash_if_dirty

  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    create_group_branch "$i"
  done

  info "Created ${#CREATED_BRANCHES[@]} branches (all from merge-base, independent):"
  for branch in "${CREATED_BRANCHES[@]}"; do echo "  $branch"; done

  trap - EXIT
}

# --- Verify ---

verify_union_matches_original() {
  local verify_branch="autoresearch/${GOAL}/verify-tmp"

  git checkout "$BASE" --quiet --detach 2>/dev/null || git checkout "$BASE" --quiet
  git checkout -b "$verify_branch"

  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    local last_commit
    last_commit=$(cat "$DATA_DIR/$i.last_commit")
    while IFS= read -r changed_file; do
      [ -n "$changed_file" ] || continue
      git checkout "$last_commit" -- "$changed_file"
    done < "$DATA_DIR/$i.files"
  done
  git commit --allow-empty -m "verify: union of all groups" --quiet

  local non_session_diff=""
  for changed_file in $(git diff --name-only HEAD "$FINAL_TREE" 2>/dev/null); do
    is_session_file "$changed_file" || non_session_diff="$non_session_diff $changed_file"
  done

  git checkout "$ORIG_BRANCH" --quiet 2>/dev/null || true
  git branch -D "$verify_branch" 2>/dev/null || true

  if [ -n "$non_session_diff" ]; then
    echo -e "${RED}✗ Union of groups differs from autoresearch branch!${NC}"
    echo "  Files:$non_session_diff"
    return 1
  fi

  echo -e "${GREEN}✓ Union of all groups matches original autoresearch branch.${NC}"
  return 0
}

verify_no_session_artifacts() {
  local clean=true
  for branch in "${CREATED_BRANCHES[@]}"; do
    for changed_file in $(git diff-tree --no-commit-id --name-only -r "$(git rev-parse "$branch")" 2>/dev/null); do
      if is_session_file "$changed_file"; then
        echo -e "${RED}✗ Session artifact '$changed_file' in branch $branch!${NC}"
        clean=false
      fi
    done
  done

  if [ "$clean" = true ]; then
    echo -e "${GREEN}✓ No session artifacts in any branch.${NC}"
    return 0
  fi
  return 1
}

verify_no_empty_commits() {
  local errors=0
  for branch in "${CREATED_BRANCHES[@]}"; do
    local commit diff_output
    commit=$(git rev-parse "$branch" 2>/dev/null)
    diff_output=$(git diff-tree --no-commit-id --name-only -r "$commit" 2>/dev/null || echo "")
    if [ -z "$diff_output" ]; then
      echo -e "${RED}✗ Empty commit in $branch${NC}"
      errors=$((errors + 1))
    fi
  done
  return $errors
}

verify_branches() {
  echo ""
  info "═══ Verifying ═══"
  echo ""

  local errors=0

  verify_union_matches_original || errors=$((errors + 1))
  verify_no_session_artifacts || errors=$((errors + 1))
  verify_no_empty_commits || errors=$((errors + $?))

  echo ""
  if [ $errors -gt 0 ]; then
    echo -e "${RED}Verification failed with $errors error(s).${NC}"
    echo -e "${RED}Branches are intact — inspect and fix manually, or delete and retry.${NC}"
    echo "  Branches: ${CREATED_BRANCHES[*]}"
    echo "  You are on: $(git branch --show-current 2>/dev/null || echo 'detached')"
    cleanup_data
    exit 1
  fi
  info "✓ All checks passed."
}

# --- Summary ---

print_summary() {
  echo ""
  info "═══ Summary ═══"
  echo ""

  echo "Goal: $GOAL"
  echo "Base: ${BASE:0:12}"
  echo "Source branch: $ORIG_BRANCH"
  echo ""

  echo "Branches:"
  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    local title body branch group_number
    title=$(cat "$DATA_DIR/$i.title")
    body=$(cat "$DATA_DIR/$i.body")
    branch="${GROUP_BRANCH[$i]:-skipped}"
    group_number=$(printf "%02d" $((i + 1)))
    echo ""
    echo "  $group_number. $title"
    echo "     Branch: $branch"
    echo "     Files: $(tr '\n' ' ' < "$DATA_DIR/$i.files")"
    echo ""
    echo "$body" | sed 's/^/     /'
  done

  echo ""
  echo "Cleanup — after merging, delete the autoresearch branch and session files:"
  echo ""
  echo "  git branch -D $ORIG_BRANCH"
  echo "  rm -f autoresearch.jsonl autoresearch.sh autoresearch.md autoresearch.ideas.md"

  if [ -f "autoresearch.ideas.md" ]; then
    echo ""
    echo "Ideas backlog (from autoresearch.ideas.md):"
    echo ""
    sed 's/^/  /' autoresearch.ideas.md
  fi

  echo ""
  if [ "$STASHED" = true ]; then
    warn "Changes were stashed. Run 'git stash pop' to restore or 'git stash drop' to discard."
  fi
}

# --- Main ---

main() {
  if [ $# -lt 1 ]; then
    echo "Usage: $0 <groups.json>"
    exit 1
  fi

  parse_groups "$1"
  preflight
  create_branches
  verify_branches
  print_summary
  cleanup_data
}

main "$@"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_finalize.sh`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add scripts/finalize.sh tests/test_finalize.sh
git commit -m "feat: add finalize.sh — create clean branches from autoresearch session"
```

---

### Task 6: Make all scripts executable and add run-all-tests script

**Files:**
- Create: `tests/run_all.sh`

- [ ] **Step 1: Make scripts executable and create test runner**

```bash
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
```

- [ ] **Step 2: Set executable permissions and run all tests**

```bash
chmod +x scripts/init_experiment.sh scripts/run_experiment.sh scripts/log_experiment.sh scripts/finalize.sh
chmod +x tests/run_all.sh
bash tests/run_all.sh
```

Expected: All test suites pass

- [ ] **Step 3: Commit**

```bash
git add scripts/ tests/run_all.sh
git commit -m "chore: make scripts executable, add test runner"
```

---

### Task 7: /autoresearch Skill (SKILL.md)

**Files:**
- Create: `skills/autoresearch/SKILL.md`

- [ ] **Step 1: Write the autoresearch skill**

The skill is a markdown prompt with YAML frontmatter. It instructs Claude on how to set up and run the autonomous experiment loop. The `SCRIPTS_DIR` is resolved relative to the skill file location.

```markdown
---
name: autoresearch
description: Use when asked to optimize something in a loop, run autoresearch, benchmark iteratively, or start autonomous experiments. Sets up and runs an autonomous experiment loop for any optimization target.
---

# Autoresearch

Autonomous experiment loop: try ideas, keep what works, discard what doesn't, never stop.

*Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).*

## Scripts

Helper scripts are located at `<SKILL_DIR>/../scripts/`. Resolve the absolute path before first use:

```bash
SCRIPTS_DIR="$(cd "$(dirname "<SKILL_FILE>")/../scripts" && pwd)"
```

Replace `<SKILL_FILE>` with the actual path to this SKILL.md that was loaded. Then use:

- **`$SCRIPTS_DIR/init_experiment.sh`** — configure session (name, metric, unit, direction)
- **`$SCRIPTS_DIR/run_experiment.sh`** — run command, time it, parse `METRIC name=value` lines from output, run optional checks
- **`$SCRIPTS_DIR/log_experiment.sh`** — record result, compute confidence score, auto-commit (keep) or auto-revert (discard/crash/checks_failed)

## Setup (no existing `autoresearch.md`)

1. Ask (or infer from context): **Goal**, **Command**, **Metric** (name + direction), **Files in scope**, **Constraints**.
2. Create branch: `git checkout -b autoresearch/<goal>-<YYYY-MM-DD>`
3. Read the source files in scope. Understand the workload deeply before writing anything.
4. Write `autoresearch.md` (session document — see template below). Commit.
5. Write `autoresearch.sh` (benchmark script — see template below). Make it executable. Commit.
6. If constraints require correctness checks (tests must pass, types must check), write `autoresearch.checks.sh`. Make it executable. Commit.
7. Initialize: `$SCRIPTS_DIR/init_experiment.sh --name "<goal>" --metric "<metric_name>" --unit "<unit>" --direction "<lower|higher>"`
8. Run baseline: `$SCRIPTS_DIR/run_experiment.sh --command "./autoresearch.sh"`
9. Log baseline: `$SCRIPTS_DIR/log_experiment.sh --commit "$(git rev-parse --short HEAD)" --metric <value> --status keep --description "baseline"`
10. Start looping immediately.

## Resume (existing `autoresearch.md`)

1. Read `autoresearch.md` — full session context.
2. Read last 20 lines of `autoresearch.jsonl` — recent results.
3. Read `autoresearch.ideas.md` if it exists — pending ideas.
4. Continue looping from where the previous session left off.

## `autoresearch.md` Template

```markdown
# Autoresearch: <goal>

## Objective
<Specific description of what we're optimizing and the workload.>

## Metrics
- **Primary**: <name> (<unit>, lower/higher is better) — the optimization target
- **Secondary**: <name>, <name>, ... — independent tradeoff monitors

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Files in Scope
<Every file the agent may modify, with a brief note on what it does.>

## Off Limits
<What must NOT be touched.>

## Constraints
<Hard rules: tests must pass, no new deps, etc.>

## What's Been Tried
<Update this section as experiments accumulate. Note key wins, dead ends,
and architectural insights so the agent doesn't repeat failed approaches.>
```

This is the heart of the session. A fresh agent with no context should be able to read this file and run the loop effectively. Invest time making it excellent.

## `autoresearch.sh` Template

```bash
#!/bin/bash
set -euo pipefail
# Pre-checks (fast, <1s) — catch syntax errors early
# ...

# Run the benchmark
# ...

# Output structured metrics (parsed by run_experiment.sh)
echo "METRIC total_seconds=12.34"
echo "METRIC compile_seconds=3.2"
```

For fast, noisy benchmarks (<5s), run the workload multiple times and report the median. This makes the confidence score reliable from the start. Slow workloads (ML training, large builds) don't need this.

Design the script to output whatever data helps you make better decisions: phase timings, error counts, memory usage, cache hit rates. You can update the script during the loop as you learn what matters.

## `autoresearch.checks.sh` (optional)

Only create this file when the user's constraints require correctness validation (e.g., "tests must pass", "types must check"). When it exists, `run_experiment.sh` runs it automatically after every passing benchmark.

```bash
#!/bin/bash
set -euo pipefail
# Keep output minimal — only errors, not verbose success output
pnpm test --run --reporter=dot 2>&1 | tail -50
pnpm typecheck 2>&1 | grep -i error || true
```

## The Loop

**LOOP FOREVER.** Never ask "should I continue?" — the user expects autonomous work.

Each iteration:
1. Study the code/data. Think about what to try next.
2. Make a code change. Stage it with `git add`.
3. Run: `$SCRIPTS_DIR/run_experiment.sh --command "./autoresearch.sh"`
4. Determine status:
   - Command passed + metric improved → `keep`
   - Command passed + metric worse/equal → `discard`
   - Command crashed or timed out → `crash`
   - Checks failed → `checks_failed`
5. Log: `$SCRIPTS_DIR/log_experiment.sh --commit "$(git rev-parse --short HEAD)" --metric <value> --status <status> --description "<what you tried>" --asi '<json>'`
6. Repeat.

### Rules

- **Primary metric is king.** Improved → keep. Worse or equal → discard. Secondary metrics rarely affect this.
- **Annotate every run with ASI.** Pass `--asi '{"key":"value"}'` to `log_experiment.sh`. Record what you *learned*, not what you *did*. What would help the next iteration or a fresh agent resuming this session?
- **Watch the confidence score.** After 3+ runs, `log_experiment.sh` reports confidence. ≥2.0× = likely real improvement. <1.0× = within noise — consider re-running to confirm.
- **Simpler is better.** Removing code for equal perf = keep. Ugly complexity for tiny gain = probably discard.
- **Don't thrash.** Repeatedly reverting the same idea? Try something structurally different.
- **Crashes:** fix if trivial, otherwise log and move on. Don't over-invest.
- **Think longer when stuck.** Re-read source files, study profiling data, reason about what the CPU is actually doing. The best ideas come from deep understanding, not random variations.
- **Update `autoresearch.md`** periodically — especially the "What's Been Tried" section.
- **Ideas backlog:** append promising but complex ideas to `autoresearch.ideas.md`. On resume, check it — prune stale entries, try promising ones.

### User Messages During Experiments

If the user sends a message while an experiment is running, finish the current run_experiment + log_experiment cycle first, then incorporate their feedback in the next iteration.

**NEVER STOP.** The user may be away for hours. Keep going until interrupted.
```

- [ ] **Step 2: Verify skill frontmatter is valid**

Check that the YAML frontmatter has `name` and `description` fields, description starts with "Use when", and total frontmatter is under 1024 characters.

- [ ] **Step 3: Commit**

```bash
git add skills/autoresearch/SKILL.md
git commit -m "feat: add /autoresearch skill — setup, run, and resume experiment loops"
```

---

### Task 8: /autoresearch-finalize Skill (SKILL.md)

**Files:**
- Create: `skills/autoresearch-finalize/SKILL.md`

- [ ] **Step 1: Write the autoresearch-finalize skill**

```markdown
---
name: autoresearch-finalize
description: Use when asked to finalize autoresearch, clean up experiments, prepare autoresearch for review, or create PR-ready branches from an autoresearch session.
---

# Finalize Autoresearch

Turn a noisy autoresearch branch into clean, independent branches — one per logical change, each starting from the merge-base. Each branch can be reviewed and merged independently.

## Scripts

Helper scripts are located at `<SKILL_DIR>/../scripts/`. Resolve the absolute path:

```bash
SCRIPTS_DIR="$(cd "$(dirname "<SKILL_FILE>")/../scripts" && pwd)"
```

## Step 1 — Analyze and Propose Groups

1. Read `autoresearch.jsonl`. Filter to **kept** experiments only (status = "keep").
2. Read `autoresearch.md` for context on what was optimized.
3. Expand all short commit hashes to full hashes: `git rev-parse <short_hash>`
4. Get the merge-base: `git merge-base HEAD main`
5. For each kept commit, get the diff stat: `git diff --stat <prev>..<commit>`
6. Group kept commits into logical changesets:
   - **Preserve application order.** Group N comes before Group N+1.
   - **No two groups may touch the same file.** Each branch applies to merge-base independently — overlapping files would conflict. If two groups must touch the same file, merge them into one group.
   - **Watch for cross-file dependencies.** If group 1 adds an API in `api.js` and group 2 calls it in `parser.js`, group 2 won't work alone. Flag tight dependencies and merge the groups.
   - **Keep each group small and focused.** One idea, one theme per group.
   - **Don't hardcode a count.** Could be 2, could be 15.

Present the proposed grouping to the user:

```
Proposed branches (each from merge-base, independent):

1. **Switch test runner to forks pool** (commits abc1234, def5678)
   Files: vitest.config.ts, package.json
   Metric: 42.3s → 38.1s (-9.9%)

2. **Tune worker count and timeouts** (commits ghi9012, jkl3456)
   Files: test/setup.ts
   Metric: 38.1s → 31.7s (-16.8%)
```

**Wait for user approval before proceeding.**

## Step 2 — Write `groups.json` and Run `finalize.sh`

Write `/tmp/autoresearch-groups.json`:

```json
{
  "base": "<full merge-base hash>",
  "trunk": "main",
  "final_tree": "<full hash of current HEAD>",
  "goal": "short-slug",
  "groups": [
    {
      "title": "Switch to forks pool",
      "body": "Why + what changed.\n\nExperiments: #3, #5\nMetric: 42.3s → 38.1s (-9.9%)",
      "last_commit": "<full hash of last kept commit in this group>",
      "slug": "forks-pool"
    }
  ]
}
```

Key rules:
- **`last_commit` must be a full hash.** Expand from short hashes with `git rev-parse`.
- **No two groups may share a file.** The script validates this and fails if violated.

Then run:

```bash
bash "$SCRIPTS_DIR/finalize.sh" /tmp/autoresearch-groups.json
```

The script creates one branch per group from the merge-base, verifies the union matches the original branch, and prints a summary.

On creation failure: rolls back (deletes branches, restores original branch, pops stash).
On verification failure: exits non-zero but leaves branches intact for inspection.

## Step 3 — Report

After the script finishes, report to the user:
- Branches created and what each contains
- Overall metric improvement (baseline → final best)
- Show the cleanup commands from the script output

## Edge Cases

- **Only 1 kept experiment**: One branch is fine — don't force splits.
- **Overlapping files between groups**: The script fails with an error naming the file. Merge the overlapping groups and retry.
- **Non-experiment commits** on the branch: Skip them — only process kept experiments from the JSONL.
```

- [ ] **Step 2: Verify skill frontmatter is valid**

Check that the YAML frontmatter has `name` and `description` fields, description starts with "Use when", and total frontmatter is under 1024 characters.

- [ ] **Step 3: Commit**

```bash
git add skills/autoresearch-finalize/SKILL.md
git commit -m "feat: add /autoresearch-finalize skill — clean branches from experiments"
```

---

### Task 9: README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README**

```markdown
# claude-autoresearch

Autonomous experiment loop for [Claude Code](https://claude.ai/code). Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch) and ported from [pi-autoresearch](https://github.com/davebcn87/pi-autoresearch).

*Try an idea, measure it, keep what works, discard what doesn't, repeat forever.*

## What's included

| Component | Description |
|-----------|-------------|
| `/autoresearch` skill | Set up and run an autonomous experiment loop |
| `/autoresearch-finalize` skill | Turn a noisy branch into clean, reviewable branches |
| Helper scripts | `init_experiment.sh`, `run_experiment.sh`, `log_experiment.sh`, `finalize.sh` |

## Install

Clone this repo and add the skills to your Claude Code settings:

```bash
git clone https://github.com/webmatze/claude-autoresearch.git ~/.claude-autoresearch
```

Add to `~/.claude/settings.json` (global) or `.claude/settings.json` (per-project):

```json
{
  "skills": ["~/.claude-autoresearch/skills"]
}
```

### Dependencies

- `bash` 4.0+
- `git`
- `awk`
- `python3` (for JSON escaping in scripts)
- `jq` (for finalize.sh; falls back to python3 if unavailable)

## Usage

### 1. Start autoresearch

```
/autoresearch optimize unit test runtime, monitor correctness
```

Claude will ask about your goal, command, metric, and files in scope — then create a branch, write session files, run a baseline, and start looping.

### 2. The loop

Claude runs autonomously: edit → benchmark → keep or revert → repeat. Every result is logged to `autoresearch.jsonl`. The session document `autoresearch.md` captures what's been tried so a fresh session can resume.

### 3. Finalize into reviewable branches

```
/autoresearch-finalize
```

Claude reads the experiment log, groups kept experiments into logical changesets, and creates independent branches from the merge-base. Each branch can be reviewed and merged independently.

## Session files

| File | Purpose |
|------|---------|
| `autoresearch.md` | Session document — objective, metrics, files, what's been tried |
| `autoresearch.sh` | Benchmark script — outputs `METRIC name=value` lines |
| `autoresearch.jsonl` | Append-only log of every experiment run |
| `autoresearch.checks.sh` | Optional correctness checks (tests, types, lint) |
| `autoresearch.ideas.md` | Ideas backlog for complex optimizations |

## Example domains

| Domain | Metric | Command |
|--------|--------|---------|
| Test speed | seconds ↓ | `pnpm test` |
| Bundle size | KB ↓ | `pnpm build && du -sb dist` |
| ML training | val_bpb ↓ | `uv run train.py` |
| Build speed | seconds ↓ | `pnpm build` |

## How it works

Two skills encode the workflow. Four bash scripts handle the mechanics.

```
┌────────────────────────┐     ┌─────────────────────────┐
│  Skills (prompts)      │     │  Scripts (bash)          │
│                        │     │                          │
│  /autoresearch         │────▶│  init_experiment.sh      │
│  /autoresearch-finalize│────▶│  run_experiment.sh       │
│                        │     │  log_experiment.sh       │
│                        │     │  finalize.sh             │
└────────────────────────┘     └─────────────────────────┘
```

Session state lives in plain files — a fresh Claude session can resume by reading `autoresearch.md` and `autoresearch.jsonl`.

## Confidence scoring

After 3+ experiments, the log script computes a confidence score using [Median Absolute Deviation (MAD)](https://en.wikipedia.org/wiki/Median_absolute_deviation). This distinguishes real gains from benchmark noise.

| Confidence | Meaning |
|-----------|---------|
| ≥ 2.0× | Improvement is likely real |
| 1.0–2.0× | Above noise but marginal |
| < 1.0× | Within noise — consider re-running |

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with install instructions and usage guide"
```

---

### Task 10: Final Integration Verification

- [ ] **Step 1: Run all tests**

```bash
bash tests/run_all.sh
```

Expected: All test suites pass

- [ ] **Step 2: Verify directory structure**

```bash
find . -type f -not -path './.git/*' | sort
```

Expected output:
```
./README.md
./docs/superpowers/plans/2026-03-30-claude-autoresearch.md
./docs/superpowers/specs/2026-03-30-claude-autoresearch-design.md
./scripts/finalize.sh
./scripts/init_experiment.sh
./scripts/log_experiment.sh
./scripts/run_experiment.sh
./skills/autoresearch-finalize/SKILL.md
./skills/autoresearch/SKILL.md
./tests/run_all.sh
./tests/test_finalize.sh
./tests/test_helpers.sh
./tests/test_init_experiment.sh
./tests/test_log_experiment.sh
./tests/test_pipeline.sh
./tests/test_run_experiment.sh
```

- [ ] **Step 3: Verify skill frontmatter**

Read both SKILL.md files and confirm:
- `name` and `description` fields present
- Description starts with "Use when"
- Total frontmatter under 1024 characters
- No special characters in name (only letters, numbers, hyphens)

- [ ] **Step 4: Verify scripts are executable**

```bash
ls -la scripts/*.sh | awk '{print $1, $NF}'
```

Expected: All scripts show `-rwxr-xr-x` permissions
