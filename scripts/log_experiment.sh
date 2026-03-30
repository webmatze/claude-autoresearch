#!/bin/bash
# scripts/log_experiment.sh — log experiment result with MAD confidence scoring
set -euo pipefail

# --- Defaults ---
COMMIT=""
METRIC=""
STATUS=""
DESCRIPTION=""
SECONDARY_METRICS="{}"
ASI="{}"
JSONL="autoresearch.jsonl"

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit) COMMIT="$2"; shift 2 ;;
    --metric) METRIC="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --metrics) SECONDARY_METRICS="$2"; shift 2 ;;
    --asi) ASI="$2"; shift 2 ;;
    --jsonl) JSONL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$COMMIT" || -z "$METRIC" || -z "$STATUS" || -z "$DESCRIPTION" ]]; then
  echo "Usage: log_experiment.sh --commit <hash> --metric <value> --status <keep|discard|crash|checks_failed> --description <text> [--metrics <json>] [--asi <json>] [--jsonl <path>]" >&2
  exit 1
fi

case "$STATUS" in
  keep|discard|crash|checks_failed) ;;
  *) echo "Error: --status must be keep, discard, crash, or checks_failed" >&2; exit 1 ;;
esac

# --- Read current segment from JSONL ---
SEGMENT=0
if [[ -f "$JSONL" ]]; then
  SEGMENT=$(grep '"type":"config"' "$JSONL" | awk -F'"segment":' '{print $2}' | awk -F'[,}]' '{print $1}' | sort -n | tail -1)
  SEGMENT=${SEGMENT:-0}
fi

# --- Read direction from config ---
DIRECTION="lower"
if [[ -f "$JSONL" ]]; then
  DIRECTION=$(grep '"type":"config"' "$JSONL" | grep "\"segment\":$SEGMENT" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if line:
        d = json.loads(line)
        print(d.get('direction', 'lower'))
        break
" 2>/dev/null || echo "lower")
  DIRECTION=${DIRECTION:-lower}
fi

# --- Count existing results in current segment ---
RUN_COUNT=0
if [[ -f "$JSONL" ]]; then
  RUN_COUNT=$({ grep '"type":"result"' "$JSONL" || true; } | { grep "\"segment\":$SEGMENT" || true; } | wc -l | tr -d ' ')
fi
RUN_NUMBER=$((RUN_COUNT + 1))

# --- Get baseline (first result metric in segment) ---
BASELINE="null"
if [[ -f "$JSONL" ]] && [[ $RUN_COUNT -gt 0 ]]; then
  BASELINE=$(grep '"type":"result"' "$JSONL" | grep "\"segment\":$SEGMENT" | head -1 | python3 -c "
import sys, json
line = sys.stdin.read().strip()
d = json.loads(line)
print(d.get('metric', 'null'))
")
fi

# --- Compute MAD-based confidence score ---
CONFIDENCE="null"
# Need 2+ existing results (so with current we have 3+ total)
if [[ $RUN_COUNT -ge 2 ]]; then
  # Collect all metrics in current segment plus current metric
  ALL_METRICS=$(grep '"type":"result"' "$JSONL" | grep "\"segment\":$SEGMENT" | python3 -c "
import sys, json
metrics = []
for line in sys.stdin:
    line = line.strip()
    if line:
        d = json.loads(line)
        metrics.append(d.get('metric', 0))
print(' '.join(str(m) for m in metrics))
")
  ALL_METRICS="$ALL_METRICS $METRIC"

  # MAD-based confidence: median, MAD, then |best_improvement| / MAD
  CONFIDENCE=$(echo "$ALL_METRICS" "$BASELINE" "$DIRECTION" | python3 -c "
import sys
parts = sys.stdin.read().strip().split()
direction = parts[-1]
baseline = float(parts[-2]) if parts[-2] != 'null' else None
metrics = [float(x) for x in parts[:-2]]
n = len(metrics)
if n < 3 or baseline is None:
    print('null')
else:
    metrics_sorted = sorted(metrics)
    if n % 2 == 1:
        median = metrics_sorted[n // 2]
    else:
        median = (metrics_sorted[n // 2 - 1] + metrics_sorted[n // 2]) / 2
    devs = sorted(abs(m - median) for m in metrics)
    if n % 2 == 1:
        mad = devs[n // 2]
    else:
        mad = (devs[n // 2 - 1] + devs[n // 2]) / 2
    if mad == 0:
        print('null')
    else:
        best = max(metrics) if direction == 'higher' else min(metrics)
        improvement = abs(best - baseline)
        confidence = improvement / mad
        print(round(confidence, 4))
")
fi

# --- Timestamp ---
TIMESTAMP=$(date +%s)

# --- Build result JSON line ---
# Use python3 for proper JSON assembly
RESULT_LINE=$(_METRIC="$METRIC" _STATUS="$STATUS" _DESC="$DESCRIPTION" _COMMIT="$COMMIT" \
  _SEGMENT="$SEGMENT" _TIMESTAMP="$TIMESTAMP" _CONFIDENCE="$CONFIDENCE" \
  _SEC_METRICS="$SECONDARY_METRICS" _ASI="$ASI" \
  python3 << 'PYEOF'
import os, json

metric_val = float(os.environ['_METRIC'])
# Keep as int if it's a whole number
if metric_val == int(metric_val):
    metric_val_str = str(int(metric_val)) + ".0" if '.' in os.environ['_METRIC'] else str(int(metric_val))
else:
    metric_val_str = str(metric_val)

confidence = os.environ['_CONFIDENCE']
sec = os.environ['_SEC_METRICS']
asi = os.environ['_ASI']

result = {
    "type": "result",
    "commit": os.environ['_COMMIT'],
    "metric": float(os.environ['_METRIC']),
    "status": os.environ['_STATUS'],
    "description": os.environ['_DESC'],
    "segment": int(os.environ['_SEGMENT']),
    "timestamp": int(os.environ['_TIMESTAMP']),
    "confidence": float(confidence) if confidence != 'null' else None,
    "metrics": json.loads(sec),
    "asi": json.loads(asi),
}

print(json.dumps(result, separators=(',', ':')))
PYEOF
)

# --- Append to JSONL ---
echo "$RESULT_LINE" >> "$JSONL"

# --- Git operations ---
case "$STATUS" in
  keep)
    git add -A
    git commit -q -m "autoresearch: $DESCRIPTION"
    ;;
  discard|crash|checks_failed)
    # Save autoresearch.* files
    SAVE_DIR=$(mktemp -d)
    for f in autoresearch.*; do
      if [[ -f "$f" ]]; then
        cp "$f" "$SAVE_DIR/"
      fi
    done

    # Revert working tree
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true

    # Restore autoresearch.* files
    for f in "$SAVE_DIR"/autoresearch.*; do
      if [[ -f "$f" ]]; then
        cp "$f" ./
      fi
    done
    rm -rf "$SAVE_DIR"
    ;;
esac

# --- Compute baseline delta ---
DELTA_STR=""
if [[ "$BASELINE" != "null" ]]; then
  DELTA_STR=$(python3 -c "
b = float($BASELINE)
m = float($METRIC)
delta = m - b
sign = '+' if delta >= 0 else ''
print(f'{sign}{delta:.2f}')
")
fi

# --- Print summary ---
echo "Run #$RUN_NUMBER | status=$STATUS | metric=$METRIC${DELTA_STR:+ (${DELTA_STR} from baseline)} | confidence=$CONFIDENCE"
