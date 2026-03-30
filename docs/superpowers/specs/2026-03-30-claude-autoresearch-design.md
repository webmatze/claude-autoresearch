# Claude Autoresearch — Design Spec

Autonomous experiment loop for Claude Code. Port of [pi-autoresearch](https://github.com/davebcn87/pi-autoresearch) adapted for Claude Code's skill system.

*Try an idea, measure it, keep what works, discard what doesn't, repeat forever.*

## Overview

Two skills and four helper scripts that give Claude Code the ability to run autonomous optimization loops: edit code, benchmark it, keep improvements, revert regressions, repeat.

Works for any optimization target: test speed, bundle size, ML training, build times, Lighthouse scores.

## Architecture

```
┌─────────────────────────┐     ┌──────────────────────────┐
│  Skills (prompt-based)  │     │  Helper Scripts (bash)    │
│                         │     │                           │
│  /autoresearch          │────▶│  init_experiment.sh       │
│    - setup + loop       │     │  run_experiment.sh        │
│                         │     │  log_experiment.sh        │
│  /autoresearch-finalize │────▶│  finalize.sh              │
│    - clean branches     │     │                           │
└─────────────────────────┘     └──────────────────────────┘
                                          │
                                          ▼
                                ┌──────────────────────────┐
                                │  Session Files (per-project)│
                                │                           │
                                │  autoresearch.md          │
                                │  autoresearch.sh          │
                                │  autoresearch.jsonl       │
                                │  autoresearch.checks.sh   │
                                │  autoresearch.ideas.md    │
                                └──────────────────────────┘
```

Skills tell Claude **how to behave** (loop forever, keep/discard logic, when to update docs). Helper scripts handle **mechanical work** (timing, metric parsing, JSONL logging, confidence scoring, git operations).

### Key Differences from pi-autoresearch

| pi version | Claude Code version |
|-----------|-------------------|
| TypeScript extension with custom tools | Bash helper scripts called via Bash tool |
| TUI widget + dashboard (Ctrl+X) | Formatted stdout summaries from scripts |
| `/autoresearch` command with subcommands | Two separate skills |
| Pi-specific APIs (ExtensionAPI, context) | Standard bash + git |

## Directory Structure

```
claude-autoresearch/
├── skills/
│   ├── autoresearch.md          # /autoresearch skill prompt
│   └── autoresearch-finalize.md # /autoresearch-finalize skill prompt
├── scripts/
│   ├── init_experiment.sh       # Session config → JSONL header
│   ├── run_experiment.sh        # Run + time + parse metrics + checks
│   ├── log_experiment.sh        # Record result, confidence, git ops
│   └── finalize.sh              # Create clean branches from kept experiments
└── README.md
```

## Helper Scripts

### `init_experiment.sh`

**Purpose:** One-time session configuration. Writes a config header to `autoresearch.jsonl`.

**Arguments:**
- `--name` — Session name (e.g., "Optimizing vitest runtime")
- `--metric` — Primary metric name (e.g., "total_seconds")
- `--unit` — Metric unit (e.g., "s", "ms", "KB"). Default: ""
- `--direction` — "lower" or "higher". Default: "lower"

**Behavior:**
1. If `autoresearch.jsonl` exists, reads current segment number and increments
2. Writes a JSON line: `{"type":"config","name":"...","metric_name":"...","metric_unit":"...","direction":"...","segment":N,"timestamp":...}`
3. Prints confirmation to stdout

### `run_experiment.sh`

**Purpose:** Runs a command, times wall-clock duration, parses structured metric output, optionally runs checks.

**Arguments:**
- `--command` — Shell command to run (required)
- `--timeout` — Kill after N seconds. Default: 600
- `--checks-timeout` — Kill checks after N seconds. Default: 300

**Behavior:**
1. Runs the command via `bash -c`, captures stdout+stderr to a temp file, times with `date` arithmetic (or `time`)
2. Parses `METRIC name=value` lines from output
3. If command exited 0 and `autoresearch.checks.sh` exists and is executable, runs it with separate timeout
4. Truncates captured output to last 80 lines / 4KB
5. Outputs JSON to stdout:

```json
{
  "exit_code": 0,
  "duration_seconds": 12.34,
  "passed": true,
  "crashed": false,
  "timed_out": false,
  "parsed_metrics": {"total_seconds": 12.34, "compile_seconds": 3.2},
  "parsed_primary": null,
  "checks_pass": true,
  "checks_timed_out": false,
  "checks_output": "",
  "checks_duration": 5.1,
  "tail_output": "...last 80 lines..."
}
```

Note: `parsed_primary` is null here — the script doesn't know which metric is primary. Claude reads `parsed_metrics` and picks the right one based on the session config.

### `log_experiment.sh`

**Purpose:** Records an experiment result, computes confidence, handles git commit/revert.

**Arguments:**
- `--commit` — Git commit hash (short)
- `--metric` — Primary metric value (number)
- `--status` — One of: keep, discard, crash, checks_failed
- `--description` — What this experiment tried
- `--metrics` — Optional JSON object of secondary metrics (e.g., '{"compile_s":3.2}')
- `--asi` — Optional JSON object of actionable side information
- `--jsonl` — Path to JSONL file. Default: `autoresearch.jsonl`

**Behavior:**
1. Reads `autoresearch.jsonl` to determine current segment and existing results
2. Computes confidence score (MAD-based) if 3+ results in current segment:
   - Collect all metric values in current segment
   - Compute median, then MAD (median of absolute deviations from median)
   - Confidence = |best_improvement| / MAD
3. Appends result line to JSONL:
   ```json
   {"type":"result","commit":"abc1234","metric":12.34,"metrics":{},"status":"keep","description":"...","timestamp":...,"segment":0,"confidence":2.1,"asi":{}}
   ```
4. Git operations based on status:
   - `keep`: `git add -A && git commit -m "autoresearch: <description>"`
   - `discard`/`crash`/`checks_failed`: `git checkout -- .` (preserves autoresearch.* files by restoring them after)
5. Prints formatted summary:
   ```
   ══ Run #12 ══
   Status: keep ✓
   Metric: 12.34s (baseline: 15.20s, -18.8%)
   Confidence: 2.1× (likely real)
   Session: 12 runs, 8 kept
   ```

### Confidence Scoring (in `log_experiment.sh`)

Uses MAD (Median Absolute Deviation) — same algorithm as pi:
- After 3+ experiments in current segment
- `confidence = |best_improvement| / MAD`
- ≥2.0× = green (likely real), 1.0-2.0× = yellow (marginal), <1.0× = red (within noise)
- Implemented in `awk` — no external dependencies

### `finalize.sh`

Direct port of the pi version. Already a standalone bash script.

**Input:** Path to `groups.json`

**Behavior:**
1. Parse groups JSON (uses `python3 -c` or `jq` for JSON parsing instead of pi's Node.js)
2. Preflight: verify branch, commits exist, no overlapping files between groups
3. Create one branch per group from merge-base, cherry-picking relevant file changes
4. Verify union of all branches matches the original autoresearch branch
5. Print summary with branches, cleanup commands

**Adaptation from pi:** Replace `node -e` JSON parsing with `jq` (more commonly available on dev machines) or `python3 -c` as fallback.

## Skill: `/autoresearch`

### Trigger
When user says "run autoresearch", "optimize X in a loop", "start experiments", or invokes `/autoresearch`.

### Setup Flow (no existing `autoresearch.md`)
1. Ask or infer: **Goal**, **Command**, **Metric** (name + direction), **Files in scope**, **Constraints**
2. `git checkout -b autoresearch/<goal>-<YYYY-MM-DD>`
3. Read source files in scope — understand the workload deeply before writing anything
4. Write `autoresearch.md` (session doc) and `autoresearch.sh` (benchmark script). Commit both.
5. Optionally write `autoresearch.checks.sh` if constraints require correctness validation
6. Run `init_experiment.sh` with session config
7. Run baseline via `run_experiment.sh` → `log_experiment.sh` → start looping

### Resume Flow (existing `autoresearch.md`)
1. Read `autoresearch.md`, recent `autoresearch.jsonl` entries, and `autoresearch.ideas.md` if present
2. Continue looping from where previous session left off

### `autoresearch.md` Template

```markdown
# Autoresearch: <goal>

## Objective
<Specific description of what we're optimizing and the workload.>

## Metrics
- **Primary**: <name> (<unit>, lower/higher is better)
- **Secondary**: <name>, <name>, ...

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Files in Scope
<Every file the agent may modify, with a brief note on what it does.>

## Off Limits
<What must NOT be touched.>

## Constraints
<Hard rules: tests must pass, no new deps, etc.>

## What's Been Tried
<Updated as experiments accumulate. Key wins, dead ends, architectural insights.>
```

### `autoresearch.sh` Template

```bash
#!/bin/bash
set -euo pipefail
# Pre-checks (fast, <1s)
# ...

# Run benchmark
# ...

# Output structured metrics
echo "METRIC total_seconds=12.34"
echo "METRIC compile_seconds=3.2"
```

For fast/noisy benchmarks (<5s), the script should run multiple iterations and report the median.

### Loop Rules

**LOOP FOREVER.** Never ask "should I continue?" — the user expects autonomous work.

- Primary metric improved → `keep`. Worse or equal → `discard`.
- Record ASI (actionable side information) on every run via `log_experiment.sh --asi`
- Watch confidence score. ≥2.0× = likely real. <1.0× = re-run to confirm.
- Simpler is better. Removing code for equal perf = keep.
- Don't thrash. Same idea reverted twice → try something structurally different.
- Crashes: fix if trivial, log and move on otherwise.
- Think longer when stuck — re-read source files, reason about bottlenecks.
- Update `autoresearch.md` "What's Been Tried" periodically.
- Append promising complex ideas to `autoresearch.ideas.md`.
- On resume, check `autoresearch.ideas.md` — prune stale entries, try promising ones.

### Script Paths

The skill needs to reference the helper scripts. Scripts are located relative to the skill file at `../scripts/`. The skill will resolve the absolute path using `SKILL_DIR` or by reading its own location context.

## Skill: `/autoresearch-finalize`

### Trigger
When user says "finalize autoresearch", "clean up experiments", or invokes `/autoresearch-finalize`.

### Step 1 — Analyze and Propose Groups
1. Read `autoresearch.jsonl`, filter to kept experiments
2. Read `autoresearch.md` for context
3. Expand short commit hashes to full: `git rev-parse <short>`
4. Get merge-base: `git merge-base HEAD main`
5. For each kept commit, get diff stat
6. Group into logical changesets:
   - Preserve application order
   - No two groups share files (would conflict)
   - Flag cross-file dependencies
   - Keep groups small and focused
7. Present proposed grouping to user — **wait for approval**

### Step 2 — Write `groups.json` and Run
Write `groups.json`:
```json
{
  "base": "<full merge-base hash>",
  "trunk": "main",
  "final_tree": "<full HEAD hash>",
  "goal": "short-slug",
  "groups": [
    {
      "title": "Switch to forks pool",
      "body": "Why + what changed.\n\nExperiments: #3, #5\nMetric: 42.3s → 38.1s (-9.9%)",
      "last_commit": "<full commit hash>",
      "slug": "forks-pool"
    }
  ]
}
```

Run: `bash <SCRIPTS_DIR>/finalize.sh /tmp/groups.json`

### Step 3 — Report
- Branches created and what each contains
- Overall metric improvement (baseline → best)
- Cleanup commands from script output

## Installation

Users add the skills directory to their Claude Code configuration. Two options:

1. **Project-level** — add to `.claude/settings.json`:
   ```json
   { "skills": ["./path/to/claude-autoresearch/skills"] }
   ```

2. **Global** — add to `~/.claude/settings.json` for availability in all projects.

The scripts directory must be alongside the skills directory (sibling `scripts/` folder).

## Dependencies

- `bash` (4.0+)
- `awk` (for confidence scoring math)
- `git`
- `jq` (for JSON parsing in finalize.sh; fallback to python3 if unavailable)
- No Node.js required

## Out of Scope

- TUI widget/dashboard (pi has Ctrl+X expand/collapse — not possible in Claude Code)
- `maxIterations` config (Claude can be told to stop after N runs in the skill prompt)
- `workingDir` config override (Claude Code already runs in the project directory)
- Keyboard shortcuts
