#!/bin/bash
# scripts/run_experiment.sh — run a command, capture output, parse metrics, run checks
# macOS-compatible (no GNU timeout, no date %N)

# --- Defaults ---
COMMAND=""
TIMEOUT=600
CHECKS_TIMEOUT=300
CHECKS_DIR="."

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --command)
      COMMAND="$2"; shift 2;;
    --timeout)
      TIMEOUT="$2"; shift 2;;
    --checks-timeout)
      CHECKS_TIMEOUT="$2"; shift 2;;
    --checks-dir)
      CHECKS_DIR="$2"; shift 2;;
    *)
      echo "Unknown argument: $1" >&2; exit 2;;
  esac
done

if [[ -z "$COMMAND" ]]; then
  echo "Error: --command is required" >&2
  exit 2
fi

# --- Helper: get current time as float via python3 ---
now_float() {
  python3 -c "import time; print(time.time())"
}

# --- Helper: run command with timeout using Python subprocess ---
# Uses Python subprocess with timeout — no dangling shell background processes.
# Sets globals: CMD_EXIT, CMD_TIMED_OUT, CMD_OUTPUT
run_with_timeout() {
  local cmd="$1"
  local secs="$2"
  local result_file
  result_file=$(mktemp)

  _RUN_CMD="$cmd" _RUN_TIMEOUT="$secs" _RUN_RESULT="$result_file" \
  python3 << 'PYEOF'
import sys, subprocess, json, os

cmd = os.environ['_RUN_CMD']
timeout_secs = int(os.environ['_RUN_TIMEOUT'])
result_file = os.environ['_RUN_RESULT']

timed_out = False
exit_code = 0
output = ''
try:
    proc = subprocess.run(
        cmd,
        shell=True,
        executable='/bin/bash',
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout_secs,
    )
    exit_code = proc.returncode
    output = proc.stdout.decode('utf-8', errors='replace')
except subprocess.TimeoutExpired as e:
    timed_out = True
    exit_code = -1
    output = (e.output or b'').decode('utf-8', errors='replace')

with open(result_file, 'w') as f:
    json.dump({'exit_code': exit_code, 'timed_out': timed_out, 'output': output}, f)
PYEOF

  CMD_EXIT=$(python3 -c "import json; d=json.load(open('$result_file')); print(d['exit_code'])")
  CMD_TIMED_OUT=$(python3 -c "import json; d=json.load(open('$result_file')); print(str(d['timed_out']).lower())")
  CMD_OUTPUT=$(python3 -c "import json,sys; d=json.load(open('$result_file')); sys.stdout.write(d['output'])")
  rm -f "$result_file"
}

# --- JSON-escape a string (strips surrounding quotes from json.dumps output) ---
json_escape_string() {
  python3 -c "
import sys, json
data = sys.stdin.read()
print(json.dumps(data)[1:-1])
"
}

# --- Truncate output: last 80 lines, max 4KB ---
truncate_output() {
  local raw="$1"
  echo "$raw" | tail -n 80 | python3 -c "
import sys
data = sys.stdin.read()
if len(data) > 4096:
    data = data[-4096:]
sys.stdout.write(data)
"
}

# --- Parse METRIC lines, return JSON object or "null" ---
parse_metrics() {
  local output="$1"
  echo "$output" | python3 -c "
import sys, re, json

pairs = {}
for line in sys.stdin:
    m = re.match(r'^METRIC ([a-zA-Z_][a-zA-Z0-9_]*)=(.+)$', line.strip())
    if m:
        key = m.group(1)
        val_str = m.group(2).strip()
        try:
            val = int(val_str)
        except ValueError:
            try:
                val = float(val_str)
            except ValueError:
                val = val_str
        pairs[key] = val

if not pairs:
    print('null')
else:
    print(json.dumps(pairs, separators=(',', ':')))
"
}

# --- Main execution ---

START=$(now_float)
run_with_timeout "$COMMAND" "$TIMEOUT"
END=$(now_float)

DURATION=$(python3 -c "print(round($END - $START, 3))")
EXIT_CODE=$CMD_EXIT
TIMED_OUT=$CMD_TIMED_OUT
RAW_OUTPUT="$CMD_OUTPUT"

