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