# Determine passed/crashed
if [[ "$TIMED_OUT" == "true" ]]; then
  PASSED=false
  CRASHED=false
elif [[ $EXIT_CODE -eq 0 ]]; then
  PASSED=true
  CRASHED=false
else
  PASSED=false
  # Crash = killed by signal (exit > 128)
  if [[ $EXIT_CODE -gt 128 ]]; then
    CRASHED=true
  else
    CRASHED=false
  fi
fi

# Parse metrics
PARSED_METRICS=$(parse_metrics "$RAW_OUTPUT")

# Truncate output
TAIL_OUTPUT=$(truncate_output "$RAW_OUTPUT")

# --- Checks ---
CHECKS_PASS_JSON=null
CHECKS_TIMED_OUT_JSON=null
CHECKS_OUTPUT_JSON=null
CHECKS_DURATION_JSON=null

CHECKS_SCRIPT="$CHECKS_DIR/autoresearch.checks.sh"

if [[ "$PASSED" == "true" && -f "$CHECKS_SCRIPT" && -x "$CHECKS_SCRIPT" ]]; then
  CHECKS_START=$(now_float)
  run_with_timeout "bash $(printf '%q' "$CHECKS_SCRIPT")" "$CHECKS_TIMEOUT"
  CHECKS_END=$(now_float)

  CHECKS_DURATION_JSON=$(python3 -c "print(round($CHECKS_END - $CHECKS_START, 3))")
  CHECKS_EXIT=$CMD_EXIT
  CHECKS_TIMED_OUT_VAL=$CMD_TIMED_OUT

  if [[ "$CHECKS_TIMED_OUT_VAL" == "true" ]]; then
    CHECKS_PASS_JSON=false
    CHECKS_TIMED_OUT_JSON=true
  elif [[ $CHECKS_EXIT -eq 0 ]]; then
    CHECKS_PASS_JSON=true
    CHECKS_TIMED_OUT_JSON=false
  else
    CHECKS_PASS_JSON=false
    CHECKS_TIMED_OUT_JSON=false
  fi

  CHECKS_TAIL=$(truncate_output "$CMD_OUTPUT")
  CHECKS_OUTPUT_ESCAPED=$(echo "$CHECKS_TAIL" | json_escape_string)
  CHECKS_OUTPUT_JSON="\"$CHECKS_OUTPUT_ESCAPED\""
fi

# Escape tail output for JSON
TAIL_ESCAPED=$(echo "$TAIL_OUTPUT" | json_escape_string)

# --- Emit JSON via python3 to ensure valid output ---
python3 - \
  "$EXIT_CODE" \
  "$DURATION" \
  "$PASSED" \
  "$CRASHED" \
  "$TIMED_OUT" \
  "$PARSED_METRICS" \
  "$CHECKS_PASS_JSON" \
  "$CHECKS_TIMED_OUT_JSON" \
  "$CHECKS_OUTPUT_JSON" \
  "$CHECKS_DURATION_JSON" \
  "$TAIL_ESCAPED" << 'PYEOF'
import sys, json

(exit_code, duration, passed_s, crashed_s, timed_out_s,
 parsed_metrics_s, checks_pass_s, checks_timed_out_s,
 checks_output_s, checks_duration_s, tail_escaped) = sys.argv[1:]

def parse_bool_or_null(s):
    if s == 'null': return None
    return s.lower() == 'true'

def parse_num_or_null(s):
    if s == 'null': return None
    try: return int(s)
    except ValueError:
        try: return float(s)
        except ValueError: return s

def parse_json_or_null(s):
    if s == 'null': return None
    return json.loads(s)

result = {
    "exit_code": int(exit_code),
    "duration_seconds": float(duration),
    "passed": passed_s.lower() == 'true',
    "crashed": crashed_s.lower() == 'true',
    "timed_out": timed_out_s.lower() == 'true',
    "parsed_metrics": parse_json_or_null(parsed_metrics_s),
    "checks_pass": parse_bool_or_null(checks_pass_s),
    "checks_timed_out": parse_bool_or_null(checks_timed_out_s),
    "checks_output": parse_json_or_null(checks_output_s),
    "checks_duration": parse_num_or_null(checks_duration_s),
    "tail_output": tail_escaped,
}

print(json.dumps(result, separators=(',', ':')))
PYEOF
